#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7344 lab policy: debug hook importpolicies JSON with valid Core facet template names (no WebMC XML).
.NOTES
  Facet comments must use FacetTemplate.Name (e.g. ;Facet Basic:..., not "Basic Settings").
  Legacy facets "System Health" and "Format Transformations" are not registered on current Core builds.
#>
Set-StrictMode -Version Latest

$script:Ncp7344LabPolicyName = 'NCP7344-office-nocdr-lab'
$script:Ncp7344LabPolicyPlaceholderId = 9344
$script:Ncp7344DefaultImportPoliciesJsonFileName = 'NCP7344-office-nocdr-lab.importpolicies.json'

. (Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1')

function Get-Ncp7344OfficeNoCdrLabPolicyRawData {
    $allowedTypes = Get-Sa07LabAllowedFileTypesValue
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
$scannersFacet
$transformationActionsFacet

"@
}

function Get-Ncp7344OfficeNoCdrLabPolicyImportPoliciesPath {
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

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7344DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function ConvertTo-CoreE2ePolicyImportBodyHashtable {
    param(
        [Parameter(Mandatory)]
        $ImportPoliciesObject
    )

    if ($null -eq $ImportPoliciesObject) {
        throw 'Policy import JSON deserialized to null.'
    }

    $policies = @()
    foreach ($policy in @($ImportPoliciesObject.policies)) {
        if ($null -eq $policy) { continue }
        $entry = [ordered]@{}
        foreach ($name in @($policy.PSObject.Properties.Name)) {
            $entry[$name] = $policy.$name
        }
        $policies += $entry
    }

    $associations = @()
    foreach ($rule in @($ImportPoliciesObject.policyAssociations)) {
        if ($null -eq $rule) { continue }
        $entry = [ordered]@{}
        foreach ($name in @($rule.PSObject.Properties.Name)) {
            $entry[$name] = $rule.$name
        }
        $associations += $entry
    }

    return [ordered]@{
        command            = 'importpolicies'
        policies           = $policies
        policyAssociations = $associations
    }
}

function Read-CoreE2ePolicyImportBodyFromJsonFile {
    param(
        [Parameter(Mandatory)]
        [string] $JsonPath
    )

    $full = [System.IO.Path]::GetFullPath($JsonPath)
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Policy import JSON not found: $full"
    }

    $document = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
    return ConvertTo-CoreE2ePolicyImportBodyHashtable -ImportPoliciesObject $document
}

function New-Ncp7344OfficeNoCdrLabPolicyImportBody {
    param([string] $PolicyName = $script:Ncp7344LabPolicyName)

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ncp7344LabPolicyPlaceholderId
                name          = $PolicyName
                displayName   = 'NCP-7344 Office no-CDR lab (debug sanitize)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = (Get-Ncp7344OfficeNoCdrLabPolicyRawData)
            }
        )
        policyAssociations = @()
    }
}

function Import-Ncp7344OfficeNoCdrLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7344LabPolicyName
    )

    $jsonPath = Get-Ncp7344OfficeNoCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}
