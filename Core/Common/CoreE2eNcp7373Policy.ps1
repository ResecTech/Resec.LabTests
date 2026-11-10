#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7373 lab policy: email + spreadsheet CDR with 1s timeout; remove failed embeds from parent archive.
#>
Set-StrictMode -Version Latest

$script:Ncp7373LabPolicyName = 'NCP7373-email-embedded-cdr-timeout-lab'
$script:Ncp7373LabPolicyPlaceholderId = 9373
$script:Ncp7373DefaultImportPoliciesJsonFileName = 'NCP7373-email-embedded-cdr-timeout-lab.importpolicies.json'

. (Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1')

function New-Ncp7373SpreadsheetCdrTransformationActionsFacet {
    return @"
;Facet Transformation Actions:Transformation Actions
Actions Settings=Pdf:Critical=False|Pdf:High=False|Pdf:Medium=False|Pdf:Low=False|Word:Critical=False|Word:High=False|Word:Medium=False|Word:Low=False|Spreadsheet:Critical=True|Spreadsheet:High=True|Spreadsheet:Medium=True|Spreadsheet:Low=True|Presentation:Critical=False|Presentation:High=False|Presentation:Medium=False|Presentation:Low=False|Visio:High=False|Visio:Medium=False|Visio:Low=False|Image:High=False|Image:Medium=False|Image:Low=False|Html:Critical=False|Html:High=False|Html:Medium=False|Html:Low=False|Email:Critical=False|Email:High=False|Email:Medium=False|Email:Low=True|Svg:Critical=False|Svg:High=False|Svg:Medium=False|MetafileImage=False|Multitiff=False|Csv:Critical=False|Csv:Medium=False|Chm=False|Ichitaro:Critical=False|Ichitaro:High=False|Ichitaro:Medium=False|JSON=False|Mp3=False|OpenOfficeText:High=False|OpenOfficeText:Medium=False|OpenOfficeSpreadsheet:High=False|OpenOfficeSpreadsheet:Medium=False|OpenOfficePresentation:High=False|OpenOfficePresentation:Medium=False|OpenOfficeGraphics=False|AutoCad=False
NumPropType_VerifySignatureWhenIgnoringSignedFile=False
NumPropType_ExtractPdfImages=False
NumPropType_ProcessJtdc=False
BoolPropType_RetainOriginalFile=False

"@
}

function Get-Ncp7373EmailEmbeddedCdrTimeoutLabPolicyRawData {
    $allowedTypes = Get-Sa07LabAllowedFileTypesValue
    $scannersFacet = (New-Sa07LabScannersFacet).TrimEnd()
    $transformationActionsFacet = (New-Ncp7373SpreadsheetCdrTransformationActionsFacet).TrimEnd()

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
NumPropType_CdrTimeoutSec=1
NumPropType_CdrTimeoutAbsoluteSec=1
NumPropType_TransformationTimeout=0
$scannersFacet
$transformationActionsFacet

"@
}

function Get-Ncp7373EmailEmbeddedCdrTimeoutLabPolicyImportPoliciesPath {
    param([string] $OverridePath = '')

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy import JSON not found: $full"
        }
        return $full
    }

    $defaultPath = Join-Path (Join-Path $PSScriptRoot '..\Policies') $script:Ncp7373DefaultImportPoliciesJsonFileName
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "Default policy import JSON not found: $defaultPath"
    }

    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Import-Ncp7373EmailEmbeddedCdrTimeoutLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyImportJson = '',
        [string] $PolicyName = $script:Ncp7373LabPolicyName
    )

    . (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1') | Out-Null
    . (Join-Path $PSScriptRoot 'CoreE2eDebugHook.ps1')

    $jsonPath = Get-Ncp7373EmailEmbeddedCdrTimeoutLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
    $importBody = Read-CoreE2ePolicyImportBodyFromJsonFile -JsonPath $jsonPath
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $importBody
    return @{
        ImportResponse       = $import
        PolicyImportJsonPath = $jsonPath
        PolicyName           = $PolicyName
    }
}
