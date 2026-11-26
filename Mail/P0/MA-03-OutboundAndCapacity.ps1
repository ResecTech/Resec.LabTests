#Requires -Version 5.1
<#
.SYNOPSIS
  MA-03: Outbound and capacity (minimal functional test plan P0 #3).

.DESCRIPTION
  Automates MA-03 substeps A–D with explicit Expect/Actual logging per step.
  Step A1 requires dual next-hop policy facet raw from WebMC (-Ma03ADualHopEmailFacetRaw or -Ma03ADualHopEmailFacetPath).
  When -Ma03ValidNextHopHost targets Microsoft 365 (e.g. dev-resec-co.mail.protection.outlook.com), use -MailTo user@dev.resec.co (default); @example.com is rejected by EOP (RFC 2606).
  Step B sets StrPropType_SmtpSenderIncomingTlsCertificateSubject (auto-resolved from cert store unless -Ma03IncomingTlsCertificateSubject), restarts the mail agent, sends one message to capture next hop.
  Steps A/B and recovery sends use one message each (SendBulkAttachmentMail with EmailCount=1). Step C still uses parallel load by design.
  Step C uses mail agent debug overload (default mode sessions). Step D uses debug stats until WMC System Health REST is documented.

.NOTES
  Exit 0 = all selected steps passed; Exit 1 = any failed.
#>
[CmdletBinding()]
param(
    [string] $MailTempFolder = '',
    [string] $CoreDebugBaseUrl = '',
    [string] $MailAgentDebugBaseUrl = '',
    [string] $CoreRestBaseUrl = '',
    [int] $SimpleMailPort = 26,
    [double] $ResponseDelaySeconds = 2,
    [int] $InboundSmtpPort = 25,
    [string] $InboundSmtpServer = '127.0.0.1',
    [string] $MailTo = 'user@dev.resec.co',
    [string] $MailFrom = 'sender@example.com',
    [string] $SimpleMailServerPath = '',
    [string] $SendBulkAttachmentMailPath = '',
    [string] $CaptureSaveFolder = '',
    [string] $SimpleMailListenHost = '127.0.0.1',
    [int] $SimpleMailStartupTimeoutSec = 20,
    [int] $DeliveryTimeoutSec = 120,
    [int] $OutboundFailureTimeoutSec = 200,
    [switch] $SkipCorePolicySetup,
    [string] $MailRelayName = '',
    [string] $CoreDebugHookUrl = '',
    [switch] $SkipWmcCheck,
    [string] $WmcUser = '',
    [string] $WmcPassword = '',
    [switch] $SkipStartSimpleMailServer,
    [string] $MailAgentExePath = '',
    [int] $MailAgentStartupTimeoutSec = 90,
    [switch] $SkipStartMailAgent,
    [string] $Ma03ADualHopEmailFacetRaw = '',
    [string] $Ma03ADualHopEmailFacetPath = '',
    [string] $Ma03DeadNextHopHost = 'ma03-e2e-dead.invalid',
    [int] $Ma03DeadNextHopPort = 25,
    [string] $Ma03ValidNextHopHost = 'dev-resec-co.mail.protection.outlook.com',
    [int] $Ma03ValidNextHopPort = 25,
    [bool] $Ma03ValidNextHopUseTls = $true,
    [switch] $Ma03A1SingleValidHop,
    [string] $DeadHopHost = '',
    [int] $DeadHopPort = 25,
    [string] $Ma03IncomingTlsCertificateSubject = '',
    [string] $TlsRelayHost = '',
    [int] $TlsRelayPort = 0,
    [ValidateSet('sessions', 'spoolfull', 'spoolcap', 'processing')]
    [string] $StepCOverloadMode = 'sessions',
    [int] $StepCParallelSends = 22,
    [int] $StepCEmailCount = 24,
    [switch] $SkipStepA,
    [switch] $SkipStepB,
    [switch] $SkipStepC,
    [switch] $SkipStepD
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-MailDeployRequirements
}

$script:MaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

$coreCommon = Join-Path (Get-LabTestsRoot) 'Core\Common'
. (Join-Path $coreCommon 'CoreE2eWmcApi.ps1')
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eCorePolicy.ps1')
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eTlsCert.ps1')
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eMa03.ps1')

Assert-MailAgentE2eBulkPrerequisites -CallingScriptRoot $PSScriptRoot `
    -SimpleMailServerPathOverride $SimpleMailServerPath `
    -SendBulkAttachmentMailPathOverride $SendBulkAttachmentMailPath

$script:TestId = 'MA-03'
$script:TestTitle = 'MA-03 outbound and capacity (minimal functional test plan)'
$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:EvidencePaths = New-Object System.Collections.Generic.List[string]
$script:PolicyStackPushed = $false
$script:CoreDebugHookUrl = $null
$script:MaE2eEmitLogMarks = $true
$script:MaE2eMailAgentDebugUrl = $null

$mailAgentProcess = $null
$mailAgentStartedByScript = $false
$simpleMailProcess = $null
$simpleMailStartedByScript = $false
$lab = $null
$runLogPath = $null
$startedAtUtc = [DateTimeOffset]::UtcNow

function Get-Ma03CoreRestUrl {
    if (-not [string]::IsNullOrWhiteSpace($CoreRestBaseUrl)) {
        return $CoreRestBaseUrl.TrimEnd('/')
    }
    $debug = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    return $debug.TrimEnd('/')
}

try {
    $runLogPath = Start-MailAgentE2eRunLog -TestId $script:TestId

    $MailAgentDebugBaseUrl = Get-MailAgentDebugBaseUrl -Override $MailAgentDebugBaseUrl
    $script:MaE2eMailAgentDebugUrl = $MailAgentDebugBaseUrl
    $CoreDebugBaseUrl = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    $coreRestUrl = Get-Ma03CoreRestUrl

    $smsExe = Resolve-SimpleMailServerPath -CallingScriptRoot $PSScriptRoot -Path $SimpleMailServerPath
    $bulkExe = Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $PSScriptRoot -Path $SendBulkAttachmentMailPath
    $smsConfig = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\simple-mail-server.appsettings.json'

    $script:CoreDebugHookUrl = Get-MailAgentE2eCoreDebugHookUrl -BaseUrl $CoreDebugBaseUrl -Override $CoreDebugHookUrl
    Write-Ma03Step 'MA-03: waiting for Core readiness.'
    Wait-MailAgentCoreReady -BaseUrl $CoreDebugBaseUrl | Out-Null

    $policyTempFolder = Get-MailAgentE2eDefaultLabTempFolder -Override $MailTempFolder
    if (-not $SkipCorePolicySetup) {
        Write-Ma03Step 'MA-03: install baseline mail lab policy (capture next hop, Send Immediate Response off).'
        Install-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl -RelayName $MailRelayName `
            -NextHopHost $SimpleMailListenHost -NextHopPort $SimpleMailPort -InboundPort $InboundSmtpPort `
            -TempFolder $policyTempFolder -TestId $script:TestId
        $script:PolicyStackPushed = $true
    }

    Prepare-MailAgentE2eFreshInboundLab -BaseUrl $MailAgentDebugBaseUrl -TempFolderOverride $MailTempFolder `
        -CoreDebugHookUrl $script:CoreDebugHookUrl -TestId $script:TestId

    $mailEnsure = Ensure-MailAgentE2eProcessRunning -CallingScriptRoot $PSScriptRoot `
        -BaseUrl $MailAgentDebugBaseUrl -MailAgentExePath $MailAgentExePath `
        -ExpectedInboundPort $InboundSmtpPort -StartupTimeoutSec $MailAgentStartupTimeoutSec `
        -SkipStart:$SkipStartMailAgent
    $mailAgentProcess = $mailEnsure.Process
    $mailAgentStartedByScript = [bool]$mailEnsure.StartedByScript
    $null = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort

    if ($script:PolicyStackPushed) {
        Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $MailAgentDebugBaseUrl -HookUrl $script:CoreDebugHookUrl -TestId $script:TestId
    }

    $relayName = Get-MailAgentE2eDefaultRelayName -Override $MailRelayName

    $wmcToken = $null
    if (-not $SkipWmcCheck) {
        Write-Ma03Step 'WMC login (required for MA-03 A failure row and Pass checks).'
        $wmcToken = Connect-CoreE2eWmcRestSession -BaseUrl $coreRestUrl -User $WmcUser -Password $WmcPassword
    }
    elseif (-not $SkipStepA) {
        throw 'MA-03 step A requires WMC; do not use -SkipWmcCheck for full MA-03.'
    }

    $lab = Initialize-MailAgentE2eMa03SharedLab -CallingScriptRoot $PSScriptRoot `
        -MailAgentDebugUrl $MailAgentDebugBaseUrl -CoreDebugHookUrl $script:CoreDebugHookUrl `
        -BulkExe $bulkExe -SmsExe $smsExe -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
        -ResponseDelaySeconds $ResponseDelaySeconds -CaptureSaveFolder $CaptureSaveFolder `
        -SmsConfig $smsConfig -SimpleMailStartupTimeoutSec $SimpleMailStartupTimeoutSec `
        -SkipStartSimpleMailServer:$SkipStartSimpleMailServer -InboundPort $InboundSmtpPort
    $simpleMailProcess = $lab.SimpleMailProcess
    $simpleMailStartedByScript = $lab.SimpleMailStartedByScript

    if (-not $SkipStepA) {
        Invoke-Ma03StepA -Lab $lab -HookUrl $script:CoreDebugHookUrl -RelayName $relayName `
            -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder `
            -DeadHopHost $Ma03DeadNextHopHost -DeadHopPort $Ma03DeadNextHopPort `
            -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
            -DualHopFacetRaw $Ma03ADualHopEmailFacetRaw -DualHopFacetPath $Ma03ADualHopEmailFacetPath `
            -ValidHopHost $Ma03ValidNextHopHost -ValidHopPort $Ma03ValidNextHopPort -ValidHopUseTls:$Ma03ValidNextHopUseTls `
            -A1SingleValidHop:$Ma03A1SingleValidHop `
            -CoreRestUrl $coreRestUrl -WmcToken $wmcToken -InboundServer $InboundSmtpServer `
            -MailFrom $MailFrom -MailTo $MailTo -OutboundFailureTimeoutSec $OutboundFailureTimeoutSec
    }
    else {
        Write-Ma03Step 'SKIP MA-03 A (-SkipStepA).'
    }

    if (-not $SkipStepB) {
        Invoke-Ma03StepB -Lab $lab -HookUrl $script:CoreDebugHookUrl -RelayName $relayName `
            -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder `
            -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
            -InboundServer $InboundSmtpServer -MailFrom $MailFrom -MailTo $MailTo `
            -IncomingTlsCertificateSubject $Ma03IncomingTlsCertificateSubject `
            -CallingScriptRoot $PSScriptRoot -MailAgentExePath $MailAgentExePath `
            -MailAgentStartupTimeoutSec $MailAgentStartupTimeoutSec -WmcToken $wmcToken -CoreRestUrl $coreRestUrl
    }
    else {
        Write-Ma03Step 'SKIP MA-03 B (-SkipStepB).'
    }

    if (-not $SkipStepC) {
        Invoke-Ma03StepC -Lab $lab -HookUrl $script:CoreDebugHookUrl -RelayName $relayName `
            -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder `
            -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
            -InboundServer $InboundSmtpServer -MailFrom $MailFrom -MailTo $MailTo `
            -OverloadMode $StepCOverloadMode -ParallelSends $StepCParallelSends -EmailCount $StepCEmailCount `
            -WmcToken $wmcToken -CoreRestUrl $coreRestUrl
    }
    else {
        Write-Ma03Step 'SKIP MA-03 C (-SkipStepC).'
    }

    if (-not $SkipStepD) {
        Invoke-Ma03StepD -MailAgentDebugUrl $MailAgentDebugBaseUrl -RelayName $relayName
    }
    else {
        Write-Ma03Step 'SKIP MA-03 D (-SkipStepD).'
    }

    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    if ($script:MaE2eEmitLogMarks) {
        Write-MailAgentE2eCorrelationLogMark -TestId $script:TestId -Mark "FAILED | $($_.Exception.Message)" `
            -CoreDebugHookUrl $script:CoreDebugHookUrl -MailAgentDebugUrl $script:MaE2eMailAgentDebugUrl
    }
    $agentLog = Get-MailAgentDebugLogPathEvidence -BaseUrl $MailAgentDebugBaseUrl
    if ($agentLog) { [void]$script:EvidencePaths.Add($agentLog) }
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    try {
        Set-MailAgentDebugOverload -Mode off -BaseUrl $MailAgentDebugBaseUrl
    }
    catch {
        Write-Warning "overload off cleanup: $($_.Exception.Message)"
    }

    if ($script:PolicyStackPushed -and $script:CoreDebugHookUrl) {
        try {
            Write-Ma03Step 'MA-03: poppolicystate'
            Restore-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($null -ne $lab -and $lab.AttachFolder -and (Test-Path -LiteralPath $lab.AttachFolder)) {
        Remove-Item -LiteralPath $lab.AttachFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($simpleMailStartedByScript -and $simpleMailProcess -and -not $simpleMailProcess.HasExited) {
        Stop-Process -Id $simpleMailProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($mailAgentStartedByScript -and $mailAgentProcess -and -not $mailAgentProcess.HasExited) {
        Stop-Process -Id $mailAgentProcess.Id -Force -ErrorAction SilentlyContinue
    }

    try {
        Complete-MailAgentE2eTest -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
            -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $startedAtUtc `
            -EvidencePathsOnFailure @($script:EvidencePaths) -RunLogPath $runLogPath
    }
    finally {
        Stop-MailAgentE2eRunLog
    }

    if (-not $script:ScenarioPassed) {
        exit 1
    }
}

exit 0