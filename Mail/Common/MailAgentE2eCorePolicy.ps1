#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook importpolicies helper for Mail Agent lab E2E (MA-01, MA-02-C).

.NOTES
  Assignment target agent_type mail_agent.   Base sanitization facets: permissive Basic, scanners off (fast inbound with Send Immediate Response off).
  Scripts=False and Executables=False for step D blocked attachment; NumPropType_DisallowedFilesInArchivesBehavior=0 (block container) so inbound SMTP gets 5xx instead of strip+250.
  Email Agent Settings: Send Immediate Response off, next hop SimpleMailServer.
#>
Set-StrictMode -Version Latest

$script:MailAgentE2eLabPolicyName = 'MA-mail-lab'
$script:MailAgentE2eLabPolicyPlaceholderId = 9101
$script:MailAgentE2eDefaultAssignmentRuleName = 'debug-mail-agent-ma-lab'

$corePolicyRoot = Join-Path $PSScriptRoot '..\..\Core\Common'
. (Join-Path $corePolicyRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $corePolicyRoot 'CoreE2eNcp7344Policy.ps1')

function Get-MailAgentE2eCoreDebugHookUrl {
    param(
        [string] $BaseUrl = '',
        [string] $Override = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $trimmed = $Override.Trim()
        if ($trimmed -match '/debug/hook') {
            return $trimmed
        }
        return ($trimmed.TrimEnd('/') + '/debug/hook')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_DEBUG_HOOK_URL)) {
        return $env:CORE_E2E_DEBUG_HOOK_URL.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        return ($BaseUrl.Trim().TrimEnd('/') + '/debug/hook')
    }

    return (Get-CoreE2eDebugHookUrl)
}

function Get-MailAgentE2eDefaultRelayName {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_RELAY_NAME)) {
        return $env:MAIL_E2E_RELAY_NAME.Trim()
    }

    return 'mail'
}

function Get-MailAgentE2eDefaultLabTempFolder {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [System.IO.Path]::GetFullPath($Override.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_TEMP_FOLDER)) {
        return [System.IO.Path]::GetFullPath($env:MAIL_E2E_TEMP_FOLDER.Trim())
    }

    return 'C:\ReSec\SMTP Temp'
}

function New-MailAgentE2eEmailInfrastructureFacetRaw {
    param(
        [string] $RelayName = 'mail',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = 'C:\ReSec\SMTP Temp',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = ''
    )

    $relay = $RelayName.Trim()
    $temp = $TempFolder.Trim()
    $hop = $NextHopHost.Trim()
    $useTls = if ($NextHopUseTls) { 'True' } else { 'False' }
    $skipTls = if ($NextHopSkipTlsCertificateValidation) { 'True' } else { 'False' }
    $incomingTlsSubject = if ([string]::IsNullOrWhiteSpace($IncomingTlsCertificateSubject)) { '' } else { $IncomingTlsCertificateSubject.Trim() }

    return @"
;Facet Email Agent Settings:Email Agent Settings
StrPropType_ScannedFileLocationName=MA-mail-lab
StrPropType_ScannedFileEmailLocationRelayComputer=$relay
NumPropType_ScannedFilesEmailLocationFacetIsFailOpen=0
NumPropType_ScannedFileEmailImmediateResponseConfirmation=False
StrPropType_ScannedFileEmailLocationTempFolder=$temp
NumPropType_ScannedFileEmailLocationIncomingPort=$InboundPort
StrPropType_ScannedFileEmailLocationNextHopServerAddress=$hop
StrPropType_ScannedFileEmailLocationNextHopPort=$NextHopPort
StrPropType_SmtpSenderIncomingTlsCertificateSubject=$incomingTlsSubject
NumPropType_ScannedFileEmailLocationNextHopUseTls=$useTls
NumPropType_ScannedFileEmailLocationNextHopSkipTlsCertificateValidation=$skipTls

"@
}

function New-MailAgentE2eMa03DualHopEmailFacetRaw {
    <#
    Dual next hop: comma-separated server addresses (dead first, valid second); single shared NextHopPort (default 25).
    Per-hop TLS flags remain comma-separated when they differ.
    #>
    param(
        [string] $RelayName = 'mail',
        [Parameter(Mandatory)][string] $DeadHopHost,
        [Parameter(Mandatory)][string] $ValidHopHost,
        [int] $NextHopPort = 25,
        [int] $InboundPort = 25,
        [string] $TempFolder = 'C:\ReSec\SMTP Temp',
        [bool] $DeadHopUseTls = $false,
        [bool] $ValidHopUseTls = $true,
        [bool] $DeadHopSkipTlsCertificateValidation = $true,
        [bool] $ValidHopSkipTlsCertificateValidation = $true
    )

    $relay = $RelayName.Trim()
    $temp = $TempFolder.Trim()
    $deadHop = $DeadHopHost.Trim()
    $validHop = $ValidHopHost.Trim()
    $addr = '{0},{1}' -f $deadHop, $validHop
    $useTls = '{0},{1}' -f ($(if ($DeadHopUseTls) { 'True' } else { 'False' })), ($(if ($ValidHopUseTls) { 'True' } else { 'False' }))
    $skipTls = '{0},{1}' -f ($(if ($DeadHopSkipTlsCertificateValidation) { 'True' } else { 'False' })), ($(if ($ValidHopSkipTlsCertificateValidation) { 'True' } else { 'False' }))

    return @"
;Facet Email Agent Settings:Email Agent Settings
StrPropType_ScannedFileLocationName=MA-mail-lab
StrPropType_ScannedFileEmailLocationRelayComputer=$relay
NumPropType_ScannedFilesEmailLocationFacetIsFailOpen=0
NumPropType_ScannedFileEmailImmediateResponseConfirmation=False
StrPropType_ScannedFileEmailLocationTempFolder=$temp
NumPropType_ScannedFileEmailLocationIncomingPort=$InboundPort
StrPropType_ScannedFileEmailLocationNextHopServerAddress=$addr
StrPropType_ScannedFileEmailLocationNextHopPort=$NextHopPort
NumPropType_ScannedFileEmailLocationNextHopUseTls=$useTls
NumPropType_ScannedFileEmailLocationNextHopSkipTlsCertificateValidation=$skipTls

"@
}

function New-MailAgentE2eEmailSignatureFacetRaw {
    return @"
;Facet Email Signature Settings:Email Signature Settings
StrPropType_EmailSignatureFacetTitle=Secured by Resec (MA E2E lab)

"@
}

function New-MailAgentE2eRelaySettingsFacetRaw {
    param([string] $RelayName = 'mail')

    $relay = $RelayName.Trim()
    return @"
;Facet Relay Settings:Relay Settings
StrPropType_RelayName=$relay

"@
}

function Get-MailAgentE2eLabAllowedFileTypesValue {
    $all = Get-Sa07LabAllowedFileTypesValue
    # Step D blocked .vbs is often classified as Executables, not only Scripts.
    return $all.Replace('Scripts=True', 'Scripts=False').Replace('Executables=True', 'Executables=False')
}

function Get-MailAgentE2eLabPolicyRawData {
    param(
        [string] $RelayName = 'mail',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = 'C:\ReSec\SMTP Temp',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = '',
        [string] $EmailInfrastructureFacetRaw = ''
    )

    $allowedTypes = Get-MailAgentE2eLabAllowedFileTypesValue
    $scannersFacet = (New-Sa07LabScannersFacet).TrimEnd()
    $transformationActionsFacet = (New-SaLabDisabledTransformationActionsFacet).TrimEnd()
    if (-not [string]::IsNullOrWhiteSpace($EmailInfrastructureFacetRaw)) {
        $emailInfra = $EmailInfrastructureFacetRaw.TrimEnd()
        if ($emailInfra -notmatch '(?i)^\s*;Facet\s+Email Agent Settings') {
            throw 'EmailInfrastructureFacetRaw must start with ;Facet Email Agent Settings:Email Agent Settings (full facet block from WebMC export or documented policy keys).'
        }
    }
    else {
        $emailInfra = (New-MailAgentE2eEmailInfrastructureFacetRaw -RelayName $RelayName -NextHopHost $NextHopHost `
            -NextHopPort $NextHopPort -InboundPort $InboundPort -TempFolder $TempFolder `
            -NextHopUseTls:$NextHopUseTls -NextHopSkipTlsCertificateValidation:$NextHopSkipTlsCertificateValidation `
            -IncomingTlsCertificateSubject $IncomingTlsCertificateSubject).TrimEnd()
    }
    $emailSignature = (New-MailAgentE2eEmailSignatureFacetRaw).TrimEnd()
    $relaySettings = (New-MailAgentE2eRelaySettingsFacetRaw -RelayName $RelayName).TrimEnd()

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
NumPropType_DisallowedFilesInArchivesBehavior=0
$scannersFacet
$transformationActionsFacet
$relaySettings
$emailInfra
$emailSignature

"@
}

function New-MailAgentE2eLabPolicyImportBody {
    param(
        [string] $PolicyName = $script:MailAgentE2eLabPolicyName,
        [string] $AssignmentRuleName = $script:MailAgentE2eDefaultAssignmentRuleName,
        [string] $RelayName = 'mail',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = 'C:\ReSec\SMTP Temp',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = '',
        [string] $EmailInfrastructureFacetRaw = ''
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:MailAgentE2eLabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:MailAgentE2eDefaultAssignmentRuleName
    }

    $policyName = $PolicyName.Trim()
    $assignmentRuleName = $AssignmentRuleName.Trim()
    $raw = Get-MailAgentE2eLabPolicyRawData -RelayName $RelayName -NextHopHost $NextHopHost `
        -NextHopPort $NextHopPort -InboundPort $InboundPort -TempFolder $TempFolder `
        -NextHopUseTls:$NextHopUseTls -NextHopSkipTlsCertificateValidation:$NextHopSkipTlsCertificateValidation `
        -IncomingTlsCertificateSubject $IncomingTlsCertificateSubject `
        -EmailInfrastructureFacetRaw $EmailInfrastructureFacetRaw

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:MailAgentE2eLabPolicyPlaceholderId
                name          = $policyName
                displayName   = 'Mail Agent MA lab (Send Immediate Response off, next hop capture SMTP)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $raw
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
                        target    = 'mail_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-MailAgentE2eLabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $PolicyName = '',
        [string] $AssignmentRuleName = '',
        [string] $RelayName = 'mail',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = 'C:\ReSec\SMTP Temp',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = '',
        [string] $EmailInfrastructureFacetRaw = ''
    )

    $body = New-MailAgentE2eLabPolicyImportBody -PolicyName $PolicyName -AssignmentRuleName $AssignmentRuleName `
        -RelayName $RelayName -NextHopHost $NextHopHost -NextHopPort $NextHopPort `
        -InboundPort $InboundPort -TempFolder $TempFolder -NextHopUseTls:$NextHopUseTls `
        -NextHopSkipTlsCertificateValidation:$NextHopSkipTlsCertificateValidation `
        -IncomingTlsCertificateSubject $IncomingTlsCertificateSubject `
        -EmailInfrastructureFacetRaw $EmailInfrastructureFacetRaw
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

    $resolvedName = if ([string]::IsNullOrWhiteSpace($PolicyName)) { $script:MailAgentE2eLabPolicyName } else { $PolicyName.Trim() }
    $null = Resolve-CoreE2ePolicyIdByName -HookUrl $HookUrl -PolicyName $resolvedName

    return $import
}

function Invoke-MailAgentE2eAgentCommNudge {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $DisconnectHoldSec = 2
    )

    Write-MailAgentE2eCorrelationLogMark -TestId 'MA-01' -Mark 'agentcomm | blockon (policy reload)' -CoreDebugHookUrl $HookUrl

    $down = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockon'
    Assert-CoreE2eDebugHookResponse -Response $down -Step 'agentcommblockon'
    if ($DisconnectHoldSec -gt 0) {
        Start-Sleep -Seconds $DisconnectHoldSec
    }

    $up = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockoff'
    Assert-CoreE2eDebugHookResponse -Response $up -Step 'agentcommblockoff'

    Write-MailAgentE2eCorrelationLogMark -TestId 'MA-01' -Mark 'agentcomm | blockoff (policy reload done)' -CoreDebugHookUrl $HookUrl
}

function Install-MailAgentE2eLabCorePolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $RelayName = '',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = '',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = '',
        [string] $EmailInfrastructureFacetRaw = '',
        [string] $TestId = 'MA-01'
    )

    $relay = Get-MailAgentE2eDefaultRelayName -Override $RelayName
    $temp = Get-MailAgentE2eDefaultLabTempFolder -Override $TempFolder

    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark "policy | push+import start relay=$relay nextHop=${NextHopHost}:$NextHopPort" `
        -CoreDebugHookUrl $HookUrl

    Push-CoreE2ePolicyState -HookUrl $HookUrl | Out-Null
    Import-MailAgentE2eLabPolicy -HookUrl $HookUrl -RelayName $relay -NextHopHost $NextHopHost `
        -NextHopPort $NextHopPort -InboundPort $InboundPort -TempFolder $temp `
        -NextHopUseTls:$NextHopUseTls -NextHopSkipTlsCertificateValidation:$NextHopSkipTlsCertificateValidation `
        -IncomingTlsCertificateSubject $IncomingTlsCertificateSubject `
        -EmailInfrastructureFacetRaw $EmailInfrastructureFacetRaw | Out-Null
    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark 'policy | push+import complete (nudge after mail agent connects)' `
        -CoreDebugHookUrl $HookUrl
}

function Update-MailAgentE2eLabCorePolicy {
    <#
    Re-import lab policy after initial push (MA-03 next-hop swaps) and nudge agent to reload.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $MailAgentDebugUrl,
        [string] $RelayName = '',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $InboundPort = 25,
        [string] $TempFolder = '',
        [bool] $NextHopUseTls = $false,
        [bool] $NextHopSkipTlsCertificateValidation = $true,
        [string] $IncomingTlsCertificateSubject = '',
        [string] $EmailInfrastructureFacetRaw = '',
        [string] $TestId = 'MA-03'
    )

    $relay = Get-MailAgentE2eDefaultRelayName -Override $RelayName
    $temp = Get-MailAgentE2eDefaultLabTempFolder -Override $TempFolder

    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark "policy | re-import relay=$relay nextHop=${NextHopHost}:$NextHopPort" `
        -CoreDebugHookUrl $HookUrl -MailAgentDebugUrl $MailAgentDebugUrl

    Import-MailAgentE2eLabPolicy -HookUrl $HookUrl -RelayName $relay -NextHopHost $NextHopHost `
        -NextHopPort $NextHopPort -InboundPort $InboundPort -TempFolder $temp `
        -NextHopUseTls:$NextHopUseTls -NextHopSkipTlsCertificateValidation:$NextHopSkipTlsCertificateValidation `
        -IncomingTlsCertificateSubject $IncomingTlsCertificateSubject `
        -EmailInfrastructureFacetRaw $EmailInfrastructureFacetRaw | Out-Null

    Invoke-MailAgentE2eAgentCommNudge -HookUrl $HookUrl -DisconnectHoldSec 3
    Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $MailAgentDebugUrl -HookUrl $HookUrl -TestId $TestId
}

function Restore-MailAgentE2eLabCorePolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    Pop-CoreE2ePolicyState -HookUrl $HookUrl | Out-Null
}