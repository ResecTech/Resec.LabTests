#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7330: Image QR + Process QR Codes URLs via Core /debug/hook sanitize (no Scan Agent).

.DESCRIPTION
  Uses fixtures from Resec.LabTests\Fixtures\QR\NCP-7330, optionally imports a lab policy with
  Image:High transformations (includes Process QR Codes URLs), runs each file through debug sanitize,
  and asserts transformation does not fail (NCP-7330 regression).

  Prerequisites:
    - Core running with EnableDebugInterface = True (default hook https://localhost:4504/debug/hook).
    - At least one deployment row in the DB (register any agent once, or pass -DeploymentId).
    - WebMC export XML for policy template unless -SkipPolicyImport -PolicyId is set.

.PARAMETER SkipPolicyImport
  Use an existing policy id (-PolicyId) without push/import/pop.

.EXAMPLE
  .\NCP7330-QrImageSanitize.ps1 -PolicyTemplateXml C:\resec\ImportExport\ImportExport_latest.xml

.NOTES
  Exit 0 = passed; exit 1 = failed. See Core\README.md in Resec.LabTests.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $FixtureRoot = '',
    [string] $OutputRoot = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $LabPolicyName = 'NCP7330-qr-lab',
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
. (Join-Path $commonRoot 'CoreE2eNcp7330Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7330'
$script:TestTitle = 'Image QR allowed URL (debug sanitize)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Assert-Ncp7330SanitizeOutcome {
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
        throw "Transformation failed for '$FileLabel'. Details: $details"
    }

    Write-TestStep "OK '$FileLabel' -> outcome=$outcome elapsedMs=$($Result.elapsedMs) durationMs=$($Result.durationMs)"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $fixtureRoot = Resolve-CoreE2eFixtureRoot -Override $FixtureRoot -CallingScriptDirectory $PSScriptRoot
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
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7330-' + [Guid]::NewGuid().ToString('N'))
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

        $templatePath = Resolve-CoreE2ePolicyTemplateXml -OverridePath $PolicyTemplateXml
        Write-TestStep "importpolicies from template: $templatePath"
        $importBody = New-Ncp7330QrLabPolicyImportBody -TemplateXmlPath $templatePath `
            -TemplatePolicyName $TemplatePolicyName -PolicyName $LabPolicyName
        Import-CoreE2ePolicies -HookUrl $hookUrl -ImportBody $importBody | Out-Null

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
            HookUrl         = $hookUrl
            FilePath        = $inputPath
            PolicyId        = $resolvedPolicyId
            OutputPath      = $outputPath
            TimeoutSeconds  = $SanitizeTimeoutSec
        }
        if ($DeploymentId -gt 0) {
            $sanitizeParams.DeploymentId = $DeploymentId
        }

        $result = Invoke-CoreE2eSanitizeFile @sanitizeParams
        Assert-Ncp7330SanitizeOutcome -Result $result -FixtureSpec $spec -FileLabel $fileName

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
    if (-not $script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        $evidenceOnFailure += $outputRoot
    }
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:CoreE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

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
