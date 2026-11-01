#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7352 lab policy: block unknown file types + sanitization email notification (debug importpolicies).
#>
Set-StrictMode -Version Latest

$script:Ncp7352LabPolicyName = 'NCP7352-email-notification-blocked'
$script:Ncp7352LabPolicyPlaceholderId = 7352
$script:Ncp7352DefaultImportPoliciesJsonFileName = 'NCP7352-email-notification-blocked.importpolicies.json'

. (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1')

function Get-Ncp7352BlockUnknownAllowedFileTypesValue {
    return 'Archives=True|CAD=True|Databases=True|Documents (Common)=True|Documents (Uncommon)=True|Email=True|Embedded Office Objects=True|Executables=True|Images=True|Media Files=True|Model=True|Others=True|Scripts=True|Unknown File=False|Unsafe=True'
}

function Get-Ncp7352EmailNotificationBlockedPolicyRawData {
    $allowedTypes = Get-Ncp7352BlockUnknownAllowedFileTypesValue
    $scannersFacet = (New-Sa07LabScannersFacet).TrimEnd()
    $transformationActionsFacet = (New-SaLabDisabledTransformationActionsFacet).TrimEnd()

    return @"
;Facet Basic:Basic
StrPropType_ConfigVersion=Auto
StrPropType_AllowedFileTypes=$allowedTypes
StrPropType_SignFiles=False
NumPropType_MaxUploadSize=0
NumPropType_BlockIncorrectUploadExtension=False
BoolPropType_EnableHashAllowlist=True
BoolPropType_EnableHashBlocklist=True
;Facet Advanced:Advanced
NumPropType_CheckServerCertificate=False
;Facet Failure Behavior:Failure Behavior
NumPropType_MaxArchiveRecursionLevels=5
NumPropType_DisallowedFilesInArchivesBehaviour=1
;Facet Email Notification:Email Notification
StrPropType_Hardcoded_EmailAddress=ncp7352-lab@127.0.0.1
StrPropType_QueryADForEmail=False
StrPropType_EmailCondition=0
StrPropType_EmailContents=0
StrPropType_EmailSubject=LAB-NCP7352 job notification
StrPropType_EmailHtmlFormatAllPassed=<html><body>LAB-NCP7352-ALL-PASSED-MARKER</body></html>
StrPropType_EmailHtmlFormatBlocked=<html><body>LAB-NCP7352-BLOCKED-MARKER</body></html>
$scannersFacet
$transformationActionsFacet

"@
}

function Get-Ncp7352EmailNotificationBlockedPolicyImportPoliciesPath {
    param([string] $OverridePath = '')

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy import JSON not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_POLICY_IMPORT_JSON)) {
        $full = [System.IO.Path]::GetFullPath($env:CORE_E2E_POLICY_IMPORT_JSON.Trim())
        if (Test-Path -LiteralPath $full) {
            return $full
        }
    }

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7352DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Import-Ncp7352EmailNotificationBlockedPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7352LabPolicyName
    )

    $jsonPath = Get-Ncp7352EmailNotificationBlockedPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}
