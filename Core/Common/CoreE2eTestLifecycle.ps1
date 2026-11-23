#Requires -Version 5.1
<#
.SYNOPSIS
  Shared scenario state, Test Platform reporting, and exit code for Core E2E scripts.
#>
Set-StrictMode -Version Latest

function Initialize-CoreE2eScenarioState {
    param(
        [Parameter(Mandatory)]
        [string] $TestId
    )

    $script:ScenarioPassed = $false
    $script:ScenarioFailureMessage = $null
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $TestId
}

function Get-CoreE2eScenarioFailureMessageForReport {
    if ($script:ScenarioPassed) {
        return $script:ScenarioFailureMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ScenarioFailureMessage)) {
        return $script:ScenarioFailureMessage
    }

    return 'Scenario failed (no exception message captured).'
}

function Test-CoreE2eDebugHookBoolean {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -eq $true) {
        return $true
    }

    if ($Value -is [string] -and $Value.Equals('true', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $false
}

function Complete-CoreE2eScenario {
    param(
        [Parameter(Mandatory)]
        [string] $ReportScriptPath,
        [Parameter(Mandatory)]
        [string] $TestId,
        [Parameter(Mandatory)]
        [string] $TestTitle,
        [string[]] $EvidencePathsOnFailure = @(),
        [string] $EvidenceZipPath
    )

    $failureMessage = Get-CoreE2eScenarioFailureMessageForReport
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $ReportScriptPath `
        -TestId $TestId -TestTitle $TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $failureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $EvidencePathsOnFailure `
        -EvidenceZipPath $EvidenceZipPath
}

function Exit-CoreE2eScenario {
    if ($script:ScenarioPassed) {
        Write-Host 'Scenario passed.'
        exit 0
    }

    $message = Get-CoreE2eScenarioFailureMessageForReport
    Write-Error "Scenario failed: $message"
    exit 1
}