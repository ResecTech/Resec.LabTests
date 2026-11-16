#Requires -Version 5.1
<#
.SYNOPSIS
  Shared scenario state, Test Platform reporting, and exit code for Scan Agent E2E scripts.
#>
Set-StrictMode -Version Latest

function Initialize-ScanAgentE2eScenarioState {
    param(
        [Parameter(Mandatory)]
        [string] $TestId
    )

    $script:ScenarioPassed = $false
    $script:ScenarioFailureMessage = $null
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $TestId
}

function Get-ScanAgentE2eScenarioFailureMessageForReport {
    if ($script:ScenarioPassed) {
        return $script:ScenarioFailureMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ScenarioFailureMessage)) {
        return $script:ScenarioFailureMessage
    }

    return 'Scenario failed (no exception message captured).'
}

function Report-ScanAgentE2eScenarioToTestPlatform {
    param(
        [Parameter(Mandatory)]
        [string] $ReportScriptPath,
        [Parameter(Mandatory)]
        [string] $TestId,
        [Parameter(Mandatory)]
        [string] $TestTitle,
        [string[]] $EvidencePathsOnFailure = @()
    )

  if (-not (Test-Path -LiteralPath $ReportScriptPath)) {
        Write-Warning "Test Platform report script not found: $ReportScriptPath"
        return
    }

    $failureMessage = Get-ScanAgentE2eScenarioFailureMessageForReport
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $ReportScriptPath `
        -TestId $TestId -TestTitle $TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $failureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $EvidencePathsOnFailure
}

function Exit-ScanAgentE2eScenario {
    if ($script:ScenarioPassed) {
        exit 0
    }

    exit 1
}