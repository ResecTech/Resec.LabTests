#Requires -Version 5.1
<#
.SYNOPSIS
  DW-08 / NCP-7385: Bulk incoming files complete after Core comm drop during FileContentRequired uploads.

.DESCRIPTION
  Regression for NCP-7385: dropping ~**1000** small files into incoming (QA **1K** unzip scale) can leave
  sanitizations stuck in **File content required** when Core drops the agent session while PutFile uploads are
  in flight, or when bulk san requests starve file-content on the wire. Needs Gateway **≥ 26.2.115** (high-priority
  content + deferred stream release) and DirWatcher ingest-slot hold (NCP-7385 DW build).

  This script:
    1. Drops many small fixture copies into incoming in quick succession (default 1000).
    2. Pulses Core agentcommblockon/off during ingest (simulated comm loss while uploads are active).
    3. Waits for DirWatcher to reconnect and for every dropped file to reach clean SMB output.
    4. For small bulk counts (<= 50), asserts Gateway logs do not show orphan sanitization responses during comm drop.
       At 1k scale, pass criteria is all clean outputs (orphan log lines during agentcommblockon are expected noise).

  Prerequisites:
    - Core EnableDebugInterface; DirWatcher debug on port 4506 (scenario sets DIRWATCHER_ENABLE_DEBUG_INTERFACE).
    - DirWatcher on a build with NCP-7385 slot hold; Gateway >= 26.2.115 on the feed.

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.PARAMETER BulkFileCount
  Number of distinct small files to drop (each a copy of a tiny allowed fixture). Default **1000** (Ben 1K repro).

.PARAMETER CommBlockAfterDrop
  After this many files are copied to incoming, pulse Core agentcommblockon (default 2).

.PARAMETER CommHoldSeconds
  How long Core agentcommblockon stays active mid-scenario.

.PARAMETER IngestIdleTimeoutSec
  Seconds to wait for DW tracking ingest idle (in-flight / Core dest writes) before asserting clean output (default 3600 for 1k).

.PARAMETER CleanOutputTimeoutSec
  Seconds to wait for all bulk files under the SMB clean folder (default 3600 for 1k).

.PARAMETER CleanProgressEverySec
  Progress log interval while waiting for clean SMB outputs (0 = off).

.PARAMETER AssertNoOrphanJobContext
  When set, fail if Gateway logs contain "Could not find matching JobContext" after the run logmark.
  Default: on when BulkFileCount <= 50; off for 1k (use with -BulkFileCount 8 for comm-drop orphan regression).

.EXAMPLE
  .\DW-08-NCP7385-BulkIncomingCompletesAfterCommDrop.ps1

.EXAMPLE
  Quick smoke with comm-drop orphan assert:
  .\DW-08-NCP7385-BulkIncomingCompletesAfterCommDrop.ps1 -BulkFileCount 8 -CleanOutputTimeoutSec 300 -IngestIdleTimeoutSec 300 -AssertNoOrphanJobContext

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
    [int] $BulkFileCount = 1000,
    [int] $CommBlockAfterDrop = 2,
    [int] $CommHoldSeconds = 3,
    [int] $CommSettleSeconds = 10,
    [int] $PostReconnectWaitSec = 120,
    [int] $IngestIdleTimeoutSec = 3600,
    [int] $CleanOutputTimeoutSec = 3600,
    [int] $CleanProgressEverySec = 30,
    [int] $TrackingClearTimeoutSec = 300,
    [switch] $AssertNoOrphanJobContext
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
$script:TestTitle = 'DirWatcher 1k small-file bulk incoming completes after comm drop (NCP-7385)'
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

function Get-DwNcp7385OrphanJobContextLogLines {
    param(
        [Parameter(Mandatory)]
        [string] $LogMarkMessage,
        [string] $DebugBaseUrl = '',
        [DateTimeOffset] $NotBeforeUtc = [DateTimeOffset]::MinValue
    )

    $dwLines = @(Get-DirWatcherE2eMergedLogLines -DebugBaseUrl $DebugBaseUrl -NotBeforeUtc $NotBeforeUtc)
    $dwLines = @(Get-DirWatcherE2eLogSliceAfterMark -Lines $dwLines -LogMarkMessage $LogMarkMessage)
    return @($dwLines | Where-Object { $_ -like '*Could not find matching JobContext*' })
}

function Assert-DwNcp7385NoOrphanJobContextInDwLog {
    param(
        [Parameter(Mandatory)]
        [string] $LogMarkMessage,
        [string] $DebugBaseUrl = '',
        [DateTimeOffset] $NotBeforeUtc = [DateTimeOffset]::MinValue
    )

    $orphan = @(Get-DwNcp7385OrphanJobContextLogLines -LogMarkMessage $LogMarkMessage `
        -DebugBaseUrl $DebugBaseUrl -NotBeforeUtc $NotBeforeUtc)
    if ($orphan.Count -gt 0) {
        throw "NCP-7385: DirWatcher log shows $($orphan.Count) orphan sanitization response(s) (JobContext missing after comm drop)."
    }

    Write-DwTestStep 'OK - no orphan JobContext log lines after comm drop'
}

try {
    if ($BulkFileCount -lt 2) {
        throw 'BulkFileCount must be at least 2.'
    }

    if ($CommBlockAfterDrop -lt 1 -or $CommBlockAfterDrop -gt $BulkFileCount) {
        throw "CommBlockAfterDrop must be between 1 and BulkFileCount ($BulkFileCount)."
    }

    $assertOrphanJobContext = if ($PSBoundParameters.ContainsKey('AssertNoOrphanJobContext')) {
        [bool]$AssertNoOrphanJobContext
    }
    else {
        $BulkFileCount -le 50
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
    $templateCandidates = @(
        (Join-Path $fixturesRoot 'FileTypeDetection\sample.txt'),
        (Join-Path $fixturesRoot 'CDR\CSV\DDE.csv'),
        (Join-Path $fixturesRoot 'Allowed\Passed\interface vlan shutdown.txt')
    )
    $templatePath = @($templateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)[0]
    if ([string]::IsNullOrWhiteSpace($templatePath)) {
        throw 'No small lab fixtures found under Fixtures\ (need at least one file).'
    }

    $ext = [System.IO.Path]::GetExtension($templatePath)
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $ext = '.txt'
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $logMark = "DW-08 NCP-7385 bulk run=$runId count=$BulkFileCount"
    Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Mark $logMark
    Write-DirWatcherE2eDebugLogMark -Message $logMark -BaseUrl $dwDebugBaseUrl

    $drops = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $BulkFileCount; $i++) {
        $name = "ncp7385-$runId-$i$ext"
        $dest = Join-Path $layout.Incoming $name
        $drops.Add([pscustomobject]@{ Name = $name; IncomingPath = $dest }) | Out-Null
    }

    Write-DwTestStep "Bulk drop $($drops.Count) small files (template: $templatePath); comm block after drop #$CommBlockAfterDrop for ${CommHoldSeconds}s"
    $dropped = 0
    $progressEvery = if ($BulkFileCount -ge 100) { 100 } else { 0 }
    foreach ($item in $drops) {
        [System.IO.File]::Copy($templatePath, $item.IncomingPath, $true)
        $dropped++
        if ($progressEvery -gt 0 -and ($dropped % $progressEvery) -eq 0) {
            Write-DwTestStep "Bulk drop progress: $dropped / $($drops.Count)"
        }

        if ($dropped -eq $CommBlockAfterDrop) {
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

    $ingestProgressSec = if ($BulkFileCount -ge 100) { 30 } else { 15 }
    Wait-DirWatcherE2eGlobalIngestIdle -DebugBaseUrl $dwDebugBaseUrl -TimeoutSec $IngestIdleTimeoutSec `
        -RequireMapperIdle -ProgressEverySec $ingestProgressSec | Out-Null

    $dropNames = @($drops | ForEach-Object { $_.Name })
    $cleanFound = Wait-DirWatcherE2eAllCleanOutputs -CleanRoot $layout.Clean -FileNames $dropNames `
        -TimeoutSec $CleanOutputTimeoutSec -ProgressEverySec $CleanProgressEverySec
    $missingClean = @($dropNames | Where-Object { -not $cleanFound.ContainsKey($_) })
    if ($dropNames.Count -le 20) {
        foreach ($name in $dropNames) {
            if ($cleanFound.ContainsKey($name)) {
                Write-DwTestStep "OK clean: $($cleanFound[$name])"
            }
        }
    }
    else {
        Write-DwTestStep "OK clean: $($cleanFound.Count)/$($dropNames.Count) files under $($layout.Clean)"
    }

    if ($missingClean.Count -gt 0) {
        throw "NCP-7385: $($missingClean.Count) file(s) did not reach clean output within ${CleanOutputTimeoutSec}s: $($missingClean -join ', ')"
    }

    if ($assertOrphanJobContext) {
        Assert-DwNcp7385NoOrphanJobContextInDwLog -LogMarkMessage $logMark -DebugBaseUrl $dwDebugBaseUrl `
            -NotBeforeUtc $script:TestStartedAtUtc
    }
    else {
        $orphanLines = @(Get-DwNcp7385OrphanJobContextLogLines -LogMarkMessage $logMark -DebugBaseUrl $dwDebugBaseUrl `
            -NotBeforeUtc $script:TestStartedAtUtc)
        if ($orphanLines.Count -gt 0) {
            Write-DwTestStep "Note: $($orphanLines.Count) orphan JobContext log line(s) during comm block (not asserted at BulkFileCount=$BulkFileCount)"
        }
    }

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