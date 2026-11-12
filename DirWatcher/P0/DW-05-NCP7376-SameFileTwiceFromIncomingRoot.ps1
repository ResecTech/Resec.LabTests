#Requires -Version 5.1
<#
.SYNOPSIS
  DW-05 / NCP-7376: The same file in the incoming root is sanitized again after a successful first pass.

.DESCRIPTION
  Regression for NCP-7376: sanitize a file dropped in the Directory Watcher incoming root folder, wait until
  clean output exists, then copy the same file to the same incoming path again. The second drop must be
  picked up (source clears and a second successful outcome is recorded).

  Repro steps from ticket (smb-to-smb / local-to-local):
    1. Sanitize any file using DW.
    2. Once the file has reached its destination.
    3. Copy the same file to the incoming root folder again.

  Lab setup:
    - Core with EnableDebugInterface=True (https://localhost:4504/debug/hook).
    - DirWatcher registered to Core and running (restart after policy import unless -SkipDirWatcherRestart).
    - Policy folders under -WorkRoot (default C:\test\DW-NCP7376-<guid>\).

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.PARAMETER SkipDirWatcherRestart
  Do not stop/start DirWatcher after policy import.

.PARAMETER BetweenPassesSettleSec
  Wait after first clean output before the second drop (allows in-flight dedupe to release).

.EXAMPLE
  .\DW-05-NCP7376-SameFileTwiceFromIncomingRoot.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed (repro guard; fails while NCP-7376 is open).
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $FixturePath = '',
    [string] $DirWatcherExe = '',
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $LeaveDirWatcherRunning,
    [switch] $UseAgentCommNudge,
    [int] $SourceClearedTimeoutSec = 60,
    [int] $CleanOutputTimeoutSec = 120,
    [int] $BetweenPassesSettleSec = 5,
    [int] $SecondSourceClearedTimeoutSec = 60,
    [int] $SecondCleanOutputTimeoutSec = 120,
    [int] $PostReconnectSettleSec = 10,
    [int] $MinSanitizeOutcomeCount = 2,
    [int] $TrackingClearTimeoutSec = 20
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
$dropPath = $null
$script:TestId = 'DW-NCP7376'
$script:TestTitle = 'DirWatcher re-sanitizes same incoming root file after first pass (NCP-7376)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Get-DwNcp7376SanitizePassCount {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $DropName,
        [Parameter(Mandatory)]
        [string] $IncomingDropPath,
        [string] $LogMarkMessage = '',
        [string] $DebugBaseUrl = '',
        [DateTimeOffset] $NotBeforeUtc = [DateTimeOffset]::MinValue,
        [int] $PollSec = 20
    )

    $corePattern = "*Sanitization details:*$DropName*Src:$IncomingDropPath*"
    $dwPattern = '*HandleScannedFile: File *outcome:*'

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($PollSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $dwLines = @(Get-DirWatcherE2eMergedLogLines -DebugBaseUrl $DebugBaseUrl -NotBeforeUtc $NotBeforeUtc)
        $dwLines = @($dwLines | Where-Object { Test-DirWatcherE2eLogLineNotBeforeUtc -Line $_ -NotBeforeUtc $NotBeforeUtc })
        if (-not [string]::IsNullOrWhiteSpace($LogMarkMessage)) {
            $dwLines = @(Get-DirWatcherE2eLogSliceAfterMark -Lines $dwLines -LogMarkMessage $LogMarkMessage)
        }

        $dwHits = @($dwLines | Where-Object {
                $_ -like $dwPattern -and $_ -notlike '*duplicate final outcome*'
            })
        if ($dwHits.Count -ge 2) {
            return $dwHits.Count
        }

        $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $HookUrl
        if (-not [string]::IsNullOrWhiteSpace($coreLog) -and (Test-Path -LiteralPath $coreLog -PathType Leaf)) {
            $coreLines = @([string[]](Get-Content -LiteralPath $coreLog -ErrorAction SilentlyContinue))
            $coreLines = @($coreLines | Where-Object { Test-DirWatcherE2eLogLineNotBeforeUtc -Line $_ -NotBeforeUtc $NotBeforeUtc })
            $coreHits = @($coreLines | Where-Object { $_ -like $corePattern })
            if ($coreHits.Count -ge 2) {
                return $coreHits.Count
            }
        }

        Start-Sleep -Seconds 1
    }

    return 0
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

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"

    $dwDebugBaseUrl = ''
    if (Get-Command Get-DirWatcherE2eDebugBaseUrl -ErrorAction SilentlyContinue) {
        $dwDebugBaseUrl = Get-DirWatcherE2eDebugBaseUrl
    }

    if (-not $SkipPolicyImport) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true

        if (-not $SkipDirWatcherRestart) {
            Stop-DirWatcherE2eProcesses
        }

        Write-DwTestStep 'importpolicies (NCP7340-style DirWatcher lab policy)'
        Import-DwNcp7340LabPolicy -HookUrl $hookUrl `
            -IncomingRoot $layout.Incoming -TempRoot $layout.Temp `
            -RejectedRoot $layout.Rejected -CleanRoot $layout.Clean `
            -PolicyName 'NCP7376-dw-lab' | Out-Null

        if (-not $SkipDirWatcherRestart) {
            $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
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
                # optional
            }

            Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 90 | Out-Null
        }
        elseif ($UseAgentCommNudge) {
            Invoke-DirWatcherE2eAgentCommReconnectNudge -HookUrl $hookUrl -SettleSeconds $PostReconnectSettleSec
            Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 90 | Out-Null
        }
        else {
            Start-Sleep -Seconds $PostReconnectSettleSec
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    if ([string]::IsNullOrWhiteSpace($FixturePath)) {
        $FixturePath = Join-Path (Get-LabFixturesRoot) 'FileTypeDetection\sample.txt'
    }
    $fixtureFull = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not (Test-Path -LiteralPath $fixtureFull -PathType Leaf)) {
        throw "Fixture not found: $fixtureFull"
    }

    $dropName = 'ncp7376-root-' + [Guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($fixtureFull)
    $dropPath = Join-Path $layout.Incoming $dropName
    $logMarkPass1 = "DW-05 pass1 $dropName"
    $logMarkPass2 = "DW-05 pass2 $dropName"

    Write-DirWatcherE2eDebugLogMark -Message $logMarkPass1 -BaseUrl $dwDebugBaseUrl

    Write-DwTestStep "Pass 1 - drop fixture at incoming root -> $dropPath"
    Copy-Item -LiteralPath $fixtureFull -Destination $dropPath -Force

    Write-DwTestStep 'Pass 1 - assert source leaves incoming'
    if (-not (Wait-DirWatcherE2eFileLeavesPath -FilePath $dropPath -TimeoutSec $SourceClearedTimeoutSec)) {
        throw "Pass 1: file still in incoming after $($SourceClearedTimeoutSec)s: $dropPath"
    }

    $outputPath = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $dropName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        throw "Pass 1: timed out waiting for clean output '$dropName' ($($CleanOutputTimeoutSec)s)."
    }
    Write-DwTestStep "Pass 1 OK - clean output: $outputPath"

    $trackingTimeoutPass1 = [Math]::Max($TrackingClearTimeoutSec, $BetweenPassesSettleSec + 5)
    Write-DwTestStep "Pass 1 - tracking.state must release incoming dedupe before pass 2"
    Wait-DirWatcherE2eIncomingTrackingCleared -IncomingPath $dropPath -DebugBaseUrl $dwDebugBaseUrl `
        -TimeoutSec $trackingTimeoutPass1 -RequireMapperIdle | Out-Null

    if ($BetweenPassesSettleSec -gt 0) {
        Write-DwTestStep "Settle ${BetweenPassesSettleSec}s before pass 2 (extra slack after tracking clear)"
        Start-Sleep -Seconds $BetweenPassesSettleSec
    }

    Write-DirWatcherE2eDebugLogMark -Message $logMarkPass2 -BaseUrl $dwDebugBaseUrl

    Write-DwTestStep "Pass 2 - copy same file again to incoming root -> $dropPath"
    Copy-Item -LiteralPath $fixtureFull -Destination $dropPath -Force

    Write-DwTestStep 'Pass 2 - assert source leaves incoming (NCP-7376)'
    if (-not (Wait-DirWatcherE2eFileLeavesPath -FilePath $dropPath -TimeoutSec $SecondSourceClearedTimeoutSec)) {
        throw "NCP-7376: second drop was not taken - file still in incoming after $($SecondSourceClearedTimeoutSec)s: $dropPath"
    }
    Write-DwTestStep 'Pass 2 - wait for clean output (same mtime as fixture is OK)'

    $outputPath2 = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $dropName `
        -TimeoutSec $SecondCleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath2)) {
        throw "Pass 2: timed out waiting for clean output '$dropName' ($($SecondCleanOutputTimeoutSec)s)."
    }
    Write-DwTestStep "Pass 2 OK - clean output: $outputPath2"

    Write-DwTestStep 'Pass 2 - tracking.state must not leave incoming/mapper junk after second outcome'
    Wait-DirWatcherE2eIncomingTrackingCleared -IncomingPath $dropPath -DebugBaseUrl $dwDebugBaseUrl `
        -TimeoutSec $TrackingClearTimeoutSec -RequireMapperIdle | Out-Null

    $sanitizePassCount = Get-DwNcp7376SanitizePassCount -HookUrl $hookUrl -DropName $dropName `
        -IncomingDropPath $dropPath -LogMarkMessage $logMarkPass1 -DebugBaseUrl $dwDebugBaseUrl `
        -NotBeforeUtc $script:TestStartedAtUtc
    if ($sanitizePassCount -lt $MinSanitizeOutcomeCount) {
        throw "Expected at least $MinSanitizeOutcomeCount sanitize passes for '$dropName' (Core Sanitization details or DirWatcher outcome log); got $sanitizePassCount."
    }
    Write-DwTestStep "OK - logs show $sanitizePassCount sanitize pass(es) for '$dropName'"

    Assert-DirWatcherE2eSanitizeLogHasNoWarnings -LogMarkMessage $logMarkPass1 -FileNameHint $dropName `
        -DebugBaseUrl $dwDebugBaseUrl -NotBeforeUtc $script:TestStartedAtUtc

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
        $evidenceOnFailure = Add-DirWatcherE2eFailureEvidenceIfEligible -EvidenceZipLabel 'DW-NCP7376' `
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
