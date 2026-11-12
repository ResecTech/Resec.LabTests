#Requires -Version 5.1
<#
.SYNOPSIS
  DW-06 / NCP-7377: Periodic File Check Stop Regex skips files under matching folders.

.DESCRIPTION
  Regression for NCP-7377: with periodic file check enabled, Process pre-existing files disabled,
  and Periodic File Check Stop Regex set to the ticket value (".*\stop"), files already under
  "stop" folders must not be sanitized on periodic scan; files under a normal folder must still sanitize.

  Repro steps from ticket:
    - Enable Periodic File Check Stop Regex (".*\stop") and periodic file check.
    - Disable collecting files on start (Process pre-existing files = false).
    - Place files under stop folders (and subfolders) before DW starts.

  Lab setup:
    - Core with EnableDebugInterface=True.
    - DirWatcher registered to Core (restart after policy import unless -SkipDirWatcherRestart).

.PARAMETER PeriodicFileCheckStopRegex
  Policy regex (default repro from ticket).

.PARAMETER PeriodicWaitSec
  Wait after DW monitoring starts before asserting (DW default interval is 1 minute; default 75s slack).

.EXAMPLE
  .\DW-06-NCP7377-PeriodicFileCheckStopRegex.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed (repro guard while NCP-7377 is open).
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $FixturePath = '',
    [string] $DirWatcherExe = '',
    [string] $PeriodicFileCheckStopRegex = '.*\stop',
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $LeaveDirWatcherRunning,
    [switch] $UseAgentCommNudge,
    [int] $PeriodicWaitSec = 75,
    [int] $CleanOutputTimeoutSec = 90,
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
$script:TestId = 'DW-NCP7377'
$script:TestTitle = 'DirWatcher periodic file check honors stop regex (NCP-7377)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    Ensure-DirWatcherE2eProcessRunning -DirWatcherExe $DirWatcherExe | Out-Null

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-DwTestStep "Hook: $hookUrl"

    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-DwTestStep "Core version: $($versionInfo.version)"
    }

    if ([string]::IsNullOrWhiteSpace($WorkRoot) -and -not $SkipPolicyImport) {
        $WorkRoot = Join-Path 'C:\test' ('DW-NCP7377-' + [Guid]::NewGuid().ToString('N'))
    }

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"

    if ($SkipPolicyImport -and [string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    $stopDir = Join-Path $layout.Incoming 'stop'
    $nestedStopDir = Join-Path (Join-Path $layout.Incoming 'level1') 'stop'
    $allowedDir = Join-Path $layout.Incoming 'allowed'
    New-Item -ItemType Directory -Path $stopDir -Force | Out-Null
    New-Item -ItemType Directory -Path $nestedStopDir -Force | Out-Null
    New-Item -ItemType Directory -Path $allowedDir -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($FixturePath)) {
        $FixturePath = Join-Path (Get-LabFixturesRoot) 'FileTypeDetection\sample.txt'
    }
    $fixtureFull = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not (Test-Path -LiteralPath $fixtureFull -PathType Leaf)) {
        throw "Fixture not found: $fixtureFull"
    }

    $allowedName = 'ncp7377-allowed' + [System.IO.Path]::GetExtension($fixtureFull)
    $stopName = 'ncp7377-stop' + [System.IO.Path]::GetExtension($fixtureFull)
    $nestedStopName = 'ncp7377-nested-stop' + [System.IO.Path]::GetExtension($fixtureFull)

    $allowedPath = Join-Path $allowedDir $allowedName
    $stopPath = Join-Path $stopDir $stopName
    $nestedStopPath = Join-Path $nestedStopDir $nestedStopName

    Write-DwTestStep 'Seed files under stop and allowed folders (before DW policy/restart)'
    Copy-Item -LiteralPath $fixtureFull -Destination $allowedPath -Force
    Copy-Item -LiteralPath $fixtureFull -Destination $stopPath -Force
    Copy-Item -LiteralPath $fixtureFull -Destination $nestedStopPath -Force

    if (-not $SkipPolicyImport) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true

        if (-not $SkipDirWatcherRestart) {
            Stop-DirWatcherE2eProcesses
        }

        Write-DwTestStep "importpolicies (periodic on, pre-existing off, stop regex='$PeriodicFileCheckStopRegex')"
        Import-DwNcp7377LabPolicy -HookUrl $hookUrl `
            -IncomingRoot $layout.Incoming -TempRoot $layout.Temp `
            -RejectedRoot $layout.Rejected -CleanRoot $layout.Clean `
            -PeriodicFileCheckStopRegex $PeriodicFileCheckStopRegex | Out-Null

        if (-not $SkipDirWatcherRestart) {
            $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
            $monitorNotBefore = Get-Date
            Start-DirWatcherE2eProcess -ExePath $dwExe
            if (-not (Test-DirWatcherE2eProcessRunning)) {
                throw 'DirWatcher failed to start after restart.'
            }
            Set-DirWatcherE2eComponentVersionFromExe -ExePath $dwExe
            Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 90 `
                -NotBeforeLocal $monitorNotBefore | Out-Null
        }
        elseif ($UseAgentCommNudge) {
            $monitorNotBefore = Get-Date
            Invoke-DirWatcherE2eAgentCommReconnectNudge -HookUrl $hookUrl -SettleSeconds $PostReconnectSettleSec
            Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 90 `
                -NotBeforeLocal $monitorNotBefore | Out-Null
        }
        else {
            Start-Sleep -Seconds $PostReconnectSettleSec
        }
    }

    Write-DwTestStep "Wait $($PeriodicWaitSec)s for periodic file check cycle"
    Start-Sleep -Seconds $PeriodicWaitSec

    Write-DwTestStep 'Assert allowed-folder file sanitizes to clean destination'
    $allowedClean = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $allowedName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($allowedClean)) {
        throw "Allowed file '$allowedName' did not reach clean output within $($CleanOutputTimeoutSec)s (periodic check should still process non-stop paths)."
    }
    Write-DwTestStep "OK - allowed clean output: $allowedClean"

    Write-DwTestStep 'Assert stop-folder files are not sanitized (still in incoming)'
    foreach ($path in @($stopPath, $nestedStopPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "NCP-7377 regression: file under stop path was removed/sanitized but should be skipped by stop regex: $path"
        }
    }
    Write-DwTestStep 'OK - files under stop folders remain in incoming'

    $stopCleanHit = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $stopName -TimeoutSec 3
    if (-not [string]::IsNullOrWhiteSpace($stopCleanHit)) {
        throw "NCP-7377 regression: stop-folder file '$stopName' appeared on clean destination: $stopCleanHit"
    }

    $nestedCleanHit = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $nestedStopName -TimeoutSec 3
    if (-not [string]::IsNullOrWhiteSpace($nestedCleanHit)) {
        throw "NCP-7377 regression: nested stop-folder file '$nestedStopName' appeared on clean destination: $nestedCleanHit"
    }
    Write-DwTestStep 'OK - no clean output for stop-folder files'

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
        $evidenceOnFailure = Add-DirWatcherE2eFailureEvidenceIfEligible -EvidenceZipLabel 'DW-NCP7377' `
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
