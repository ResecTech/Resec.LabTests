#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7374 lab policy: Office spreadsheet CDR + Local:: out store (cross-portal PutFile repro).
#>
Set-StrictMode -Version Latest

$script:Ncp7374PutfileLabPolicyName = 'NCP7374-office-cdr-local-putfile-lab'
$script:Ncp7374PutfileLabPolicyPlaceholderId = 93741
$script:Ncp7374DefaultImportPoliciesJsonFileName = 'NCP7374-office-cdr-local-putfile-lab.importpolicies.json'

$scanAgentCommon = Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1'
if (-not (Test-Path -LiteralPath $scanAgentCommon)) {
    throw "Scan Agent policy helpers not found: $scanAgentCommon"
}
. $scanAgentCommon

function New-Ncp7374SpreadsheetCdrTransformationActionsFacet {
    return @"
;Facet Transformation Actions:Transformation Actions
Actions Settings=Pdf:Critical=False|Pdf:High=False|Pdf:Medium=False|Pdf:Low=False|Word:Critical=False|Word:High=False|Word:Medium=False|Word:Low=False|Spreadsheet:Critical=True|Spreadsheet:High=True|Spreadsheet:Medium=True|Spreadsheet:Low=True|Presentation:Critical=False|Presentation:High=False|Presentation:Medium=False|Presentation:Low=False|Visio:High=False|Visio:Medium=False|Visio:Low=False|Image:High=False|Image:Medium=False|Image:Low=False|Html:Critical=False|Html:High=False|Html:Medium=False|Html:Low=False|Email:Critical=False|Email:High=False|Email:Medium=False|Email:Low=False|Svg:Critical=False|Svg:High=False|Svg:Medium=False|MetafileImage=False|Multitiff=False|Csv:Critical=False|Csv:Medium=False|Chm=False|Ichitaro:Critical=False|Ichitaro:High=False|Ichitaro:Medium=False|JSON=False|Mp3=False|OpenOfficeText:High=False|OpenOfficeText:Medium=False|OpenOfficeSpreadsheet:High=False|OpenOfficeSpreadsheet:Medium=False|OpenOfficePresentation:High=False|OpenOfficePresentation:Medium=False|OpenOfficeGraphics=False|AutoCad=False
NumPropType_VerifySignatureWhenIgnoringSignedFile=False
NumPropType_ExtractPdfImages=False
NumPropType_ProcessJtdc=False
BoolPropType_RetainOriginalFile=False

"@
}

function Get-Ncp7374OfficeCdrLocalPutfileLabPolicyRawData {
    $allowedTypes = Get-Sa07LabAllowedFileTypesValue
    $scannersFacet = (New-Sa07LabScannersFacet).TrimEnd()
    $transformationActionsFacet = (New-Ncp7374SpreadsheetCdrTransformationActionsFacet).TrimEnd()
    $localInOut = (New-Sa07LocalInOutFacetBlock).TrimEnd()

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
$localInOut

"@
}

function Get-Ncp7374OfficeCdrLocalPutfileLabPolicyImportPoliciesPath {
    param([string] $OverridePath = '')

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy import JSON not found: $full"
        }
        return $full
    }

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7374DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Import-Ncp7374OfficeCdrLocalPutfileLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7374PutfileLabPolicyName
    )

    . (Join-Path $PSScriptRoot 'CoreE2eDebugHook.ps1')
    . (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1')

    $jsonPath = Get-Ncp7374OfficeCdrLocalPutfileLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $firstPolicy = $importBody.policies[0]
    $hasRaw = $false
    if ($firstPolicy -is [System.Collections.IDictionary]) {
        $hasRaw = -not [string]::IsNullOrWhiteSpace([string]$firstPolicy['policyRawData'])
    }
    else {
        $hasRaw = -not [string]::IsNullOrWhiteSpace([string]$firstPolicy.policyRawData)
    }

    if (-not $hasRaw) {
        $importBody = New-Ncp7374OfficeCdrLocalPutfileLabPolicyImportBody -PolicyName $PolicyName
    }

    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}

function New-Ncp7374OfficeCdrLocalPutfileLabPolicyImportBody {
    param([string] $PolicyName = $script:Ncp7374PutfileLabPolicyName)

    $raw = Get-Ncp7374OfficeCdrLocalPutfileLabPolicyRawData
    return @{
        policies           = @(
            @{
                displayName   = 'NCP-7374 Office CDR + Local:: putfile repro (debug sanitize)'
                policyRawData = $raw
                isPredefined  = $false
                agentType     = 'General'
                name          = $PolicyName
                id            = $script:Ncp7374PutfileLabPolicyPlaceholderId
            }
        )
        policyAssociations = @()
    }
}
