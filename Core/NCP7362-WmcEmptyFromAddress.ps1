#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7362: WMC email list must not show the recipient address in the From column when the EML has no From.

.DESCRIPTION
  Reproduces [NCP-7362](https://resec.atlassian.net/browse/NCP-7362):
    - Sanitize the Jira attachment EML (empty From, To ben@resec.co) via debug sanitize.
    - Query the same REST shape WebMC uses for the Emails page: POST /v1/sanitizations/email.
    - Assert mailFromAddress is empty and mailToAddresses contains the recipient — not duplicated into From.

  Prerequisites:
    - Core DEBUG with EnableDebugInterface (default hook https://localhost:4504).
    - At least one deployment row in the DB.
    - WMC REST login uses resec_admin / resec_admin by default (Core AdminUser/AdminPassword); override via
      CORE_E2E_WMC_USER / CORE_E2E_WMC_PASSWORD or -WmcUser / -WmcPassword.

.EXAMPLE
  .\NCP7362-WmcEmptyFromAddress.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $CoreRestBaseUrl = '',
    [string] $OutputRoot = '',
    [string] $FixtureRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7344-office-nocdr-lab',
    [string] $WmcUser = '',
    [string] $WmcPassword = '',
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
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
. (Join-Path $commonRoot 'CoreE2ePortalApi.ps1')
. (Join-Path $commonRoot 'CoreE2eWmcApi.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7344Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$coreRestBaseUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7362'
$script:TestTitle = 'WMC email From empty when EML has no From (NCP-7362)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-Ncp7362FixturePaths {
    param([string] $OverrideRoot = '')

    $root = $OverrideRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_FIXTURE_ROOT)) {
            $root = $env:CORE_E2E_FIXTURE_ROOT
        }
        else {
            $root = Join-Path (Get-LabTestsRoot) 'Fixtures\Mail\NCP-7362'
        }
    }

    $root = [System.IO.Path]::GetFullPath($root)
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "NCP-7362 manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $emlName = [string]$manifest.fixtureFile
    $emlPath = Join-Path $root $emlName
    if (-not (Test-Path -LiteralPath $emlPath -PathType Leaf)) {
        throw "NCP-7362 fixture EML not found: $emlPath"
    }

    return @{
        Root               = $root
        Manifest           = $manifest
        EmlPath            = $emlPath
        ExpectedToContains = [string]$manifest.expectedToContains
        ExpectedSubject    = [string]$manifest.expectedSubjectContains
    }
}

function Assert-Ncp7362WmcEmailFromNotRecipient {
    param(
        [Parameter(Mandatory)]
        $EmailRow,
        [Parameter(Mandatory)]
        [string] $ExpectedToContains,
        [int] $SanitizationId
    )

    $from = [string](Get-CoreE2eWmcRestPropertyValue -Object $EmailRow -Names @('mailFromAddress', 'MailFromAddress'))
    $to = [string](Get-CoreE2eWmcRestPropertyValue -Object $EmailRow -Names @('mailToAddresses', 'MailToAddresses'))
    $subject = [string](Get-CoreE2eWmcRestPropertyValue -Object $EmailRow -Names @('mailSubject', 'MailSubject'))

    if ([string]::IsNullOrWhiteSpace($to)) {
        throw "NCP-7362: mailToAddresses is empty for sanitizationId=$SanitizationId (expected recipient '$ExpectedToContains')."
    }

    if ($to -notmatch [Regex]::Escape($ExpectedToContains)) {
        throw "NCP-7362: mailToAddresses '$to' does not contain expected recipient '$ExpectedToContains'."
    }

    if (-not [string]::IsNullOrWhiteSpace($from)) {
        if ($from -eq $to) {
            throw @"
NCP-7362 reproduction: WMC email query shows recipient in From and To (mailFromAddress='$from' mailToAddresses='$to').
Expected empty From when the source EML From header is blank.
"@
        }

        if ($from -match [Regex]::Escape($ExpectedToContains)) {
            throw @"
NCP-7362 reproduction: mailFromAddress '$from' contains recipient '$ExpectedToContains' but source EML has no From header.
mailToAddresses='$to'
"@
        }
    }

    Write-TestStep "WMC email row OK: mailFromAddress='$from' mailToAddresses='$to' subject='$subject'"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $fixture = Get-Ncp7362FixturePaths -OverrideRoot $FixtureRoot

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $coreRestBaseUrl = Get-CoreE2eCoreRestBaseUrl -HookUrl $hookUrl -Override $CoreRestBaseUrl

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7362-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Core REST: $coreRestBaseUrl"
    Write-TestStep "Fixture: $($fixture.EmlPath)"

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
        Import-Ncp7344OfficeNoCdrLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath `
            -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    Write-TestStep 'debug sanitize (EML with empty From)'
    $sanitizeParams = @{
        HookUrl        = $hookUrl
        FilePath       = $fixture.EmlPath
        PolicyId       = $resolvedPolicyId
        TimeoutSeconds = $SanitizeTimeoutSec
    }
    if ($DeploymentId -gt 0) {
        $sanitizeParams.DeploymentId = $DeploymentId
    }

    $sanitizeResult = Invoke-CoreE2eSanitizeFile @sanitizeParams
    if ($sanitizeResult.timedOut -eq $true) {
        throw "Timed out sanitizing EML (sanitizationId=$($sanitizeResult.sanitizationId))."
    }

    $sanitizationId = [int]$sanitizeResult.sanitizationId
    Write-TestStep "Sanitize finished sanitizationId=$sanitizationId outcome=$($sanitizeResult.outcome)"

    Write-TestStep 'WMC login'
    $wmcToken = Connect-CoreE2eWmcRestSession -BaseUrl $coreRestBaseUrl -User $WmcUser -Password $WmcPassword

    Write-TestStep "Query WMC email sanitizations for id $sanitizationId"
    $emailRow = Get-CoreE2eWmcEmailSanitizationRow -BaseUrl $coreRestBaseUrl -ApiToken $wmcToken `
        -SanitizationId $sanitizationId

    Assert-Ncp7362WmcEmailFromNotRecipient -EmailRow $emailRow -ExpectedToContains $fixture.ExpectedToContains `
        -SanitizationId $sanitizationId

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
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7362'
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
