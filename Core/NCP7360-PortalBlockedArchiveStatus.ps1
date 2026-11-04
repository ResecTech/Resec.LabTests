#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7360: After Password Portal submit, blocked archive must not show as completed successfully.

.DESCRIPTION
  Mirrors the Jira repro:
    - Failure Behavior: block archive when it contains disallowed files (policy value 0).
    - Sanitization report: for blocked and encrypted files.
    - Portal enabled (Portal_Enabled).
    - Sanitize an AES-encrypted zip whose only member is an unknown file type (password 1111).
    - Submit the archive password through Core /v1/portal (same API the Portal app uses).
    - Assert portal file-data reflects a blocked/failed job, not Passed (OutcomePassed / SanitizationState Passed).

  The test fails on builds that bubble FileOutcome=Passed to the portal root while the job outcome is blocked (NCP-7360).

  Prerequisites:
    - Core DEBUG with EnableDebugInterface and portal REST on the management port (default https://localhost:4504).
    - At least one deployment row in the DB (register any agent once, or pass -DeploymentId).
    - 7-Zip on the lab host (env CORE_E2E_7Z_EXE, RESEC_CORE_EXE_LOCATION build output, or Core repo EmbeddedWindows\7z.exe).

.EXAMPLE
  .\NCP7360-PortalBlockedArchiveStatus.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $CoreRestBaseUrl = '',
    [string] $OutputRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7360-portal-encrypted-archive-block',
    [string] $SevenZipExe = '',
    [string] $ArchivePassword = '1111',
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
    [int] $PortalPollTimeoutSec = 300,
    [switch] $SkipPolicyImport,
    [switch] $SkipPolicyStack,
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
. (Join-Path $commonRoot 'CoreE2ePortalApi.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7360Policy.ps1')
. (Join-Path $commonRoot 'CoreE2eLabPaths.ps1')

$script:OutcomePassedValue = 100
$script:SanitizationStatePassed = 10
$script:SanitizationStateBlocked = 30
$script:LabPortalSecretFallback = 'NCP7360-lab-portal-secret'

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:SystemPropertiesStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$coreRestBaseUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7360'
$script:TestTitle = 'Portal status after encrypted archive block (NCP-7360)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Resolve-Ncp7360SevenZipExe {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $full = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "7z not found: $full"
        }
        return $full
    }

    $resolved = Resolve-CoreE2eEmbedded7ZipPath
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }

    throw '7-Zip not found. Set CORE_E2E_7Z_EXE, build Core (sets RESEC_CORE_EXE_LOCATION), or set LAB_CORE_EXE.'
}

function New-Ncp7360EncryptedUnknownArchive {
    param(
        [Parameter(Mandatory)]
        [string] $OutputRoot,
        [Parameter(Mandatory)]
        [string] $SevenZipPath,
        [Parameter(Mandatory)]
        [string] $Password
    )

    $staging = Join-Path $OutputRoot 'archive-staging'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $innerPath = Join-Path $staging 'inner-unknown.dat'
    $unknownBytes = [byte[]](0x52, 0x45, 0x53, 0x45, 0x43, 0x2D, 0x4E, 0x43, 0x50, 0x2D, 0x37, 0x33, 0x36, 0x30, 0x00, 0xFF)
    [System.IO.File]::WriteAllBytes($innerPath, $unknownBytes)

    $archivePath = Join-Path $OutputRoot 'NCP7360-encrypted-unknown.zip'
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }

    & $SevenZipPath @('a', '-tzip', "-p$Password", '-mem=AES256', $archivePath, $innerPath) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7z failed creating encrypted archive (exit $LASTEXITCODE)."
    }

    return [System.IO.Path]::GetFullPath($archivePath)
}

function Assert-Ncp7360PortalNotSuccessfulAfterCoreBlock {
    param(
        [Parameter(Mandatory)]
        $FileData,
        [string] $CoreOutcomeName = ''
    )

    $outcome = [int]$FileData.outcome
    $state = [int]$FileData.sanitizationState

    if ($outcome -eq $script:OutcomePassedValue -or $state -eq $script:SanitizationStatePassed) {
        $details = [string]$FileData.sanitizationStateDetails
        throw @"
NCP-7360 reproduction: Portal file-data shows success after archive block (outcome=$outcome sanitizationState=$state details='$details').
Core outcome after reprocess: $CoreOutcomeName
Expected portal root to reflect blocked/failed job, not OutcomePassed ($($script:OutcomePassedValue)) / SanitizationState Passed ($($script:SanitizationStatePassed)).
"@
    }

    if ($state -ne $script:SanitizationStateBlocked) {
        throw "Expected portal SanitizationState Blocked ($($script:SanitizationStateBlocked)), got $state (outcome=$outcome)."
    }

    Write-TestStep "Portal file-data OK after block: outcome=$outcome sanitizationState=$state"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $coreRestBaseUrl = Get-CoreE2eCoreRestBaseUrl -HookUrl $hookUrl -Override $CoreRestBaseUrl

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7360-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $sevenZip = Resolve-Ncp7360SevenZipExe -Override $SevenZipExe

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Core REST: $coreRestBaseUrl"
    Write-TestStep "Output: $outputRoot"

    Write-TestStep 'Wait for Core ready'
    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-TestStep "Core version: $($versionInfo.version)"
    }

    if (-not $SkipSystemPropertiesStack) {
        Write-TestStep 'pushsystempropertystate'
        Push-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        $script:SystemPropertiesStackPushed = $true
    }

    $portalSecret = Get-CoreE2eSystemPropertyValue -HookUrl $hookUrl -PropertyName 'Portal_Secret'
    if ([string]::IsNullOrWhiteSpace($portalSecret)) {
        $portalSecret = $script:LabPortalSecretFallback
        Write-TestStep 'importsystemproperties (lab Portal_Secret + Portal_Enabled)'
        Import-CoreE2eSystemProperties -HookUrl $hookUrl -SystemProperties @(
            @{ name = 'Portal_Secret'; propValue = $portalSecret }
            @{ name = 'Portal_Enabled'; propValue = 'True' }
        ) | Out-Null
    }
    else {
        Write-TestStep 'importsystemproperties (Portal_Enabled=True)'
        Import-CoreE2eSystemProperties -HookUrl $hookUrl -SystemProperties @(
            @{ name = 'Portal_Enabled'; propValue = 'True' }
        ) | Out-Null
    }

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        $jsonPath = Get-Ncp7360PortalEncryptedArchiveBlockPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies from JSON: $jsonPath"
        Import-Ncp7360PortalEncryptedArchiveBlockPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath `
            -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $archivePath = New-Ncp7360EncryptedUnknownArchive -OutputRoot $outputRoot -SevenZipPath $sevenZip `
        -Password $ArchivePassword
    Write-TestStep "Fixture archive: $archivePath"

    Write-TestStep 'debug sanitize (encrypted archive, no password yet)'
    $sanitizeParams = @{
        HookUrl        = $hookUrl
        FilePath       = $archivePath
        PolicyId       = $resolvedPolicyId
        TimeoutSeconds = $SanitizeTimeoutSec
    }
    if ($DeploymentId -gt 0) {
        $sanitizeParams.DeploymentId = $DeploymentId
    }

    $firstPass = Invoke-CoreE2eSanitizeFile @sanitizeParams
    if ($firstPass.timedOut -eq $true) {
        throw "Timed out on first-pass sanitize (sanitizationId=$($firstPass.sanitizationId))."
    }

    $firstOutcome = [string]$firstPass.outcome
    if ($firstOutcome -ne 'OutcomeBlockedPasswordRequired') {
        throw "Expected OutcomeBlockedPasswordRequired on first pass but got '$firstOutcome'. Details: $($firstPass.outcomeDetails)"
    }

    $sanitizationId = [int]$firstPass.sanitizationId
    Write-TestStep "First pass OK (sanitizationId=$sanitizationId outcome=$firstOutcome)"

    $signature = New-CoreE2ePortalSanitizationSignature -PortalSecret $portalSecret -SanitizationId $sanitizationId

    $beforeSubmit = Wait-CoreE2ePortalFileDataFinal -BaseUrl $coreRestBaseUrl -PortalApiToken $portalSecret `
        -SanitizationId $sanitizationId -TimeoutSec $PortalPollTimeoutSec -ScenarioLabel 'before password submit'
    $internalName = Resolve-CoreE2ePortalPasswordSubmitInternalName -FileData $beforeSubmit

    Write-TestStep "Portal submit password for '$internalName'"
    Submit-CoreE2ePortalFilePassword -BaseUrl $coreRestBaseUrl -PortalApiToken $portalSecret `
        -SanitizationId $sanitizationId -Signature $signature -InternalName $internalName `
        -Password $ArchivePassword | Out-Null

    $afterSubmit = Wait-CoreE2ePortalFileDataFinal -BaseUrl $coreRestBaseUrl -PortalApiToken $portalSecret `
        -SanitizationId $sanitizationId -TimeoutSec $PortalPollTimeoutSec -ScenarioLabel 'after password submit'

    Assert-Ncp7360PortalNotSuccessfulAfterCoreBlock -FileData $afterSubmit -CoreOutcomeName '(see Core logs / WMC for job outcome)'

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
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7360'
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

    if ($script:SystemPropertiesStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-TestStep 'popsystempropertystate'
            Pop-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "popsystempropertystate failed: $($_.Exception.Message)"
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
