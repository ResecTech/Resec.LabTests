#Requires -Version 5.1
<#
  Core importpolicies helper for NCP-7378 using QA export XML (Scan Agent IN / Scan Agent OUT).
  Dot-source after ScanAgentE2eCorePolicy.ps1.
#>
Set-StrictMode -Version Latest

function Get-Ncp7378QaExportPolicyNodes {
    param(
        [Parameter(Mandatory)]
        [string] $ExportXmlPath,
        [string[]] $PolicyNames = @('Scan Agent OUT', 'Scan Agent IN')
    )

    $full = [System.IO.Path]::GetFullPath($ExportXmlPath)
    if (-not (Test-Path -LiteralPath $full)) {
        throw "QA export XML not found: $full"
    }

    [xml]$doc = Get-Content -LiteralPath $full -Encoding UTF8
    $nodes = @()
    foreach ($name in $PolicyNames) {
        $match = @($doc.ImportExportContainer.Policies.Policy | Where-Object { $_.Name -eq $name })
        if ($match.Count -lt 1) {
            throw "Policy '$name' not found in $full"
        }

        $p = $match[0]
        $raw = [string]$p.PolicyRawData
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "Policy '$name' has empty PolicyRawData in $full"
        }

        $nodes += [pscustomobject]@{
            Id           = [string]$p.Id
            Name         = [string]$p.Name
            DisplayName  = [string]$p.DisplayName
            PolicyRawData = $raw
        }
    }

    return ,$nodes
}

function New-Ncp7378QaExportCorePolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $ExportXmlPath,
        [string[]] $PolicyNames = @('Scan Agent OUT', 'Scan Agent IN'),
        [string] $AssignmentRuleName = 'debug-ncp7378-qa-scan-agent'
    )

    $policyNodes = Get-Ncp7378QaExportPolicyNodes -ExportXmlPath $ExportXmlPath -PolicyNames $PolicyNames
    $importPolicies = @(
        foreach ($node in $policyNodes) {
            @{
                id             = [int]$node.Id
                name           = $node.Name
                displayName    = $node.DisplayName
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $node.PolicyRawData
            }
        }
    )

    return @{
        command            = 'importpolicies'
        policies           = $importPolicies
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @($policyNodes | ForEach-Object { [string]$_.Id })
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

function Import-ScanAgentNcp7378QaExportCorePolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string] $ExportXmlPath,
        [string[]] $PolicyNames = @('Scan Agent OUT', 'Scan Agent IN'),
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $body = New-Ncp7378QaExportCorePolicyImportBody -ExportXmlPath $ExportXmlPath -PolicyNames $PolicyNames
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core importpolicies QA export ($ExportXmlPath)"
    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $body
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (NCP7378 QA export)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames $PolicyNames `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs
    return $import
}

function Initialize-ScanAgentNcp7378QaExportCorePolicies {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [Parameter(Mandatory)]
        [string] $ExportXmlPath,
        [string[]] $PolicyNames = @('Scan Agent OUT', 'Scan Agent IN'),
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $import = Import-ScanAgentNcp7378QaExportCorePolicies -HookUrl $pushed.HookUrl -Exe $Exe `
        -ExportXmlPath $ExportXmlPath -PolicyNames $PolicyNames `
        -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl        = $pushed.HookUrl
        ExportXmlPath  = $ExportXmlPath
        PolicyNames    = $PolicyNames
        PushResponse   = $pushed.PushResponse
        ImportResponse = $import
    }
}