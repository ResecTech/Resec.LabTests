#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7371: CHM Convert to PDF via Core /debug/hook sanitize (CDR worker path).

.DESCRIPTION
  Imports a lab policy with Chm=True (Convert to PDF), sanitizes ticket fixture IMJPCL.CHM,
  and asserts the job does not fail with worker temp-folder collision and output is PDF.

  Prerequisites:
    - Core running DEBUG with EnableDebugInterface (default https://localhost:4504/debug/hook).
    - CDR out-of-process worker enabled (same as QA regress).
    - Deployment row in DB or pass -DeploymentId.

.EXAMPLE
  .\NCP7371-ChmConvertToPdfSanitize.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
  Test Platform shows "Running" until this script exits (transcript is uploaded in finally).
  After deploy, the script may sit on Wait-CoreE2eReady (up to 600s) or CHM sanitize (default 600s;
  HTTP client allows +60s). Search Core Serilog for "NCP7371-ChmConvertToPdfSanitize" logmarks.
  Lab run: -SkipAutoStartCore when deploy already started Resec.Core.exe.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $FixtureRoot = '',
    [string] $OutputRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7371-chm-cdr-lab',
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 600,
    [switch] $SkipPolicyStack,
    [switch] $SkipAutoStartCore
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
. (Join-Path $commonRoot 'CoreE2eNcp7371Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7371'
$script:TestTitle = 'CHM convert to PDF debug sanitize (NCP-7371)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
    try { [Console]::Out.Flush() } catch { }
}

function Invoke-Ncp7371SanitizeWithProgress {
    param(
        [Parameter(Mandatory)] [hashtable] $SanitizeParams
    )

    $clientTimeoutSec = [int]$SanitizeParams.TimeoutSeconds + 60
    Write-TestStep "sanitize HTTP starting (client timeout ${clientTimeoutSec}s; CHM→PDF can take several minutes)"
    if ($SanitizeParams.ContainsKey('HookUrl')) {
        Write-CoreE2eDebugLogMark -HookUrl $SanitizeParams.HookUrl -Step 'NCP7371-ChmConvertToPdfSanitize' `
            -Mark ('sanitize starting: ' + [System.IO.Path]::GetFileName([string]$SanitizeParams.FilePath))
    }

    return Invoke-CoreE2eSanitizeFile @SanitizeParams
}

function Assert-Ncp7371SanitizeOutcome {
    param(
        [Parameter(Mandatory)]
        $Result,
        [Parameter(Mandatory)]
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $InputPath,
        [Parameter(Mandatory)]
        [string] $OutputPath
    )

    $fileLabel = [string]$FixtureSpec.label
    if ($Result.timedOut -eq $true) {
        throw "Timed out sanitizing '$fileLabel' (sanitizationId=$($Result.sanitizationId))."
    }

    $outcome = [string]$Result.outcome
    $details = [string]$Result.outcomeDetails

    foreach ($forbidden in @($FixtureSpec.forbiddenOutcomes)) {
        if ($outcome -eq [string]$forbidden) {
            throw "Unexpected outcome '$outcome' for '$fileLabel'. Details: $details"
        }
    }

    foreach ($pattern in @($FixtureSpec.forbiddenOutcomeDetailsPatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($details) -and $details -match $pattern) {
            throw "Outcome details for '$fileLabel' matched forbidden pattern '$pattern'. Outcome=$outcome Details=$details"
        }
    }

  if ($FixtureSpec.requirePdfOutput -eq $true) {
        $effectiveOutput = $OutputPath
        if ($Result.outputPath -and (Test-Path -LiteralPath $Result.outputPath -PathType Leaf)) {
            $effectiveOutput = [string]$Result.outputPath
        }

        if (-not (Test-Path -LiteralPath $effectiveOutput -PathType Leaf)) {
            throw "Expected PDF output for '$fileLabel' at '$effectiveOutput'."
        }

        $header = [System.IO.File]::ReadAllBytes($effectiveOutput)[0..4]
        $pdfMagic = [byte[]](0x25, 0x50, 0x44, 0x46, 0x2D)
        for ($i = 0; $i -lt $pdfMagic.Length; $i++) {
            if ($header[$i] -ne $pdfMagic[$i]) {
                throw "Output for '$fileLabel' is not a PDF (missing %PDF- header): $effectiveOutput"
            }
        }
    }

    $expected = @($FixtureSpec.expectedOutcomes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($expected).Count -gt 0 -and ($expected -notcontains $outcome)) {
        throw "Unexpected outcome '$outcome' for '$fileLabel' (expected one of: $($expected -join ', ')). Details: $details"
    }

    Write-TestStep "OK '$fileLabel' -> outcome=$outcome output=$OutputPath"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $FixtureRoot = Join-Path $PSScriptRoot 'Fixtures\CHM\NCP7371'
    }

    $fixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
    if (-not (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
        throw "Fixture root not found: $fixtureRoot"
    }

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
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7371-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Fixtures: $fixtureRoot"
    Write-TestStep "Output: $outputRoot"
    if ($script:E2eRunLogPath) {
        Write-TestStep "Run transcript: $script:E2eRunLogPath"
    }

    $waitParams = @{
        HookUrl     = $hookUrl
        LogMarkStep = 'NCP7371-ChmConvertToPdfSanitize'
    }
    if ($SkipAutoStartCore) {
        $waitParams.SkipAutoStartCore = $true
    }

    Write-TestStep 'Wait for Core ready (coreInitialized; up to 600s after deploy)'
    Wait-CoreE2eReady @waitParams | Out-Null
    Write-TestStep 'Core ready (coreInitialized=true)'
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

        $jsonPath = Get-Ncp7371ChmCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies: $jsonPath"
        Import-Ncp7371ChmCdrLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath -PolicyName $LabPolicyName | Out-Null
        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId.'
    }

    foreach ($spec in $fixtureSpecs) {
        $fileName = [string]$spec.file
        $inputPath = Join-Path $fixtureRoot $fileName
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "Fixture file missing: $inputPath"
        }

        $outputPath = Join-Path $outputRoot ($fileName -replace '\.chm$', '.pdf')
        Write-TestStep "sanitize: $inputPath -> $outputPath"
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

        $result = Invoke-Ncp7371SanitizeWithProgress -SanitizeParams $sanitizeParams
        Write-TestStep "sanitize finished sanitizationId=$($result.sanitizationId) outcome=$($result.outcome) timedOut=$($result.timedOut)"
        Assert-Ncp7371SanitizeOutcome -Result $result -FixtureSpec $spec -InputPath $inputPath -OutputPath $outputPath
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
            }
        }
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:CoreE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle `
        -Passed $script:ScenarioPassed -FailureMessage $script:ScenarioFailureMessage `
        -StartedAtUtc $script:TestStartedAtUtc -RunLogPath $script:E2eRunLogPath `
        -EvidencePathsOnFailure $evidenceOnFailure -EvidenceZipPath $script:EvidenceZipPath

    if ($script:PolicyStackPushed -and $hookUrl) {
        try {
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}