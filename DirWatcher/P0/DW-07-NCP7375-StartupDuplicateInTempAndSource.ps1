#Requires -Version 5.1
<#
.SYNOPSIS
  DW-07 / NCP-7375: Same file in incoming and temp at DW startup is sanitized once; temp is empty afterward.

.DESCRIPTION
  Regression for NCP-7375:
    1. Stop DirWatcher
    2. Seed the same file in incoming and temp
    3. Start DirWatcher with ProcessPreExistingFiles enabled
  Expected: incoming is processed, clean output appears, then temp is empty within a few seconds (no stale copy / file_1).

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.EXAMPLE
  .\DW-07-NCP7375-StartupDuplicateInTempAndSource.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $FixturePath = '',
    [string] $DirWatcherExe = '',
    [switch] $SkipPolicyImport,
    [int] $SourceClearedTimeoutSec = 90,
    [int] $CleanOutputTimeoutSec = 120,
    [int] $TempEmptyTimeoutSec = 15,
    [int] $PostStartSettleSec = 5
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
$tempSeedPath = $null
$script:TestId = 'DW-NCP7375'
$script:TestTitle = 'DirWatcher startup duplicate temp+source; temp empty after pass (NCP-7375)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-DwTestStep "Hook: $hookUrl"
    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-DwTestStep "Core version: $($versionInfo.version)"
    }

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot -DefaultWorkRootPrefix 'DW-NCP7375'
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"
    Write-DwTestStep "  incoming: $($layout.Incoming)"
    Write-DwTestStep "  temp:     $($layout.Temp)"
    Write-DwTestStep "  clean:    $($layout.Clean)"

    Stop-DirWatcherE2eProcesses
    Write-DwTestStep 'DirWatcher stopped (ticket repro step 1)'

    if (-not $SkipPolicyImport) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true

        Write-DwTestStep 'importpolicies (ProcessPreExistingFiles=1 for NCP-7375)'
        Import-DwNcp7340LabPolicy -HookUrl $hookUrl `
            -IncomingRoot $layout.Incoming -TempRoot $layout.Temp `
            -RejectedRoot $layout.Rejected -CleanRoot $layout.Clean `
            -ProcessPreExistingFiles:$true | Out-Null
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

    $dropName = 'ncp7375-' + [Guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($fixtureFull)
    $dropPath = Join-Path $layout.Incoming $dropName
    $tempSeedPath = Join-Path $layout.Temp $dropName

    Write-DwTestStep 'Seed same file in incoming and temp before DW start (ticket repro steps 2-3)'
    Copy-Item -LiteralPath $fixtureFull -Destination $dropPath -Force
    Copy-Item -LiteralPath $fixtureFull -Destination $tempSeedPath -Force

    $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
    Write-DwTestStep "Start DirWatcher: $dwExe"
    Start-DirWatcherE2eProcess -ExePath $dwExe
    if (-not (Test-DirWatcherE2eProcessRunning)) {
        throw 'DirWatcher failed to start.'
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

    Start-Sleep -Seconds $PostStartSettleSec
    Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $layout.Incoming -TimeoutSec 120 | Out-Null

    $logMark = "DW-07 sanitize $dropName"
    $dwDebugBaseUrl = ''
    if (Get-Command Get-DirWatcherE2eDebugBaseUrl -ErrorAction SilentlyContinue) {
        $dwDebugBaseUrl = Get-DirWatcherE2eDebugBaseUrl
    }
    Write-DirWatcherE2eDebugLogMark -Message $logMark -BaseUrl $dwDebugBaseUrl

    Write-DwTestStep 'Assert incoming copy is cleared'
    $sourceCleared = Wait-DirWatcherE2eFileLeavesPath -FilePath $dropPath -TimeoutSec $SourceClearedTimeoutSec
    if (-not $sourceCleared) {
        throw "NCP-7375: file still in incoming after $($SourceClearedTimeoutSec)s: $dropPath"
    }

    Write-DwTestStep 'Wait for sanitized output in clean folder'
    $outputPath = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $dropName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        throw "Timed out waiting for clean output '$dropName' under $($layout.Clean) ($($CleanOutputTimeoutSec)s)."
    }
    Write-DwTestStep "OK - clean output: $outputPath"

    Write-DwTestStep 'Assert no duplicate staged name in temp (no file_1 leftover from stale copy)'
    $dupStaged = @(Get-DirWatcherE2eTempFiles -TempRoot $layout.Temp | Where-Object {
            $_.BaseName -match '_\d+$'
        })
    if ($dupStaged.Count -gt 0) {
        $paths = ($dupStaged | ForEach-Object { $_.FullName }) -join '; '
        throw "NCP-7375 regression: duplicate staged temp file(s): $paths"
    }

    Write-DwTestStep "Assert temp folder is empty shortly after clean output (timeout $($TempEmptyTimeoutSec)s)"
    $tempEmpty = Wait-DirWatcherE2eTempFolderEmpty -TempRoot $layout.Temp -TimeoutSec $TempEmptyTimeoutSec
    if (-not $tempEmpty) {
        $left = @(Get-DirWatcherE2eTempFiles -TempRoot $layout.Temp)
        $paths = ($left | ForEach-Object { $_.FullName }) -join '; '
        throw "NCP-7375: temp folder not empty after pass. Files: $paths"
    }
    Write-DwTestStep 'OK - temp folder empty'

    Write-DwTestStep 'Assert DirWatcher log has no duplicate-outcome or temp-mapper warnings'
    Assert-DirWatcherE2eSanitizeLogHasNoWarnings -LogMarkMessage $logMark -FileNameHint $dropName `
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
        $evidenceOnFailure = Add-DirWatcherE2eFailureEvidenceIfEligible -EvidenceZipLabel 'DW-NCP7375' `
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
        Stop-DirWatcherE2eProcessesForScenarioTeardown
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