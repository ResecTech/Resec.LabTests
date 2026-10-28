#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook lab policies for NCP-7328 (source/destination drive dropdown: 1 vs many SMB roots).

.NOTES
  Dot-sourced after ScanAgentE2eCorePolicy.ps1 (reuses SMB facet helpers and Core hook routines).
#>
Set-StrictMode -Version Latest

$script:Ncp7328PolicyOne = 'NCP7328-one'
$script:Ncp7328PolicyMulti = 'NCP7328-multi'
$script:Ncp7328AssignmentRuleName = 'debug-scan-agents-ncp7328'

$script:Ncp7328StoreInA = 'ncp7328-in-a'
$script:Ncp7328StoreInB = 'ncp7328-in-b'
$script:Ncp7328StoreOutA = 'ncp7328-out-a'
$script:Ncp7328StoreOutB = 'ncp7328-out-b'

$script:Ncp7328FolderInA = 'c:\temp\NCP7328-in-a'
$script:Ncp7328FolderInB = 'c:\temp\NCP7328-in-b'
$script:Ncp7328FolderOutA = 'c:\test\NCP7328-out-a'
$script:Ncp7328FolderOutB = 'c:\test\NCP7328-out-b'

function New-Ncp7328SmbLocationBlock {
    param(
        [Parameter(Mandatory)]
        [string[]] $SourceStores,
        [Parameter(Mandatory)]
        [string[]] $SourceFolders,
        [Parameter(Mandatory)]
        [string[]] $DestinationStores,
        [Parameter(Mandatory)]
        [string[]] $DestinationFolders
    )

    if ($SourceStores.Count -ne $SourceFolders.Count) {
        throw 'SourceStores and SourceFolders must have the same length.'
    }
    if ($DestinationStores.Count -ne $DestinationFolders.Count) {
        throw 'DestinationStores and DestinationFolders must have the same length.'
    }

    $block = ''
    for ($i = 0; $i -lt $SourceStores.Count; $i++) {
        $block += New-Sa05SmbSourceFacet -StoreName $SourceStores[$i] -RootFolder $SourceFolders[$i] -SortOrder ($i + 1)
    }
    for ($i = 0; $i -lt $DestinationStores.Count; $i++) {
        $block += New-Sa05SmbDestinationFacet -StoreName $DestinationStores[$i] -RootFolder $DestinationFolders[$i] -SortOrder ($i + 1 + $SourceStores.Count)
    }
    return $block
}

function New-Ncp7328CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = ''
    )

    Ensure-Sa05SmbLabFolders -FolderPaths @(
        $script:Ncp7328FolderInA,
        $script:Ncp7328FolderInB,
        $script:Ncp7328FolderOutA,
        $script:Ncp7328FolderOutB
    ) -MarkerPrefix 'NCP7328'

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw
    $baseRemainConnected = Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    $rawOne = (New-Ncp7328SmbLocationBlock `
        -SourceStores @($script:Ncp7328StoreInA) -SourceFolders @($script:Ncp7328FolderInA) `
        -DestinationStores @($script:Ncp7328StoreOutA) -DestinationFolders @($script:Ncp7328FolderOutA)) + $baseRemainConnected
    $rawMulti = (New-Ncp7328SmbLocationBlock `
        -SourceStores @($script:Ncp7328StoreInA, $script:Ncp7328StoreInB) `
        -SourceFolders @($script:Ncp7328FolderInA, $script:Ncp7328FolderInB) `
        -DestinationStores @($script:Ncp7328StoreOutA, $script:Ncp7328StoreOutB) `
        -DestinationFolders @($script:Ncp7328FolderOutA, $script:Ncp7328FolderOutB)) + $baseRemainConnected

    $policyIdOne = 9202
    $policyIdMulti = 9203

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyIdOne
                name           = $script:Ncp7328PolicyOne
                displayName    = "NCP7328 one source + one destination ($($script:Ncp7328FolderInA))"
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $rawOne
            },
            @{
                id             = $policyIdMulti
                name           = $script:Ncp7328PolicyMulti
                displayName    = 'NCP7328 two sources + two destinations'
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $rawMulti
            }
        )
        policyAssociations = @(
            @{
                name       = $script:Ncp7328AssignmentRuleName
                enabled    = $true
                policies   = @(
                    [string]$policyIdOne
                    [string]$policyIdMulti
                )
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

function Import-ScanAgentNcp7328CoreDebugPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $importBody = New-Ncp7328CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' -TemplatePolicyName $TemplatePolicyName

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (NCP7328)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe

    $expectedNames = @(
        $script:Ncp7328PolicyOne,
        $script:Ncp7328PolicyMulti
    )
    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames $expectedNames `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    if ($policyList.ok -ne $true) {
        throw 'policy.list failed after NCP7328 Core import.'
    }

    return [pscustomobject]@{
        PolicyBaseSource = $resolvedBase.Source
        ImportResponse   = $import
        AgentPolicyList  = $policyList
        PolicyNames      = $expectedNames
    }
}

function Initialize-ScanAgentNcp7328CoreTestPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentNcp7328CoreDebugPolicies -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl          = $pushed.HookUrl
        PolicyBaseSource = $imported.PolicyBaseSource
        PushResponse     = $pushed.PushResponse
        ImportResponse   = $imported.ImportResponse
        PolicyNames      = $imported.PolicyNames
    }
}
