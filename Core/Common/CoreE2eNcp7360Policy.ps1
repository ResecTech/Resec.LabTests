#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7360 lab policy: block archive on disallowed embedded files, sanitization report for encrypted files, unknown types blocked.
#>
Set-StrictMode -Version Latest

$script:Ncp7360LabPolicyName = 'NCP7360-portal-encrypted-archive-block'
$script:Ncp7360LabPolicyPlaceholderId = 7360
$script:Ncp7360DefaultImportPoliciesJsonFileName = 'NCP7360-portal-encrypted-archive-block.importpolicies.json'

. (Join-Path $PSScriptRoot 'CoreE2eNcp7352Policy.ps1')

function Get-Ncp7360BlockUnknownAllowedFileTypesValue {
    return Get-Ncp7352BlockUnknownAllowedFileTypesValue
}

function Get-Ncp7360PortalEncryptedArchiveBlockPolicyRawData {
    $allowedTypes = Get-Ncp7360BlockUnknownAllowedFileTypesValue
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
NumPropType_DisallowedFilesInArchivesBehaviour=0
;Facet Sanitization Report:Sanitization Report
NumPropType_StoreSanitizationReport=2
StrPropType_SanitizationReportFilename=`$(file_name).`$(success_or_fail).html
$scannersFacet
$transformationActionsFacet

"@
}

function Get-Ncp7360PortalEncryptedArchiveBlockPolicyImportPoliciesPath {
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

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7360DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Import-Ncp7360PortalEncryptedArchiveBlockPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7360LabPolicyName
    )

    $jsonPath = Get-Ncp7360PortalEncryptedArchiveBlockPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}
