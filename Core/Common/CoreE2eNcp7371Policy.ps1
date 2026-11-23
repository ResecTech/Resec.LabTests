#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7371 lab policy: CHM CDR with Convert to PDF enabled (other products disabled).
#>
Set-StrictMode -Version Latest

$script:Ncp7371LabPolicyName = 'NCP7371-chm-cdr-lab'
$script:Ncp7371LabPolicyPlaceholderId = 9371
$script:Ncp7371DefaultImportPoliciesJsonFileName = 'NCP7371-chm-cdr-lab.importpolicies.json'

. (Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1')
. (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1')

function New-Ncp7371ChmCdrTransformationActionsFacet {
    $disabled = (New-SaLabDisabledTransformationActionsFacet).TrimEnd()
    return ($disabled -replace 'Chm=False', 'Chm=True')
}

function Get-Ncp7371ChmCdrLabPolicyRawData {
    $allowedTypes = Get-Sa07LabAllowedFileTypesValue
    $scannersFacet = (New-Sa07LabScannersFacet).TrimEnd()
    $transformationActionsFacet = (New-Ncp7371ChmCdrTransformationActionsFacet).TrimEnd()

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
$scannersFacet
$transformationActionsFacet

"@
}

function Get-Ncp7371ChmCdrLabPolicyImportPoliciesPath {
    param([string] $OverridePath = '')

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy import JSON not found: $full"
        }
        return $full
    }

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7371DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Import-Ncp7371ChmCdrLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7371LabPolicyName
    )

    . (Join-Path $PSScriptRoot 'CoreE2eDebugHook.ps1')

    $jsonPath = Get-Ncp7371ChmCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}