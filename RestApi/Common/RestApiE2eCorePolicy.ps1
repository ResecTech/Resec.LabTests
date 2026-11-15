#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook importpolicies helper for REST API lab E2E (RA-01 / NCP-7372).
.NOTES
  Assignment target agent_type rest_api (MachineSafeComponent). Policy base: NCP-7344 office no-CDR lab facets.
#>
Set-StrictMode -Version Latest

$script:Ra01LabPolicyName = 'RA-01-rest-api-lab'
$script:Ra01LabPolicyPlaceholderId = 9372
$script:Ra01DefaultAssignmentRuleName = 'debug-rest-api-ra-01'

$corePolicyRoot = Join-Path $PSScriptRoot '..\..\Core\Common'
. (Join-Path $corePolicyRoot 'CoreE2eNcp7344Policy.ps1')

function New-Ra01RestApiLabPolicyImportBody {
    param(
        [string] $PolicyName = $script:Ra01LabPolicyName,
        [string] $AssignmentRuleName = $script:Ra01DefaultAssignmentRuleName
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:Ra01LabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:Ra01DefaultAssignmentRuleName
    }

    $policyName = $PolicyName.Trim()
    $assignmentRuleName = $AssignmentRuleName.Trim()

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ra01LabPolicyPlaceholderId
                name          = $policyName
                displayName   = 'RA-01 REST API lab (NCP-7372)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = (Get-Ncp7344OfficeNoCdrLabPolicyRawData)
            }
        )
        policyAssociations = @(
            @{
                name       = $assignmentRuleName
                enabled    = $true
                policies   = @($policyName)
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'rest_api'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-Ra01RestApiLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyName = '',
        [string] $AssignmentRuleName = ''
    )

    $body = New-Ra01RestApiLabPolicyImportBody -PolicyName $PolicyName -AssignmentRuleName $AssignmentRuleName
    $import = Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body

    $count = if ($import.PSObject.Properties.Name -contains 'importedPolicyCount') { [int]$import.importedPolicyCount } else { 0 }
    if ($count -lt 1) {
        throw "importpolicies did not import any policies (importedPolicyCount=$count)."
    }

    $assocImported = $false
    if ($import.PSObject.Properties.Name -contains 'policyAssociationsImported') {
        $assocImported = [bool]$import.policyAssociationsImported
    }
    if (-not $assocImported) {
        throw 'importpolicies did not import policyAssociations (policyAssociationsImported=false).'
    }

    $resolvedName = if ([string]::IsNullOrWhiteSpace($PolicyName)) { $script:Ra01LabPolicyName } else { $PolicyName.Trim() }
    $null = Resolve-CoreE2ePolicyIdByName -HookUrl $HookUrl -PolicyName $resolvedName

    return $import
}

function Invoke-Ra01RestApiAgentCommNudge {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $DisconnectHoldSec = 2
    )

    $down = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockon'
    Assert-CoreE2eDebugHookResponse -Response $down -Step 'agentcommblockon'
    if ($DisconnectHoldSec -gt 0) {
        Start-Sleep -Seconds $DisconnectHoldSec
    }

    $up = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockoff'
    Assert-CoreE2eDebugHookResponse -Response $up -Step 'agentcommblockoff'
}

function Install-Ra01RestApiLabCorePolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    Push-CoreE2ePolicyState -HookUrl $HookUrl | Out-Null
    Import-Ra01RestApiLabPolicy -HookUrl $HookUrl | Out-Null
    Invoke-Ra01RestApiAgentCommNudge -HookUrl $HookUrl
}