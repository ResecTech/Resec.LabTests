#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7408 lab policies: block scripts vs allow-all, plus a .ps1 path assignment rule.
.NOTES
  Debug sanitize with the allow policy is overridden by PolicyConditions to the block policy.
  WMC resubmit with the allow policy must bypass assignment rules (NCP-7408).
#>
Set-StrictMode -Version Latest

$script:Ncp7408BlockScriptsPolicyName = 'NCP7408-block-scripts'
$script:Ncp7408AllowScriptsPolicyName = 'NCP7408-allow-scripts'
$script:Ncp7408BlockPolicyPlaceholderId = 74081
$script:Ncp7408AllowPolicyPlaceholderId = 74082

. (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1')
. (Join-Path $PSScriptRoot '..\..\ScanAgent\Common\ScanAgentE2eCorePolicy.ps1')

function Get-Ncp7408BlockScriptsAllowedFileTypesValue {
    return 'Archives=True|CAD=True|Databases=True|Documents (Common)=True|Documents (Uncommon)=True|Email=True|Embedded Office Objects=True|Executables=True|Images=True|Media Files=True|Model=True|Others=True|Scripts=False|Unknown File=True|Unsafe=True'
}

function Get-Ncp7408PolicyRawData {
    param(
        [Parameter(Mandatory)]
        [bool] $AllowScripts
    )

    $allowedTypes = if ($AllowScripts) {
        Get-Sa07LabAllowedFileTypesValue
    }
    else {
        Get-Ncp7408BlockScriptsAllowedFileTypesValue
    }

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

function New-Ncp7408PolicyImportBody {
    $blockName = $script:Ncp7408BlockScriptsPolicyName
    $allowName = $script:Ncp7408AllowScriptsPolicyName

    $rule = [ordered]@{
        name       = 'NCP7408-ps1-path-block'
        enabled    = $true
        policies   = @($blockName)
        conditions = @(
            [ordered]@{
                item      = 'file_path'
                condition = 'matches'
                target    = '\.ps1$'
                op        = 'AND'
            }
        )
    }

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ncp7408BlockPolicyPlaceholderId
                name          = $blockName
                displayName   = 'NCP-7408 block scripts'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = (Get-Ncp7408PolicyRawData -AllowScripts $false)
            }
            @{
                id            = $script:Ncp7408AllowPolicyPlaceholderId
                name          = $allowName
                displayName   = 'NCP-7408 allow scripts'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = (Get-Ncp7408PolicyRawData -AllowScripts $true)
            }
        )
        policyAssociations = @($rule)
    }
}

function Import-Ncp7408ResubmitPolicyLabPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    $body = New-Ncp7408PolicyImportBody
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}