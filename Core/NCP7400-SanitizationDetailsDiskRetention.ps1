#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7400: SanitizationDetails on disk are removed when CleanSanitizationsRelatedTables runs.

.DESCRIPTION
  Seeds an old dated folder under TempFiles\SanitizationDetails, sets a short DB retention window,
  triggers CleanSanitizationsRelatedTables via debug runscheduledtask, and asserts the old tree is gone.

  Prerequisites:
    - Core running with EnableDebugInterface = True (https://localhost:4504/debug/hook).
    - Disk stored-files mode (not S3).
    - This node is main server.
    - Running Core binary includes NCP-7400 changes (debug runscheduledtask + disk cleanup fix). Restart Core after build.

  The script sets TimeOfDayForNotificationCleanup (Nightly Maintenance Hour) to a non-disabled value so
  CleanSanitizationsRelatedTables does not no-op when run via runscheduledtask.

.EXAMPLE
  .\NCP7400-SanitizationDetailsDiskRetention.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed. Test Platform outcome follows $script:ScenarioPassed after reporting.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $CoreExe = '',
    [switch] $SkipLocalCoreRestart,
    [int] $DaysToKeepSanitizationRecords = 1,
    [string] $NightlyMaintenanceHour = '3:00',
    [string] $OldSeedYear = '2020',
    [string] $OldSeedMonth = '06',
    [string] $OldSeedDay = '15',
    [switch] $SkipSystemPropertiesStack
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-CoreDeployRequirements
}

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')

$commonRoot = Join-Path $PSScriptRoot 'Common'
$script:CoreE2eReportScript = Join-Path $commonRoot 'Report-CoreE2eTestPlatformResult.ps1'
. $script:CoreE2eReportScript
. (Join-Path $commonRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $commonRoot 'CoreE2eTestLifecycle.ps1')

$script:TestId = 'Core-NCP7400'
$script:TestTitle = 'SanitizationDetails disk retention cleanup'
$script:SystemPropsStackPushed = $false
$hookUrl = $null
$seedFolder = $null
$detailsRoot = $null
$script:EvidenceZipPath = $null

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Join-SanitizationDetailsPath {
    param(
        [Parameter(Mandatory)]
        [string] $Root,
        [Parameter(Mandatory)]
        [string[]] $Segments
    )

    $path = $Root
    foreach ($segment in $Segments) {
        $path = Join-Path -Path $path -ChildPath $segment
    }

    return [System.IO.Path]::GetFullPath($path)
}

Initialize-CoreE2eScenarioState -TestId $script:TestId

try {
    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-TestStep "Debug hook: $hookUrl"
    Wait-CoreE2eReady -HookUrl $hookUrl -CoreExe $CoreExe | Out-Null

    if (-not $SkipSystemPropertiesStack) {
        Write-TestStep 'pushsystempropertystate'
        Push-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        $script:SystemPropsStackPushed = $true
    }

    Write-TestStep "importsystemproperties (retention, maintenance hour, disk storage)"
    Import-CoreE2eSystemProperties -HookUrl $hookUrl -SystemProperties @(
        @{ name = 'DaysToKeepDatabaseRecords'; propValue = [string]$DaysToKeepSanitizationRecords }
        @{ name = 'TimeOfDayForNotificationCleanup'; propValue = $NightlyMaintenanceHour }
        @{ name = 'StoredFilesStorageType'; propValue = 'File System' }
    ) | Out-Null

    Ensure-CoreE2eServerWithRunScheduledTaskHook -HookUrl $hookUrl -CoreExe $CoreExe `
        -SkipLocalCoreRestart:$SkipLocalCoreRestart

    Write-TestStep 'runscheduledtask (probe storage + sanitizationDetailsRoot)'
    $probe = Invoke-CoreE2eRunScheduledTask -HookUrl $hookUrl -ScheduledTaskName 'CleanSanitizationsRelatedTables'
    if (-not (Test-CoreE2eDebugHookBoolean -Value $probe.scheduledTaskRan)) {
        throw "runscheduledtask did not execute: $($probe.scheduledTaskSkippedReason)"
    }

    if ($probe.sanitizationDetailsStorage -eq 's3') {
        throw 'Not applicable: Core uses S3 for stored files; this test requires disk SanitizationDetails.'
    }

    $detailsRoot = [string]$probe.sanitizationDetailsRoot
    if ([string]::IsNullOrWhiteSpace($detailsRoot)) {
        throw 'runscheduledtask did not return sanitizationDetailsRoot.'
    }

    $detailsRoot = [System.IO.Path]::GetFullPath($detailsRoot)
    if (-not (Test-Path -LiteralPath $detailsRoot)) {
        New-Item -ItemType Directory -Path $detailsRoot -Force | Out-Null
    }

    $seedFolder = Join-SanitizationDetailsPath -Root $detailsRoot -Segments @(
        $OldSeedYear, $OldSeedMonth, $OldSeedDay, '10', '30', '00', 'lab-NCP7400'
    )
    New-Item -ItemType Directory -Path $seedFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $seedFolder 'SanitizationDetails.json') -Value '{"SanitizationId":7400}' -Encoding UTF8
    Write-TestStep "Seeded old folder: $seedFolder"

    $utcNow = [DateTime]::UtcNow
    $recentFolder = Join-SanitizationDetailsPath -Root $detailsRoot -Segments @(
        $utcNow.ToString('yyyy'),
        $utcNow.ToString('MM'),
        $utcNow.ToString('dd'),
        '23', '59', '59', 'lab-NCP7400-recent'
    )
    New-Item -ItemType Directory -Path $recentFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $recentFolder 'SanitizationDetails.json') -Value '{"SanitizationId":7401}' -Encoding UTF8
    Write-TestStep "Seeded recent control folder: $recentFolder"

    Write-TestStep 'runscheduledtask (cleanup after seed)'
    $run = Invoke-CoreE2eRunScheduledTask -HookUrl $hookUrl -ScheduledTaskName 'CleanSanitizationsRelatedTables'
    if (-not (Test-CoreE2eDebugHookBoolean -Value $run.scheduledTaskRan)) {
        throw "Second runscheduledtask did not execute: $($run.scheduledTaskSkippedReason)"
    }

    if (Test-Path -LiteralPath $seedFolder) {
        throw "Old SanitizationDetails folder still exists after cleanup: $seedFolder"
    }

    if (-not (Test-Path -LiteralPath $recentFolder)) {
        throw "Recent control folder was removed unexpectedly: $recentFolder"
    }

    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
}
finally {
    if ($script:SystemPropsStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-TestStep 'popsystempropertystate'
            Pop-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "popsystempropertystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed -and $seedFolder -and (Test-Path -LiteralPath $seedFolder)) {
        try {
            $yearRoot = Join-Path $detailsRoot $OldSeedYear
            if (Test-Path -LiteralPath $yearRoot) {
                Remove-Item -LiteralPath $yearRoot -Recurse -Force
            }
        }
        catch {
            Write-Warning "Could not remove seed tree under '$detailsRoot': $($_.Exception.Message)"
        }
    }
}

$evidenceOnFailure = @()
if (-not $script:ScenarioPassed) {
    if ($seedFolder -and (Test-Path -LiteralPath $seedFolder)) {
        $evidenceOnFailure += $seedFolder
    }
    if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
        $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
        if ($coreLog) {
            $evidenceOnFailure += $coreLog
            Write-TestStep "Core log for evidence: $coreLog"
        }
    }
    if (@($evidenceOnFailure).Count -gt 0) {
        $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7400'
        if ($script:EvidenceZipPath) {
            Write-TestStep "Evidence zip: $($script:EvidenceZipPath)"
        }
    }
}

Complete-CoreE2eScenario -ReportScriptPath $script:CoreE2eReportScript `
    -TestId $script:TestId -TestTitle $script:TestTitle `
    -EvidencePathsOnFailure $evidenceOnFailure -EvidenceZipPath $script:EvidenceZipPath

Exit-CoreE2eScenario