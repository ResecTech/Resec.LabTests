#Requires -Version 5.1
<#
.SYNOPSIS
  DW-01 / NCP-7340: Incoming file moves to temp when sanitization starts (not left in source).

.DESCRIPTION
  Regression for NCP-7340: after a drop in the Directory Watcher incoming folder, the file must leave
  the source path within 10 seconds once processing starts (move to temp). Temp is not asserted
  (the copy is often removed within seconds after upload starts). The test then waits for clean SMB output.

  Lab setup:
    - Core with EnableDebugInterface=True (https://localhost:4504/debug/hook).
    - DirWatcher registered to Core and running (restart after policy import unless -SkipDirWatcherRestart).
    - Policy folders are created under -WorkRoot (default C:\test\DW-NCP7340-<guid>\).

  ---------------------------------------------------------------------------
  Core policy (unless -SkipPolicyImport):
    importpolicies on /debug/hook after pushpolicystate
    Policy name:     NCP7340-dw-lab (placeholder id 9340; Core remaps to DB id)
    Assignment rule: debug-dir-watcher-ncp7340 (agent_type dir_watcher)
    Policy raw:      NCP7344 office no-CDR lab base (pass-through sanitize)
                     + Directory Watcher Settings (incoming / temp / rejected)
                     + SMB Destination facet (clean out store dw7340-out)
  ---------------------------------------------------------------------------

  Version skew (e.g. DW 26.2 vs Core 26.1) is a manual lab matrix item — run this script on the
  combination under test; it asserts folder behavior regardless of train pairing.

.PARAMETER SkipPolicyImport
  Use when incoming/temp/rejected/clean paths already match an active DW policy (-WorkRoot required).

.PARAMETER SkipDirWatcherRestart
  Do not stop/start DirWatcher after policy import (DW already running with matching folders).

.PARAMETER UseAgentCommNudge
  Run Core agentcommblockon/off after import and after DW restart. Default is off; import + DW restart is enough and avoids extra disconnect races on older builds.

.EXAMPLE
  .\DW-01-NCP7340-SourceMovedToTempOnSanitize.ps1

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
    [switch] $SkipDirWatcherRestart,
    [switch] $UseAgentCommNudge,
    [int] $SourceClearedTimeoutSec = 10,
    [int] $CleanOutputTimeoutSec = 60,
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
$dropPath = $null
$script:TestId = 'DW-NCP7340'
$script:TestTitle = 'DirWatcher source cleared to temp on sanitize start (NCP-7340)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Write-DwNcp7340CorePolicyHighlight {
    param([switch] $SkipPolicyImport)

    if ($SkipPolicyImport) {
        Write-Host '---------------------------------------------------------------------------'
        Write-Host 'Core policy: (unchanged) -SkipPolicyImport; using whatever policy Core/DW already have'
        Write-Host '---------------------------------------------------------------------------'
        return
    }

    Write-Host '---------------------------------------------------------------------------'
    Write-Host 'Core policy: importpolicies via /debug/hook (pushpolicystate first, pop in finally)'
    Write-Host "  Policy name:     $($script:DwNcp7340LabPolicyName) (placeholder id $($script:DwNcp7340LabPolicyPlaceholderId))"
    Write-Host "  Assignment rule: $($script:DwNcp7340DefaultAssignmentRuleName) -> agent_type dir_watcher"
    Write-Host '  Policy raw:      NCP7344 office no-CDR lab base + Directory Watcher Settings'
    Write-Host '                   (incoming / temp / rejected) + SMB Destination (clean, store dw7340-out)'
    Write-Host '---------------------------------------------------------------------------'
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
    Write-DwTestStep "  incoming: $($layout.Incoming)"
    Write-DwTestStep "  temp:     $($layout.Temp)"
    Write-DwTestStep "  clean:    $($layout.Clean)"

    # ---------------------------------------------------------------------------
    # Core policy: see Write-DwNcp7340CorePolicyHighlight and comment-based help above.
    # ---------------------------------------------------------------------------
    Write-DwNcp7340CorePolicyHighlight -SkipPolicyImport:$SkipPolicyImport

    if (-not $SkipPolicyImport) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true

        Write-DwTestStep 'importpolicies (NCP-7340 DirWatcher lab policy)'
        Import-DwNcp7340LabPolicy -HookUrl $hookUrl `
            -IncomingRoot $layout.Incoming -TempRoot $layout.Temp `
            -RejectedRoot $layout.Rejected -CleanRoot $layout.Clean | Out-Null

        if (-not $SkipDirWatcherRestart) {
            $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
            Stop-DirWatcherE2eProcesses
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

    $dropName = 'ncp7340-' + [Guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($fixtureFull)
    $dropPath = Join-Path $layout.Incoming $dropName
    $fixtureLength = (Get-Item -LiteralPath $fixtureFull).Length

    Write-DwTestStep "Drop fixture -> $dropPath"
    Copy-Item -LiteralPath $fixtureFull -Destination $dropPath -Force

    Write-DwTestStep 'Assert source file leaves incoming folder (move to temp on sanitize start)'
    $sourceCleared = Wait-DirWatcherE2eFileLeavesPath -FilePath $dropPath -TimeoutSec $SourceClearedTimeoutSec
    if (-not $sourceCleared) {
        throw "NCP-7340 regression: file still in source folder after ${SourceClearedTimeoutSec}s: $dropPath"
    }
    Write-DwTestStep 'OK — source path cleared'

    $tempHit = Wait-DirWatcherE2eTempContainsCopy -TempRoot $layout.Temp -ExpectedLength $fixtureLength -TimeoutSec 0
    if (-not [string]::IsNullOrWhiteSpace($tempHit)) {
        Write-DwTestStep "Observed temp copy (informational): $tempHit"
    }
    else {
        Write-DwTestStep 'Temp copy not visible after source cleared (normal once upload/sanitize starts)'
    }

    Write-DwTestStep 'Wait for sanitized output in clean folder'
    $outputPath = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $dropName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        throw "Timed out waiting for clean output '$dropName' under $($layout.Clean) (${CleanOutputTimeoutSec}s)."
    }
    Write-DwTestStep "OK — clean output: $outputPath"

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
        if (@($evidenceOnFailure).Count -gt 0) {
            try {
                $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'DW-NCP7340'
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
