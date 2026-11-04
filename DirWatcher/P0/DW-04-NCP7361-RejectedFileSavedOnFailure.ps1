#Requires -Version 5.1
<#
.SYNOPSIS
  DW-04 / NCP-7361: Failed sanitization must be saved under the configured rejected folder.

.DESCRIPTION
  Regression for NCP-7361:
    - Directory Watcher Settings > Rejected File Behavior = "Save to a single folder" (0) or
      "Save to folder according to reason" (1).
    - Drop a policy-blocked unknown file type (.dat lab fixture) into incoming; sanitization fails.
    - Assert the file appears under the policy rejected folder (not clean output).

  The test fails on builds where HandleInfectedFile does not persist blocked files to RejectedFolder.

  Lab setup:
    - Core with EnableDebugInterface=True (https://localhost:4504/debug/hook).
    - DirWatcher registered to Core and running (restart after policy import unless -SkipDirWatcherRestart).
    - Policy folders under -WorkRoot (default C:\test\DW-NCP7361-<guid>\).

  ---------------------------------------------------------------------------
  Core policy (unless -SkipPolicyImport):
    importpolicies on /debug/hook after pushpolicystate
    Policy name:     NCP7361-dw-rejected-save-lab (placeholder id 9361)
    Assignment rule: debug-dir-watcher-ncp7361 (agent_type dir_watcher)
    Policy raw:      NCP7344 office no-CDR base with Unknown File=False (blocks lab unknown .dat)
                     + Directory Watcher Settings (incoming / temp / rejected, behavior from -RejectedBehavior)
                     + SMB Destination facet (clean out store dw7361-out)
  ---------------------------------------------------------------------------

.PARAMETER RejectedBehavior
  0 = Save to a single folder; 1 = Save to folder according to reason (Jira repro options).

.PARAMETER RejectedOutputTimeoutSec
  Ignored by design (NCP-7361 rejected save is seconds-scale). The script always waits $($script:DwNcp7361RejectedOutputTimeoutSec)s.

.PARAMETER CleanAbsentTimeoutSec
  Ignored by design. The script uses $($script:DwNcp7361CleanAbsentTimeoutSec)s for the clean-folder negative check.

.PARAMETER PostMonitoringSettleSec
  Seconds DirWatcher must remain in armed monitoring before the drop (default 8). Absorbs late OnConnectionUp policy refresh after restart.

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.EXAMPLE
  .\DW-04-NCP7361-RejectedFileSavedOnFailure.ps1

.EXAMPLE
  .\DW-04-NCP7361-RejectedFileSavedOnFailure.ps1 -RejectedBehavior 1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $FixturePath = '',
    [string] $DirWatcherExe = '',
    [ValidateSet(0, 1)]
    [int] $RejectedBehavior = 0,
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $LeaveDirWatcherRunning,
    [switch] $UseAgentCommNudge,
    [int] $SourceClearedTimeoutSec = 60,
    [int] $RejectedOutputTimeoutSec = 5,
    [int] $CleanAbsentTimeoutSec = 5,
    [int] $PostMonitoringSettleSec = 8,
    [int] $PostReconnectSettleSec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return (Get-CoreDeployRequirements) + (Get-DirWatcherDeployRequirements)
}

$script:DwE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:DwE2eCommonRoot 'DirWatcherE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$layout = $null
$dropName = $null
$script:TestId = 'DW-NCP7361'
$script:TestTitle = 'DirWatcher rejected folder save on failed sanitize (NCP-7361)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Write-DwNcp7361CorePolicyHighlight {
    param(
        [int] $RejectedBehavior,
        [switch] $SkipPolicyImport
    )

    if ($SkipPolicyImport) {
        Write-Host '---------------------------------------------------------------------------'
        Write-Host 'Core policy: (unchanged) -SkipPolicyImport; using whatever policy Core/DW already have'
        Write-Host '---------------------------------------------------------------------------'
        return
    }

    $behaviorLabel = switch ($RejectedBehavior) {
        0 { 'Save to a single folder (0)' }
        1 { 'Save to folder according to reason (1)' }
        default { "RejectedBehavior=$RejectedBehavior" }
    }

    Write-Host '---------------------------------------------------------------------------'
    Write-Host 'Core policy: importpolicies via /debug/hook (pushpolicystate first, pop in finally)'
    Write-Host "  Policy name:     $($script:DwNcp7361LabPolicyName) (placeholder id $($script:DwNcp7361LabPolicyPlaceholderId))"
    Write-Host "  Assignment rule: $($script:DwNcp7361DefaultAssignmentRuleName) -> agent_type dir_watcher"
    Write-Host "  Rejected behavior: $behaviorLabel"
    Write-Host '  Policy raw:      NCP7344 no-CDR lab + Unknown File=False + Directory Watcher Settings + SMB clean dest'
    Write-Host '---------------------------------------------------------------------------'
}

$script:DwNcp7361RejectedOutputTimeoutSec = 5
$script:DwNcp7361CleanAbsentTimeoutSec = 2

function Get-DwNcp7361FolderSnapshot {
    param([string] $FolderPath)

    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path -LiteralPath $FolderPath)) {
        return '(missing)'
    }

    $files = @(Get-ChildItem -LiteralPath $FolderPath -File -Recurse -Force -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    if ($files.Count -eq 0) {
        return '(empty)'
    }

    if ($files.Count -le 8) {
        return ($files -join '; ')
    }

    return (($files | Select-Object -First 8) -join '; ') + "; ... (+$($files.Count - 8) more)"
}

function Assert-Ncp7361RejectedPathLayout {
    param(
        [Parameter(Mandatory)]
        [string] $RejectedFilePath,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [ValidateSet(0, 1)]
        [int] $RejectedBehavior
    )

    $rejectedRootFull = [System.IO.Path]::GetFullPath($RejectedRoot).TrimEnd('\')
    $parentDir = [System.IO.Path]::GetDirectoryName($RejectedFilePath)
    if ([string]::IsNullOrEmpty($parentDir)) {
        throw "NCP-7361: cannot resolve parent folder for rejected file: $RejectedFilePath"
    }

    $parentFull = [System.IO.Path]::GetFullPath($parentDir).TrimEnd('\')

    if ($RejectedBehavior -eq 0) {
        if ($parentFull -ne $rejectedRootFull) {
            throw "NCP-7361: expected rejected file directly under rejected root for behavior 0. root=$rejectedRootFull parent=$parentFull file=$RejectedFilePath"
        }
        return
    }

    if ($parentFull -eq $rejectedRootFull) {
        throw "NCP-7361: expected reason subfolder under rejected root for behavior 1. file=$RejectedFilePath"
    }

    if (-not $parentFull.StartsWith($rejectedRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "NCP-7361: rejected file is outside rejected root. root=$rejectedRootFull file=$RejectedFilePath"
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    Ensure-DirWatcherE2eProcessRunning -DirWatcherExe $DirWatcherExe

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-DwTestStep "Hook: $hookUrl"

    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-DwTestStep "Core version: $($versionInfo.version)"
    }

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot -DefaultWorkRootPrefix 'DW-NCP7361'
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"
    Write-DwTestStep "  incoming: $($layout.Incoming)"
    Write-DwTestStep "  temp:     $($layout.Temp)"
    Write-DwTestStep "  rejected: $($layout.Rejected)"
    Write-DwTestStep "  clean:    $($layout.Clean)"

    Write-DwNcp7361CorePolicyHighlight -RejectedBehavior $RejectedBehavior -SkipPolicyImport:$SkipPolicyImport

    if (-not $SkipPolicyImport) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true

        if (-not $SkipDirWatcherRestart) {
            Stop-DirWatcherE2eProcesses
        }

        Write-DwTestStep "importpolicies (NCP-7361 DirWatcher lab, RejectedBehavior=$RejectedBehavior)"
        Import-DwNcp7361LabPolicy -HookUrl $hookUrl `
            -IncomingRoot $layout.Incoming -TempRoot $layout.Temp `
            -RejectedRoot $layout.Rejected -CleanRoot $layout.Clean `
            -RejectedBehavior $RejectedBehavior | Out-Null

        if (-not $SkipDirWatcherRestart) {
            $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
            $dwRestartedAtLocal = Get-Date
            Start-DirWatcherE2eProcess -ExePath $dwExe
            if (-not (Test-DirWatcherE2eProcessRunning)) {
                throw 'DirWatcher failed to start after restart.'
            }
            try {
                $ver = (Get-Item -LiteralPath $dwExe).VersionInfo.ProductVersion
                if (-not [string]::IsNullOrWhiteSpace($ver)) {
                    $env:DIRWATCHER_COMPONENT_VERSION = $ver
                    Write-DwTestStep "DirWatcher version: $ver"
                }
            }
            catch {
            }

            Wait-DirWatcherE2eMonitoringStable -IncomingRoot $layout.Incoming -TimeoutSec 90 `
                -SettleSec $PostMonitoringSettleSec -NotBeforeLocal $dwRestartedAtLocal | Out-Null
        }
        elseif ($UseAgentCommNudge) {
            $dwRestartedAtLocal = Get-Date
            Invoke-DirWatcherE2eAgentCommReconnectNudge -HookUrl $hookUrl -SettleSeconds $PostReconnectSettleSec
            Wait-DirWatcherE2eMonitoringStable -IncomingRoot $layout.Incoming -TimeoutSec 90 `
                -SettleSec $PostMonitoringSettleSec -NotBeforeLocal $dwRestartedAtLocal | Out-Null
        }
        else {
            Start-Sleep -Seconds $PostReconnectSettleSec
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    if ([string]::IsNullOrWhiteSpace($FixturePath)) {
        $FixturePath = Join-Path (Get-LabFixturesRoot) 'Blocked\NCP-7361\unknown-blocked.dat'
    }
    $fixtureFull = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not (Test-Path -LiteralPath $fixtureFull -PathType Leaf)) {
        throw "Fixture not found: $fixtureFull"
    }

    $dropName = 'ncp7361-' + [Guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($fixtureFull)
    $dropPath = Join-Path $layout.Incoming $dropName

    Write-DwTestStep "Drop blocked fixture -> $dropPath"
    Copy-Item -LiteralPath $fixtureFull -Destination $dropPath -Force

    Write-DwTestStep 'Assert source file leaves incoming folder after sanitize starts'
    $sourceCleared = Wait-DirWatcherE2eFileLeavesPath -FilePath $dropPath -TimeoutSec $SourceClearedTimeoutSec
    if (-not $sourceCleared) {
        throw "Timed out waiting for incoming drop to leave source ($($SourceClearedTimeoutSec)s): $dropPath"
    }
    Write-DwTestStep 'OK - incoming path cleared'

    Write-DwTestStep 'Assert file does not land in clean destination'
    $cleanHit = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $dropName `
        -TimeoutSec $script:DwNcp7361CleanAbsentTimeoutSec -PollMs 200
    if (-not [string]::IsNullOrWhiteSpace($cleanHit)) {
        throw "NCP-7361: blocked file must not appear in clean folder. Found: $cleanHit"
    }
    Write-DwTestStep 'OK - no clean output for blocked file'

    Write-DwTestStep "Wait for rejected copy under $($layout.Rejected) (timeout $($script:DwNcp7361RejectedOutputTimeoutSec)s)"
    $rejectedPath = Wait-DirWatcherE2eRejectedOutput -RejectedRoot $layout.Rejected -FileName $dropName `
        -TimeoutSec $script:DwNcp7361RejectedOutputTimeoutSec -PollMs 200
    if ([string]::IsNullOrWhiteSpace($rejectedPath)) {
        $tempSnap = Get-DwNcp7361FolderSnapshot -FolderPath $layout.Temp
        $rejectedSnap = Get-DwNcp7361FolderSnapshot -FolderPath $layout.Rejected
        $cleanSnap = Get-DwNcp7361FolderSnapshot -FolderPath $layout.Clean
        throw @"
NCP-7361 regression: blocked file not saved under rejected folder within $($script:DwNcp7361RejectedOutputTimeoutSec)s (behavior=$RejectedBehavior).
  rejectedRoot=$($layout.Rejected)
  dropName=$dropName
  temp=$tempSnap
  rejected=$rejectedSnap
  clean=$cleanSnap
"@
    }
    Write-DwTestStep "OK - rejected output: $rejectedPath"

    Assert-Ncp7361RejectedPathLayout -RejectedFilePath $rejectedPath -RejectedRoot $layout.Rejected `
        -RejectedBehavior $RejectedBehavior

    $script:ScenarioPassed = $true
    Write-Host 'Scenario passed.'
    exit 0
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
    exit 1
}
finally {
    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed) {
        $evidenceOnFailure = Add-DirWatcherE2eFailureEvidenceIfEligible -EvidenceZipLabel 'DW-NCP7361' `
            -Layout $layout -HookUrl $hookUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DIRWATCHER_COMPONENT_VERSION)) {
        $env:TESTPLATFORM_COMPONENT_VERSION = $env:DIRWATCHER_COMPONENT_VERSION
    }
    $prevComponent = $env:TESTPLATFORM_COMPONENT_NAME
    if ([string]::IsNullOrWhiteSpace($prevComponent)) {
        $env:TESTPLATFORM_COMPONENT_NAME = 'DirWatcher'
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:DwE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure `
        -EvidenceZipPath $script:EvidenceZipPath

    if ($script:PolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-DwTestStep 'poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    try {
        Stop-DirWatcherE2eProcessesForScenarioTeardown -LeaveRunning:$LeaveDirWatcherRunning
    }
    catch {
        Write-Warning "DirWatcher teardown failed: $($_.Exception.Message)"
    }

    if ($script:ScenarioPassed -and $layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
        try {
            Remove-Item -LiteralPath $layout.WorkRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove work folder '$($layout.WorkRoot)': $($_.Exception.Message)"
        }
    }
    elseif (-not $script:ScenarioPassed -and $layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
        Write-Host "Work artifacts left at: $($layout.WorkRoot)"
    }
}
