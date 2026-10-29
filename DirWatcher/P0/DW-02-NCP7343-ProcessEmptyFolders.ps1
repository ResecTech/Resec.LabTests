#Requires -Version 5.1
<#
.SYNOPSIS
  DW-02 / NCP-7343: Directory Watcher processes empty folders when policy enables it.

.DESCRIPTION
  Regression for NCP-7343: with "Process empty folders" enabled, dropping an empty directory under
  incoming must be sanitized and replicated to the SMB clean destination.

  Two incoming-folder behaviors are asserted:
    1. Default (Delete processed folders after X minutes = 0): incoming copy remains after clean output.
    2. Delete after X minutes + periodic file check enabled: incoming empty folder is removed by DW
       periodic cleanup (may occur up to ~1 minute after the policy threshold, plus the periodic interval).

  Lab setup:
    - Core with EnableDebugInterface=True (https://localhost:4504/debug/hook).
    - DirWatcher registered to Core and running (restart after policy import unless -SkipDirWatcherRestart).

.PARAMETER DeleteProcessedFoldersAfterMinutes
  Policy value for phase 2 (default 1). Phase 1 always imports with 0.

.PARAMETER SkipPolicyImport
  Use when paths and policy already match (both phases require mutable policy import unless skipped entirely).

.EXAMPLE
  .\DW-02-NCP7343-ProcessEmptyFolders.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $DirWatcherExe = '',
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $UseAgentCommNudge,
    [int] $CleanOutputTimeoutSec = 10,
    [int] $IncomingRetainVerifySec = 5,
    [int] $DeleteProcessedFoldersAfterMinutes = 1,
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
$script:TestId = 'DW-NCP7343'
$script:TestTitle = 'DirWatcher processes empty folders (NCP-7343)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Import-DwNcp7343PolicyAndApply {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        $Layout,
        [int] $DeleteProcessedFoldersAfterMinutes = 0,
        [bool] $EnablePeriodicFileCheck = $false,
        [string] $StepLabel
    )

    if ($SkipPolicyImport) {
        Write-DwTestStep "$StepLabel (SkipPolicyImport — using existing Core/DW policy)"
        return
    }

    Write-DwTestStep $StepLabel
    Write-DwTestStep "  Delete processed folders after X minutes: $DeleteProcessedFoldersAfterMinutes"
    Write-DwTestStep "  Enable periodic file check: $EnablePeriodicFileCheck"

    if (-not $script:PolicyStackPushed) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $HookUrl | Out-Null
        $script:PolicyStackPushed = $true
    }

    Import-DwNcp7343LabPolicy -HookUrl $HookUrl `
        -IncomingRoot $Layout.Incoming -TempRoot $Layout.Temp `
        -RejectedRoot $Layout.Rejected -CleanRoot $Layout.Clean `
        -DeleteProcessedFoldersAfterMinutes $DeleteProcessedFoldersAfterMinutes `
        -EnablePeriodicFileCheck:$EnablePeriodicFileCheck | Out-Null

    if (-not $SkipDirWatcherRestart) {
        $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
        $monitorNotBefore = Get-Date
        Stop-DirWatcherE2eProcesses
        Start-DirWatcherE2eProcess -ExePath $dwExe
        if (-not (Test-DirWatcherE2eProcessRunning)) {
            throw 'DirWatcher failed to start after restart.'
        }
        Set-DirWatcherE2eComponentVersionFromExe -ExePath $dwExe
        Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $Layout.Incoming -TimeoutSec 90 `
            -NotBeforeLocal $monitorNotBefore | Out-Null
    }
    elseif ($UseAgentCommNudge) {
        $monitorNotBefore = Get-Date
        Invoke-DirWatcherE2eAgentCommReconnectNudge -HookUrl $HookUrl -SettleSeconds $PostReconnectSettleSec
        Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $Layout.Incoming -TimeoutSec 90 `
            -NotBeforeLocal $monitorNotBefore | Out-Null
    }
    else {
        Start-Sleep -Seconds $PostReconnectSettleSec
    }
}

function New-DwNcp7343EmptyIncomingFolder {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [string] $NamePrefix = 'ncp7343-empty'
    )

    $folderName = $NamePrefix + '-' + [Guid]::NewGuid().ToString('N')
    $folderPath = Join-Path $IncomingRoot $folderName
    New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    return [pscustomobject]@{
        Name      = $folderName
        Path      = $folderPath
        CreatedAt = [datetime]::Now
    }
}

function Wait-DwNcp7343SanitizedCleanFolder {
    param(
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [Parameter(Mandatory)]
        [string] $FolderName
    )

    Write-DwTestStep "Wait for sanitized empty folder '$FolderName' on SMB clean destination"
    $outputPath = Wait-DirWatcherE2eCleanOutputDirectory -CleanRoot $CleanRoot -DirectoryName $FolderName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        throw "Empty folder '$FolderName' did not appear under clean root $CleanRoot within ${CleanOutputTimeoutSec}s."
    }
    Write-DwTestStep "OK — clean output folder: $outputPath"
    return $outputPath
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

    if ([string]::IsNullOrWhiteSpace($WorkRoot) -and -not $SkipPolicyImport) {
        $WorkRoot = Join-Path 'C:\test' ('DW-NCP7343-' + [Guid]::NewGuid().ToString('N'))
    }

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"
    Write-DwTestStep "  incoming: $($layout.Incoming)"
    Write-DwTestStep "  temp:     $($layout.Temp)"
    Write-DwTestStep "  clean:    $($layout.Clean)"

    if ($SkipPolicyImport -and [string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    # --- Phase 1: default — incoming folder stays after sanitize ---
    Import-DwNcp7343PolicyAndApply -HookUrl $hookUrl -Layout $layout `
        -DeleteProcessedFoldersAfterMinutes 0 -EnablePeriodicFileCheck:$false `
        -StepLabel 'importpolicies phase 1 (Process empty folders; do not delete processed folders)'

    $drop1 = New-DwNcp7343EmptyIncomingFolder -IncomingRoot $layout.Incoming -NamePrefix 'ncp7343-retain'
    Write-DwTestStep "Create empty folder (phase 1) -> $($drop1.Path)"
    Wait-DwNcp7343SanitizedCleanFolder -CleanRoot $layout.Clean -FolderName $drop1.Name | Out-Null

    Write-DwTestStep 'Assert incoming folder remains when Delete processed folders = 0'
    if (-not (Wait-DirWatcherE2ePathPresent -Path $drop1.Path -TimeoutSec $IncomingRetainVerifySec)) {
        throw "Incoming folder should remain with Delete processed folders = 0, but path is missing: $($drop1.Path)"
    }
    Write-DwTestStep 'OK — incoming folder still present (expected default behavior)'

    if ($SkipPolicyImport) {
        Write-DwTestStep 'SkipPolicyImport: skipping phase 2 (delete processed folders policy change)'
    }
    else {
        # --- Phase 2: delete empty processed folders after X minutes (periodic check) ---
        if ($DeleteProcessedFoldersAfterMinutes -le 0) {
            throw 'DeleteProcessedFoldersAfterMinutes must be > 0 for phase 2.'
        }

        Import-DwNcp7343PolicyAndApply -HookUrl $hookUrl -Layout $layout `
            -DeleteProcessedFoldersAfterMinutes $DeleteProcessedFoldersAfterMinutes `
            -EnablePeriodicFileCheck:$true `
            -StepLabel 'importpolicies phase 2 (delete processed folders + periodic file check)'

        $drop2 = New-DwNcp7343EmptyIncomingFolder -IncomingRoot $layout.Incoming -NamePrefix 'ncp7343-delete'
        Write-DwTestStep "Create empty folder (phase 2) -> $($drop2.Path)"
        Wait-DwNcp7343SanitizedCleanFolder -CleanRoot $layout.Clean -FolderName $drop2.Name | Out-Null

        Write-DwTestStep 'Assert incoming folder still present immediately after clean output (before policy age threshold)'
        if (-not (Test-Path -LiteralPath $drop2.Path)) {
            throw "Incoming folder missing too early (phase 2): $($drop2.Path)"
        }
        Write-DwTestStep 'OK — incoming folder still present before periodic delete'

        Write-DwTestStep "Wait for periodic cleanup (policy ${DeleteProcessedFoldersAfterMinutes} min + slack)"
        $deleted = Wait-DirWatcherE2eIncomingFolderDeletedByPolicy `
            -IncomingFolderPath $drop2.Path `
            -FolderCreatedAtLocal $drop2.CreatedAt `
            -DeleteAfterMinutes $DeleteProcessedFoldersAfterMinutes
        if (-not $deleted) {
            throw "Incoming folder was not removed by periodic delete policy within expected window: $($drop2.Path)"
        }
        Write-DwTestStep 'OK — incoming folder removed by Delete processed folders policy'
    }

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
        if ($layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
            $evidenceOnFailure += $layout.WorkRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
            $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
            if ($coreLog) {
                $evidenceOnFailure += $coreLog
                Write-DwTestStep "Core log for evidence: $coreLog"
            }
        }
        $dwLogDir = Get-DirWatcherE2eLogDirectory
        if ($dwLogDir) {
            $evidenceOnFailure += $dwLogDir
        }
        if (@($evidenceOnFailure).Count -gt 0) {
            try {
                $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'DW-NCP7343'
                if ($script:EvidenceZipPath) {
                    Write-DwTestStep "Evidence zip: $($script:EvidenceZipPath)"
                }
            }
            catch {
                Write-Warning "Could not create failure evidence zip: $($_.Exception.Message)"
            }
        }
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
