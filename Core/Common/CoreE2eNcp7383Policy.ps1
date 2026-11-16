#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7383 lab policy: email + embedded ZIP; block unknown/disallowed inner files and remove from archive.
#>
Set-StrictMode -Version Latest

$script:Ncp7383LabPolicyName = 'NCP7383-email-embedded-archive-block-lab'
$script:Ncp7383LabPolicyPlaceholderId = 9383

. (Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1')

function Get-Ncp7383LabAllowedFileTypesValue {
    return 'Archives=True|CAD=True|Databases=True|Documents (Common)=True|Documents (Uncommon)=True|Email=True|Embedded Office Objects=True|Executables=True|Images=True|Media Files=True|Model=True|Others=True|Scripts=True|Unknown File=False|Unsafe=True'
}

function Get-Ncp7383EmailEmbeddedArchiveBlockLabPolicyRawData {
    $allowedTypes = Get-Ncp7383LabAllowedFileTypesValue
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

function New-Ncp7383EmailEmbeddedArchiveBlockLabPolicyImportBody {
    param([string] $PolicyName = $script:Ncp7383LabPolicyName)

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ncp7383LabPolicyPlaceholderId
                name          = $PolicyName
                displayName   = 'NCP-7383 email embedded archive block lab (debug sanitize)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = (Get-Ncp7383EmailEmbeddedArchiveBlockLabPolicyRawData)
            }
        )
        policyAssociations = @()
    }
}

function Import-Ncp7383EmailEmbeddedArchiveBlockLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7383LabPolicyName
    )

    . (Join-Path $PSScriptRoot 'CoreE2eDebugHook.ps1')

    if (-not [string]::IsNullOrWhiteSpace($PolicyImportJson)) {
        . (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1') | Out-Null
        $jsonPath = [System.IO.Path]::GetFullPath($PolicyImportJson.Trim())
        if (-not (Test-Path -LiteralPath $jsonPath)) {
            throw "Policy import JSON not found: $jsonPath"
        }
        $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
        $policySource = $jsonPath
    }
    else {
        $importBody = New-Ncp7383EmailEmbeddedArchiveBlockLabPolicyImportBody -PolicyName $PolicyName
        $policySource = '(in-memory policyRawData)'
    }

    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse = $import
        PolicySource   = $policySource
        PolicyName     = $PolicyName
    }
}