#Requires -Version 5.1
<#
.SYNOPSIS
  DW-08 / NCP-7385: Bulk incoming files complete after Core comm drop during FileContentRequired uploads.

.DESCRIPTION
  Regression for NCP-7385: copying several files into the Directory Watcher incoming root at once can leave
  sanitizations stuck in **File content required** when Core drops the agent session while PutFile uploads are
  in flight (grace period + aborted uploads). Gateway must keep DW job contexts across the short reconnect window
  (Resec.Agent.Gateway 26.2.107+).

  This script:
    1. Drops multiple small fixtures into incoming in quick succession.
    2. Pulses Core agentcommblockon/off during ingest (simulated comm loss while uploads are active).
    3. Waits for DirWatcher to reconnect and for every dropped file to reach clean SMB output.
    4. Asserts DirWatcher logs do not show orphan ContentRequired handling (missing JobContext).

  Prerequisites:
    - Core EnableDebugInterface; DirWatcher debug on port 4506 (scenario sets DIRWATCHER_ENABLE_DEBUG_INTERFACE).
    - DirWatcher built against Resec.Agent.Gateway >= 26.2.107 (NCP-7385 fix).

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.PARAMETER BulkFileCount
  Number of distinct files to drop (each copied from a small allowed fixture).

.PARAMETER CommHoldSeconds
  How long Core agentcommblockon stays active mid-scenario.

.PARAMETER IngestIdleTimeoutSec
  Seconds to wait for DW tracking ingest idle (in-flight / Core dest writes) before asserting clean output (default 10).

.PARAMETER CleanOutputTimeoutSec
  Seconds to wait for all bulk files under the SMB clean folder (default 10).

.EXAMPLE
  .\DW-08-NCP7385-BulkIncomingCompletesAfterCommDrop.ps1

.NOTES
  Jira: NCP-7385.
  Exit 0 = passed; exit 1 = failed; poppolicystate in finally when this script pushed policy state.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $DirWatcherExe = '',
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $LeaveDirWatcherRunning,
    [int] $BulkFileCount = 8,
    [int] $CommHoldSeconds = 3,
    [int] $CommSettleSeconds = 10,
    [int] $PostReconnectWaitSec = 120,
    [int] $IngestIdleTimeoutSec = 10,
    [int] $CleanOutputTimeoutSec = 10,
    [int] $TrackingClearTimeoutSec = 10
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
$script:TestId = 'DW-NCP7385'
$script:TestTitle = 'DirWatcher bulk incoming completes after comm drop during upload (NCP-7385)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Wait-DirWatcherNcp7385CoreReady {
    param(
        [string] $DebugBaseUrl = '',
        [int] $TimeoutSec = 120
    )

    Write-DwTestStep "Wait for DirWatcher connection.state core ready (timeout ${TimeoutSec}s)"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $lastDetail = '(no response)'
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $status = Invoke-DirWatcherE2eDebugHook -Command 'connection.state' -BaseUrl $DebugBaseUrl
        if (Test-DirWatcherE2eDebugCoreReady -Status $status) {
            $lastDetail = Format-DirWatcherE2eDebugConnectionSummary -Status $status
            Write-DwTestStep "DirWatcher core ready: $lastDetail"
            return $status
        }

        $lastDetail = Format-DirWatcherE2eDebugConnectionSummary -Status $status
        Start-Sleep -Seconds 2
    }

    throw "DirWatcher did not report core ready within ${TimeoutSec}s. Last: $lastDetail"
}

function Assert-DwNcp7385NoOrphanJobContextInDwLog {
    param(
        [Parameter(Mandatory)]
        [string] $LogMarkMessage,
        [string] $DebugBaseUrl = '',
        [DateTimeOffset] $NotBeforeUtc = [DateTimeOffset]::MinValue
    )

    $dwLines = @(Get-DirWatcherE2eMergedLogLines -DebugBaseUrl $DebugBaseUrl -NotBeforeUtc $NotBeforeUtc)
    $dwLines = @(Get-DirWatcherE2eLogSliceAfterMark -Lines $dwLines -LogMarkMessage $LogMarkMessage)
    $orphan = @($dwLines | Where-Object { $_ -like '*Could not find matching JobContext*' })
    if ($orphan.Count -gt 0) {
        throw "NCP-7385: DirWatcher log shows $($orphan.Count) orphan sanitization response(s) (JobContext missing after comm drop)."
    }
}

try {
    if ($BulkFileCount -lt 2) {
        throw 'BulkFileCount must be at least 2.'
    }

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
            -PolicyName 'NCP7385-dw-lab' | Out-Null

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
        else {
            Start-Sleep -Seconds $CommSettleSeconds
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    $fixturesRoot = Get-LabFixturesRoot
    $fixtureCandidates = @(
        (Join-Path $fixturesRoot 'FileTypeDetection\sample.txt'),
        (Join-Path $fixturesRoot 'CDR\CSV\DDE.csv'),
        (Join-Path $fixturesRoot 'Allowed\Passed\interface vlan shutdown.txt')
    )
    $fixtureSources = @($fixtureCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($fixtureSources.Count -eq 0) {
        throw 'No small lab fixtures found under Fixtures\ (need at least one file).'
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $logMark = "DW-08 NCP-7385 bulk run=$runId count=$BulkFileCount"
    Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Mark $logMark
    Write-DirWatcherE2eDebugLogMark -Message $logMark -BaseUrl $dwDebugBaseUrl

    $drops = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $BulkFileCount; $i++) {
        $src = $fixtureSources[$i % $fixtureSources.Count]
        $ext = [System.IO.Path]::GetExtension($src)
        if ([string]::IsNullOrWhiteSpace($ext)) {
            $ext = '.txt'
        }

        $name = "ncp7385-$runId-$i$ext"
        $dest = Join-Path $layout.Incoming $name
        $drops.Add([pscustomobject]@{ Name = $name; Source = $src; IncomingPath = $dest }) | Out-Null
    }

    Write-DwTestStep "Bulk drop $($drops.Count) files into incoming, then comm block ${CommHoldSeconds}s mid-ingest"
    $dropped = 0
    foreach ($item in $drops) {
        Copy-Item -LiteralPath $item.Source -Destination $item.IncomingPath -Force
        $dropped++
        if ($dropped -eq 2) {
            Write-DwTestStep 'agentcommblockon (during bulk ingest)'
            $on = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'agentcommblockon'
            Assert-CoreE2eDebugHookResponse -Response $on -Step 'agentcommblockon'
        }
    }

    if ($CommHoldSeconds -gt 0) {
        Start-Sleep -Seconds $CommHoldSeconds
    }

    Write-DwTestStep 'agentcommblockoff'
    $off = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'agentcommblockoff'
    Assert-CoreE2eDebugHookResponse -Response $off -Step 'agentcommblockoff'

    if ($CommSettleSeconds -gt 0) {
        Start-Sleep -Seconds $CommSettleSeconds
    }

    Wait-DirWatcherNcp7385CoreReady -DebugBaseUrl $dwDebugBaseUrl -TimeoutSec $PostReconnectWaitSec | Out-Null
    Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 60 | Out-Null

    Wait-DirWatcherE2eGlobalIngestIdle -DebugBaseUrl $dwDebugBaseUrl -TimeoutSec $IngestIdleTimeoutSec `
        -RequireMapperIdle -ProgressEverySec 0 | Out-Null

    $dropNames = @($drops | ForEach-Object { $_.Name })
    $cleanFound = Wait-DirWatcherE2eAllCleanOutputs -CleanRoot $layout.Clean -FileNames $dropNames `
        -TimeoutSec $CleanOutputTimeoutSec -ProgressEverySec 0
    $missingClean = @($dropNames | Where-Object { -not $cleanFound.ContainsKey($_) })
    foreach ($name in $dropNames) {
        if ($cleanFound.ContainsKey($name)) {
            Write-DwTestStep "OK clean: $($cleanFound[$name])"
        }
    }

    if ($missingClean.Count -gt 0) {
        throw "NCP-7385: $($missingClean.Count) file(s) did not reach clean output within ${CleanOutputTimeoutSec}s: $($missingClean -join ', ')"
    }

    Assert-DwNcp7385NoOrphanJobContextInDwLog -LogMarkMessage $logMark -DebugBaseUrl $dwDebugBaseUrl `
        -NotBeforeUtc $script:TestStartedAtUtc

    Write-DwTestStep 'tracking.state idle for last dropped file'
    $lastDrop = $drops[$drops.Count - 1]
    Wait-DirWatcherE2eIncomingTrackingCleared -IncomingPath $lastDrop.IncomingPath -DebugBaseUrl $dwDebugBaseUrl `
        -TimeoutSec $TrackingClearTimeoutSec -RequireMapperIdle | Out-Null

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
        $evidenceOnFailure = Add-DirWatcherE2eFailureEvidenceIfEligible -EvidenceZipLabel 'DW-NCP7385' `
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