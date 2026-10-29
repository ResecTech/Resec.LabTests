#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7344: Office files with CDR disabled via Core /debug/hook sanitize (no Scan Agent).

.DESCRIPTION
  Imports a lab policy with CDR/transformations disabled (same shape as SA-09 pass-through),
  runs Office fixtures through debug sanitize, and asserts sanitization does not fail with
  7-Zip "not a valid archive" extraction errors (NCP-7344 regression).

  Prerequisites:
    - Core running with EnableDebugInterface = True (default hook https://localhost:4504/debug/hook).
    - At least one deployment row in the DB (register any agent once, or pass -DeploymentId).
    - Default lab policy JSON under Core\Policies\ (debug importpolicies), unless -SkipPolicyImport -PolicyId.

.PARAMETER SkipPolicyImport
  Use an existing policy id (-PolicyId) without push/import/pop.

.PARAMETER PolicyImportJson
  Override path to importpolicies JSON (policies + policyAssociations). Default: Core\Policies\NCP7344-office-nocdr-lab.importpolicies.json

.EXAMPLE
  .\NCP7344-OfficeNoCdrSanitize.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed. On failure, attaches Core Serilog + artifacts to Test Platform when configured.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $FixtureRoot = '',
    [string] $OutputRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7344-office-nocdr-lab',
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
    [switch] $SkipPolicyStack
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-CoreDeployRequirements
}

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')

$commonRoot = Join-Path $PSScriptRoot 'Common'
$script:CoreE2eReportScript = Join-Path $commonRoot 'Report-CoreE2eTestPlatformResult.ps1'
. $script:CoreE2eReportScript
. (Join-Path $commonRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7344Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7344'
$script:TestTitle = 'Office no-CDR debug sanitize (NCP-7344)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Assert-Ncp7344SanitizeOutcome {
    param(
        [Parameter(Mandatory)]
        $Result,
        [Parameter(Mandatory)]
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $FileLabel
    )

    if ($Result.timedOut -eq $true) {
        throw "Timed out sanitizing '$FileLabel' (sanitizationId=$($Result.sanitizationId))."
    }

    $outcome = [string]$Result.outcome
    $details = [string]$Result.outcomeDetails

    foreach ($forbidden in @($FixtureSpec.forbiddenOutcomes)) {
        if ($outcome -eq [string]$forbidden) {
            throw "Unexpected outcome '$outcome' for '$FileLabel'. Details: $details"
        }
    }

    foreach ($pattern in @($FixtureSpec.forbiddenOutcomeDetailsPatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($details) -and $details -match $pattern) {
            throw "Outcome details for '$FileLabel' matched forbidden pattern '$pattern'. Outcome=$outcome Details=$details"
        }
    }

    if ($outcome -eq 'OutcomeBlockedTransformationFailed' -or [int]$Result.outcomeValue -eq 160) {
        throw "Transformation/extraction failed for '$FileLabel'. Details: $details"
    }

    $expected = @($FixtureSpec.expectedOutcomes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($expected).Count -gt 0 -and ($expected -notcontains $outcome)) {
        throw "Unexpected outcome '$outcome' for '$FileLabel' (expected one of: $($expected -join ', ')). Details: $details"
    }

    Write-TestStep "OK '$FileLabel' -> outcome=$outcome elapsedMs=$($Result.elapsedMs) durationMs=$($Result.durationMs)"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $fixtureRoot = Resolve-CoreE2eFixtureRoot -Override $FixtureRoot -CallingScriptDirectory $PSScriptRoot `
        -RelativeFromFixturesRoot 'Office\NCP-7344'
    $manifestPath = Join-Path $fixtureRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "manifest.json not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixtureSpecs = @($manifest.fixtures)
    if ($fixtureSpecs.Count -eq 0) {
        throw 'manifest.json contains no fixtures.'
    }

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7344-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Fixtures: $fixtureRoot"
    Write-TestStep "Output: $outputRoot"

    Write-TestStep 'Wait for Core ready'
    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-TestStep "Core version: $($versionInfo.version)"
    }

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        $jsonPath = Get-Ncp7344OfficeNoCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies from JSON: $jsonPath"
        Import-Ncp7344OfficeNoCdrLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    foreach ($spec in $fixtureSpecs) {
        $fileName = [string]$spec.file
        $inputPath = Join-Path $fixtureRoot $fileName
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "Fixture file missing: $inputPath"
        }

        $outputPath = Join-Path $outputRoot $fileName
        Write-TestStep "sanitize: $fileName"
        $sanitizeParams = @{
            HookUrl        = $hookUrl
            FilePath       = $inputPath
            PolicyId       = $resolvedPolicyId
            OutputPath     = $outputPath
            TimeoutSeconds = $SanitizeTimeoutSec
        }
        if ($DeploymentId -gt 0) {
            $sanitizeParams.DeploymentId = $DeploymentId
        }

        $result = Invoke-CoreE2eSanitizeFile @sanitizeParams
        Assert-Ncp7344SanitizeOutcome -Result $result -FixtureSpec $spec -FileLabel $fileName

        if ($result.outputPath -and (Test-Path -LiteralPath $result.outputPath -PathType Leaf)) {
            Write-TestStep "Output written: $($result.outputPath) ($($result.outputPathNote))"
        }
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
        if ($outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
            $evidenceOnFailure += $outputRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
            $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
            if ($coreLog) {
                $evidenceOnFailure += $coreLog
                Write-TestStep "Core log for evidence: $coreLog"
            }
        }
        if (@($evidenceOnFailure).Count -gt 0) {
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7344'
            if ($script:EvidenceZipPath) {
                Write-TestStep "Evidence zip: $($script:EvidenceZipPath)"
            }
        }
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:CoreE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure `
        -EvidenceZipPath $script:EvidenceZipPath

    if ($script:PolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-TestStep 'poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        try {
            Remove-Item -LiteralPath $outputRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove output folder '$outputRoot': $($_.Exception.Message)"
        }
    }
    elseif (-not $script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        Write-Host "Output artifacts left at: $outputRoot"
    }
}
