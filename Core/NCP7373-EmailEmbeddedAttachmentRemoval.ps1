#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7373: Email with embedded xlsx — CDR timeout then remove attachment without self file-lock delete failures.

.DESCRIPTION
  Regression for [NCP-7373](https://resec.atlassian.net/browse/NCP-7373):
    - Lab policy forces short CDR timeout and removes failed embedded files from parent email.
    - Sanitizes MIME EML with embedded spreadsheet (synthetic or checked-in fixture).
    - Asserts debug sanitize embeddedObjects summary, structured Core log line, and absence of forbidden delete warnings.

  Prerequisites:
    - Core DEBUG with EnableDebugInterface (hook https://localhost:4504).
    - Core build with sanitize includeEmbeddedSummary and NCP-7373 lock-release logging.
    - At least one deployment row; CDR worker available for spreadsheet transform attempts.

.EXAMPLE
  .\NCP7373-EmailEmbeddedAttachmentRemoval.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
  Optional Jira EML: copy to Fixtures\Mail\NCP-7373\ncp7373-lab-embedded-xlsx.eml or set -FixtureRoot.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $OutputRoot = '',
    [string] $FixtureRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7373-email-embedded-cdr-timeout-lab',
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 600,
    [switch] $SkipPolicyImport,
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
. (Join-Path $commonRoot 'CoreE2eNcp7373Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7373'
$script:TestTitle = 'Email embedded attachment removal after CDR timeout (NCP-7373)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-Ncp7373FixturePaths {
    param(
        [string] $OverrideRoot = '',
        [string] $WorkOutputRoot
    )

    $root = $OverrideRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_FIXTURE_ROOT)) {
            $root = $env:CORE_E2E_FIXTURE_ROOT
        }
        else {
            $root = Join-Path (Get-LabTestsRoot) 'Fixtures\Mail\NCP-7373'
        }
    }

    $root = [System.IO.Path]::GetFullPath($root)
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "NCP-7373 manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $emlName = [string]$manifest.fixtureFile
    $emlPath = Join-Path $root $emlName

    if (-not (Test-Path -LiteralPath $emlPath -PathType Leaf)) {
        $xlsxRel = [string]$manifest.spreadsheetFixtureRelative
        $xlsxPath = [System.IO.Path]::GetFullPath((Join-Path $root $xlsxRel))
        if (-not (Test-Path -LiteralPath $xlsxPath -PathType Leaf)) {
            throw "NCP-7373 spreadsheet fixture not found: $xlsxPath"
        }

        $emlPath = Join-Path $WorkOutputRoot $emlName
        New-Ncp7373LabEmlWithXlsxAttachment -OutputPath $emlPath -XlsxPath $xlsxPath `
            -AttachmentDisplayName ([string]$manifest.syntheticAttachmentFileName)
        Write-TestStep "Built synthetic EML: $emlPath"
    }

    return @{
        Root                             = $root
        Manifest                         = $manifest
        EmlPath                          = $emlPath
        ForbiddenLogPatterns             = @($manifest.forbiddenLogPatterns)
        RequiredSuccessLogPattern        = [string]$manifest.requiredSuccessLogPattern
        ExpectedEmbeddedOutcomeNames     = @($manifest.expectedEmbeddedOutcomeNames)
        ExpectedEmbeddedFileNameContains = [string]$manifest.expectedEmbeddedFileNameContains
    }
}

function New-Ncp7373LabEmlWithXlsxAttachment {
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [Parameter(Mandatory)]
        [string] $XlsxPath,
        [Parameter(Mandatory)]
        [string] $AttachmentDisplayName
    )

    $bytes = [System.IO.File]::ReadAllBytes($XlsxPath)
    $b64 = [Convert]::ToBase64String($bytes)
    $b64Lines = [System.Text.RegularExpressions.Regex]::Split($b64, '(.{1,76})') |
        Where-Object { -not [string]::IsNullOrEmpty($_) }

    $boundary = "----=_NCP7373_" + [Guid]::NewGuid().ToString('N')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('From: ncp7373-sender@test.local')
    [void]$sb.AppendLine('To: ncp7373-recipient@test.local')
    [void]$sb.AppendLine('Subject: NCP-7373 lab embedded xlsx timeout')
    [void]$sb.AppendLine('MIME-Version: 1.0')
    [void]$sb.AppendLine("Content-Type: multipart/mixed; boundary=`"$boundary`"")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine('Content-Type: text/plain; charset=utf-8')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NCP-7373 lab message body.')
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine('Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
    [void]$sb.AppendLine('Content-Transfer-Encoding: base64')
    [void]$sb.AppendLine("Content-Disposition: attachment; filename=`"$AttachmentDisplayName`"")
    [void]$sb.AppendLine('')
    foreach ($line in $b64Lines) {
        [void]$sb.AppendLine($line)
    }
    [void]$sb.AppendLine("--$boundary--")

    $dir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

function Assert-Ncp7373SanitizeResult {
    param(
        [Parameter(Mandatory)]
        $Result,
        [Parameter(Mandatory)]
        $ManifestSpec,
        [string] $CoreLogPath
    )

    if ($Result.timedOut -eq $true) {
        throw "Timed out sanitizing EML (sanitizationId=$($Result.sanitizationId))."
    }

    $embedded = @($Result.embeddedObjects)
    if ($embedded.Count -eq 0) {
        throw 'includeEmbeddedSummary returned no embeddedObjects; ensure Core build includes NCP-7373 debug hook fields.'
    }

    $xlsxRows = @($embedded | Where-Object {
            ([string]$_.fileName) -match [Regex]::Escape($ManifestSpec.ExpectedEmbeddedFileNameContains) -or
            ([string]$_.fileId) -match [Regex]::Escape($ManifestSpec.ExpectedEmbeddedFileNameContains)
        })
    if ($xlsxRows.Count -eq 0) {
        $ids = ($embedded | ForEach-Object { [string]$_.fileId }) -join '; '
        throw "No embedded spreadsheet row in embeddedObjects (fileId/fileName containing '$($ManifestSpec.ExpectedEmbeddedFileNameContains)'). Rows: $ids"
    }

    $match = $false
    foreach ($row in $xlsxRows) {
        $outcome = [string]$row.fileOutcome
        if ($ManifestSpec.ExpectedEmbeddedOutcomeNames -contains $outcome) {
            $match = $true
            break
        }
    }

    if (-not $match) {
        throw "Embedded xlsx outcomes were $($xlsxRows.fileOutcome -join ', '); expected one of: $($ManifestSpec.ExpectedEmbeddedOutcomeNames -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($CoreLogPath) -or -not (Test-Path -LiteralPath $CoreLogPath)) {
        throw "Core log path unavailable for NCP-7373 assertions: $CoreLogPath"
    }

    foreach ($pattern in @($ManifestSpec.ForbiddenLogPatterns)) {
        if (Select-String -LiteralPath $CoreLogPath -Pattern $pattern -Quiet) {
            throw "Forbidden log pattern matched after sanitize: $pattern"
        }
    }

    if (-not (Select-String -LiteralPath $CoreLogPath -Pattern $ManifestSpec.RequiredSuccessLogPattern -Quiet)) {
        throw "Expected Core log line not found: $($ManifestSpec.RequiredSuccessLogPattern)"
    }

    Write-TestStep "NCP-7373 assertions OK (embedded xlsx outcome + log markers, no forbidden delete warnings)."
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7373-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $fixture = Get-Ncp7373FixturePaths -OverrideRoot $FixtureRoot -WorkOutputRoot $outputRoot

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Fixture EML: $($fixture.EmlPath)"

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

        $jsonPath = Get-Ncp7373EmailEmbeddedCdrTimeoutLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies from JSON: $jsonPath"
        Import-Ncp7373EmailEmbeddedCdrTimeoutLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath `
            -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
    Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Step 'NCP7373' -Mark 'before sanitize eml'

    Write-TestStep 'debug sanitize (EML + embedded xlsx, includeEmbeddedSummary)'
    $sanitizeParams = @{
        HookUrl                 = $hookUrl
        FilePath                = $fixture.EmlPath
        PolicyId                = $resolvedPolicyId
        TimeoutSeconds          = $SanitizeTimeoutSec
        IncludeEmbeddedSummary  = $true
    }
    if ($DeploymentId -gt 0) {
        $sanitizeParams.DeploymentId = $DeploymentId
    }

    $sanitizeResult = Invoke-CoreE2eSanitizeFile @sanitizeParams
    Write-TestStep "Sanitize finished sanitizationId=$($sanitizeResult.sanitizationId) outcome=$($sanitizeResult.outcome) embeddedCount=$($sanitizeResult.numOfEmbeddedObjects)"

    Assert-Ncp7373SanitizeResult -Result $sanitizeResult -ManifestSpec $fixture -CoreLogPath $coreLog

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
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7373'
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
}
