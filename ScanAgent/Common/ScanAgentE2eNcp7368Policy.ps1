#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook lab policy for NCP-7368 (Remain connected off; idle gateway disconnect).
.NOTES
  Dot-sourced after ScanAgentE2eCorePolicy.ps1.
#>
Set-StrictMode -Version Latest

$script:Ncp7368PolicyName = 'NCP7368-idle'
$script:Ncp7368AssignmentRuleName = 'debug-scan-agents-ncp7368'
$script:Ncp7368StoreIn = 'ncp7368-smb-in'
$script:Ncp7368StoreOut = 'ncp7368-smb-out'
$script:Ncp7368FolderIn = 'c:\test\NCP7368-in'
$script:Ncp7368FolderOut = 'c:\test\NCP7368-out'

function New-Ncp7368CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'NCP7368-idle',
        [string] $SourceRoot = 'c:\test\NCP7368-in',
        [string] $DestRoot = 'c:\test\NCP7368-out',
        [string] $SourceStoreName = 'ncp7368-smb-in',
        [string] $DestinationStoreName = 'ncp7368-smb-out',
        [string] $AssignmentRuleName = 'debug-scan-agents-ncp7368'
    )

    Ensure-Sa05SmbLabFolders -FolderPaths @($SourceRoot, $DestRoot) -MarkerPrefix 'NCP7368'

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw
    $baseRaw = Set-Sa09PolicyRawLabSanitizePolicy -PolicyRawData $baseRaw
    $baseRaw = Set-Sa05PolicyRawIdleDisconnectOnInactivity -PolicyRawData $baseRaw

    $raw = New-Sa05SmbInOutFacetBlock `
        -SourceStoreName $SourceStoreName -SourceRootFolder $SourceRoot `
        -DestinationStoreName $DestinationStoreName -DestinationRootFolder $DestRoot
    $raw += $baseRaw

    $policyId = 9208

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyId
                name           = $PolicyName
                displayName    = "NCP7368 idle disconnect ($SourceRoot -> $DestRoot)"
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $raw
            }
        )
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @([string]$policyId)
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'scan_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-ScanAgentNcp7368CoreDebugPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'NCP7368-idle',
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core importpolicies policy base: $($resolvedBase.Source)"
    $importBody = New-Ncp7368CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' `
        -TemplatePolicyName $TemplatePolicyName -PolicyName $PolicyName

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (NCP7368)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($PolicyName) `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        PolicyBaseSource = $resolvedBase.Source
        PolicyName       = $PolicyName
        SourceRoot       = $script:Ncp7368FolderIn
        DestRoot         = $script:Ncp7368FolderOut
        ImportResponse   = $import
    }
}

function Initialize-ScanAgentNcp7368CoreTestPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'NCP7368-idle',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentNcp7368CoreDebugPolicy -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -PolicyName $PolicyName -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl          = $pushed.HookUrl
        PolicyBaseSource = $imported.PolicyBaseSource
        PolicyName       = $imported.PolicyName
        SourceRoot       = $imported.SourceRoot
        DestRoot         = $imported.DestRoot
        PushResponse     = $pushed.PushResponse
        ImportResponse   = $imported.ImportResponse
    }
}
