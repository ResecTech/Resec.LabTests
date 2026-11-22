#Requires -Version 5.1
<#
.SYNOPSIS
  MA-02 C / NCP-7307: After Core comm outage during outbound staging, sanitized mail is delivered when Core returns.

.DESCRIPTION
  Runs two commdown hold durations (short ~10s and long ~30s) against the same lab setup.
  Each scenario: bulk inbound send, staging detection, commdown/commup, mail agent reconnect wait, delivery assert.

  Prerequisites:
    - Core with EnableDebugInterface=True; mail agent debug hook :4505 (script starts Resec.Agent.Mail when needed unless -SkipStartMailAgent).
    - Policy next hop on SimpleMailPort.
    - Optional -MailTempFolder / MAIL_E2E_TEMP_FOLDER; otherwise resolved from mail agent debug status (tempFolderRoot).

  Required fixtures and tools (local repo):
    Build SimpleMailServer (Resec.LabTests):
      dotnet build Tools\SimpleMailServer\SimpleMailServer.csproj -c Debug
    Build SendBulkAttachmentMail (Resec.Agent.Mail):
      dotnet build src\Resec.Agent.Mail.sln -c Debug -p:Platform=x64
    Or publish single-file (Rider/VS Publish).

    | Artifact | Purpose |
    | --- | --- |
    | Resec.LabTests\Tools\SimpleMailServer\bin\x64\Debug\...\SimpleMailServer.exe (or bin\publish\single-file\) | Outbound capture SMTP (--cli); started by this script unless -SkipStartSimpleMailServer |
    | SendBulkAttachmentMail\bin\Debug\...\SendBulkAttachmentMail.exe (or publish single-file) | Inbound bulk send to mail agent SMTP |
    | Mail\Config\simple-mail-server.appsettings.json | Headless SimpleMailServer config for mail E2E |
    | Fixtures\Mail\E2eAttach\ | Attachments for bulk send (e.g. clean-sample.txt, minimal-inbound.eml) |

    Tool paths (first match wins): -SimpleMailServerPath / -SendBulkAttachmentMailPath, then
    MAIL_E2E_SIMPLE_MAIL_SERVER_EXE / MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE, then repo build outputs and PATH.
    Dot-source Resec.LabTests\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1 to discover tools and set those variables.
    Set MAILAGENT_TEST_FILES_ROOT for fixture overrides.
    See Resec.LabTests\Mail\Common\README.md for lab setup (Core/mail agent debug, Test Platform env).

.NOTES
  Exit 0 = all selected scenarios passed; Exit 1 = any failed.
#>
[CmdletBinding()]
param(
    [string] $MailTempFolder = '',
    [string] $CoreDebugBaseUrl = '',
    [string] $MailAgentDebugBaseUrl = '',
    [int] $SimpleMailPort = 26,
    [double] $ResponseDelaySeconds = 5,
    [int] $ShortCommDownHoldSeconds = 10,
    [int] $LongCommDownHoldSeconds = 30,
    [ValidateSet('All', 'Short', 'Long')]
    [string] $Scenarios = 'All',
    [int] $StagingTimeoutSec = 120,
    [int] $ShortReconnectTimeoutSec = 45,
    [int] $LongReconnectTimeoutSec = 90,
    [int] $DeliveryTimeoutSec = 180,
    [int] $SanitizationOutputEmptyTimeoutSec = 20,
    [string] $InboundSmtpServer = '127.0.0.1',
    [int] $InboundSmtpPort = 25,
    [string] $MailTo = 'recipient@example.com',
    [string] $MailFrom = 'sender@example.com',
    [string] $SimpleMailServerPath = '',
    [string] $SendBulkAttachmentMailPath = '',
    [string] $CaptureSaveFolder = '',
    [string] $SimpleMailListenHost = '127.0.0.1',
    [int] $SimpleMailStartupTimeoutSec = 20,
    [switch] $SkipStartSimpleMailServer,
    [string] $MailAgentExePath = '',
    [int] $MailAgentStartupTimeoutSec = 90,
    [switch] $SkipStartMailAgent,
    [switch] $SkipCorePolicySetup,
    [string] $MailRelayName = '',
    [string] $CoreDebugHookUrl = '',
    [switch] $SkipRestoreCorePolicy,
    [switch] $SkipScenarioProcessTeardown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-MailDeployRequirements
}

$script:MaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eCorePolicy.ps1')

Assert-MailAgentE2eBulkPrerequisites -CallingScriptRoot $PSScriptRoot `
    -SimpleMailServerPathOverride $SimpleMailServerPath `
    -SendBulkAttachmentMailPathOverride $SendBulkAttachmentMailPath

$script:OverallPassed = $true
$simpleMailProcess = $null
$simpleMailStartedByScript = $false
$mailAgentProcess = $null
$mailAgentStartedByScript = $false
$script:PolicyStackPushed = $false
$script:CoreDebugHookUrl = $null

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Get-EffectiveMailTempFolder {
    param([string] $MailAgentDebugUrl = '')

    return Resolve-MailAgentE2eTempFolder -OverridePath $MailTempFolder -MailAgentDebugUrl $MailAgentDebugUrl
}

function Get-SanitizationOutputFolder {
    param([string] $TempRoot)
    return Get-MailAgentE2eSanitizationOutputFolder -TempRoot $TempRoot
}

function Invoke-Ma01ReconnectScenario {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Scenario,
        [Parameter(Mandatory)]
        [string] $StagingFolder,
        [Parameter(Mandatory)]
        [string] $AttachFolder,
        [Parameter(Mandatory)]
        [string] $BulkExe,
        [Parameter(Mandatory)]
        [string] $StatusFilePath,
        [Parameter(Mandatory)]
        [string] $CaptureFolder
    )

    $scenarioPassed = $false
    $scenarioFailureMessage = $null
    $evidencePaths = New-Object System.Collections.Generic.List[string]
    $bulkConfigPath = $null
    $startedAtUtc = [DateTimeOffset]::UtcNow
    $runLogPath = Start-MailAgentE2eRunLog -TestId $Scenario.TestId

    try {
        Write-TestStep "===== $($Scenario.Label) (commdown hold $($Scenario.CommDownHoldSeconds)s) ====="

        Write-TestStep 'Ensuring Core comm is up and mail agent is operationally ready.'
        Set-MailAgentCoreAgentCommUp -BaseUrl $CoreDebugBaseUrl | Out-Null
        $ready = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort
        Write-TestStep ("Mail agent: {0}" -f (Format-MailAgentDebugStatusSummary -Status $ready))

        Clear-CaptureFolder -Folder $CaptureFolder
        $captureStatusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $StatusFilePath).MessageCount
        $captureFileBaseline = Get-CaptureFolderFileSnapshot -Folder $CaptureFolder

        $subjectPrefix = Get-Date -Format 'yyyyMMddHHmmss'
        $expectedSubject = '{0}-1' -f $subjectPrefix
        $bulkSendTimeoutSec = [Math]::Max(90, $Scenario.CommDownHoldSeconds + 90)
        Write-TestStep "Sending inbound message (SMTP send timeout ${bulkSendTimeoutSec}s)."
        $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $AttachFolder `
            -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort -From $MailFrom -To $MailTo `
            -SendTimeoutSeconds $bulkSendTimeoutSec -SubjectPrefix $subjectPrefix
        $stagingSnapshot = Get-SanitizationStagingFileSnapshot -OutputFolder $StagingFolder
        $bulkJob = Start-BulkSendOnce -ExePath $BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $subjectPrefix
        Write-TestStep "Bulk send started (PID $($bulkJob.Process.Id)); expect subject: $expectedSubject"

        Write-TestStep "Waiting for staging under $StagingFolder."
        $stagingFile = Wait-ForSanitizationStagingWhileProcessRunning `
            -OutputFolder $StagingFolder -BulkProcess $bulkJob.Process -ExcludePaths $stagingSnapshot -TimeoutSec $StagingTimeoutSec
        if ([string]::IsNullOrWhiteSpace($stagingFile)) {
            if ($bulkJob.Process.HasExited) {
                throw 'Outbound staging never observed before SendBulkAttachmentMail exited (commdown must run while inbound session is open).'
            }
            throw "No outbound staging file within ${StagingTimeoutSec}s."
        }
        Write-TestStep "Staging file: $stagingFile"

        Write-TestStep 'Core commdown.'
        $down = Set-MailAgentCoreAgentCommDown -BaseUrl $CoreDebugBaseUrl
        Write-TestStep ("commdown: droppedSessions={0} admissionBlocked={1}" -f $down.droppedSessions, $down.agentCommAdmissionBlocked)
        $afterDown = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $MailAgentDebugBaseUrl
        Write-TestStep ("After commdown: {0}" -f (Format-MailAgentDebugStatusSummary -Status $afterDown))

        $holdSec = $Scenario.CommDownHoldSeconds
        Write-TestStep "Holding commdown for ${holdSec}s."
        Start-Sleep -Seconds $holdSec

        Write-TestStep 'Core commup.'
        Set-MailAgentCoreAgentCommUp -BaseUrl $CoreDebugBaseUrl | Out-Null

        $reconnectSec = $Scenario.ReconnectTimeoutSec
        Write-TestStep "Waiting for mail agent reconnect (up to ${reconnectSec}s)."
        $reconnected = Wait-MailAgentDebugReconnect -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort `
            -TimeoutSec $reconnectSec
        Write-TestStep ("Reconnected: {0}" -f (Format-MailAgentDebugStatusSummary -Status $reconnected))

        Write-TestStep 'Waiting for SendBulkAttachmentMail to finish.'
        $bulkReport = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec -AllowExpectedCommdown451 `
            -ProgressLabel $Scenario.TestId -MailAgentDebugUrl $MailAgentDebugBaseUrl -ProgressIntervalSec 5 `
            -E2eTestId $Scenario.TestId -CoreDebugHookUrl $script:CoreDebugHookUrl -EmitLogMarks
        $bulkFailureDetail = $null
        if ($null -ne $bulkReport -and $null -ne $bulkReport.failedMessages -and @($bulkReport.failedMessages).Count -gt 0) {
            $bulkFailureDetail = [string]@($bulkReport.failedMessages)[0].detail
        }
        Assert-MailAgentE2eCommdownInbound451Observed -BulkJob $bulkJob -FailureDetail $bulkFailureDetail `
            -Context "[$($Scenario.TestId)] MA-02 C inbound 451 during commdown" -MailAgentDebugUrl $MailAgentDebugBaseUrl
        if ($null -ne $bulkReport -and -not [string]::IsNullOrWhiteSpace([string]$bulkReport.subjectPrefix)) {
            $expectedSubject = '{0}-1' -f [string]$bulkReport.subjectPrefix
        }

        $deliveryWaitSec = [Math]::Max($DeliveryTimeoutSec, [int][Math]::Ceiling($ResponseDelaySeconds + $Scenario.CommDownHoldSeconds + 45))
        Write-TestStep "Waiting for outbound at SimpleMailServer (up to ${deliveryWaitSec}s, expect subject $expectedSubject)."
        $capture = Wait-ForCapturedSubject -StatusPath $StatusFilePath -ExpectedSubject $expectedSubject `
            -TimeoutSec $deliveryWaitSec -MinMessageCount $captureStatusBaseline `
            -CaptureFolder $CaptureFolder -ExcludeCaptureFiles $captureFileBaseline
        $resolvedSubject = if ($capture.resolvedSubject) { [string]$capture.resolvedSubject } else { [string]$capture.lastSubject }
        Write-TestStep ("Captured subject={0}" -f $resolvedSubject)

        Write-TestStep "Asserting SanitizationOutput is empty (no orphaned outbound staging after delivery)."
        Wait-MailAgentDebugSanitizationOutputEmpty -BaseUrl $MailAgentDebugBaseUrl `
            -TimeoutSec $SanitizationOutputEmptyTimeoutSec `
            -Context "[$($Scenario.TestId)] SanitizationOutput must be empty after successful outbound delivery" | Out-Null

        $repaired = Repair-MailAgentE2eOrphanInboundTempWhenIdle -BaseUrl $MailAgentDebugBaseUrl `
            -Context "[$($Scenario.TestId)] after delivery"
        $idleWaitSec = if ($repaired) { 30 } else { 60 }
        Write-TestStep "MA-02 C: idle temp folder check (plan step C; up to ${idleWaitSec}s)."
        $null = Wait-MailAgentE2eIdleTempFolders -BaseUrl $MailAgentDebugBaseUrl -TimeoutSec $idleWaitSec `
            -Context "[$($Scenario.TestId)] MA-02 C after delivery"

        $scenarioPassed = $true
    }
    catch {
        $scenarioFailureMessage = $_.Exception.Message
        $script:OverallPassed = $false
        if ($StatusFilePath) { $evidencePaths.Add($StatusFilePath) }
        if ($StagingFolder -and (Test-Path -LiteralPath $StagingFolder)) { $evidencePaths.Add($StagingFolder) }
        $agentLog = Get-MailAgentDebugLogPathEvidence -BaseUrl $MailAgentDebugBaseUrl
        if ($agentLog) { $evidencePaths.Add($agentLog) }
        try {
            $failStatus = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $MailAgentDebugBaseUrl
            Write-Host "[ERROR] [$($Scenario.TestId)] Mail agent: $(Format-MailAgentDebugStatusSummary -Status $failStatus)"
        }
        catch {
        }
        Write-Host "[ERROR] [$($Scenario.TestId)] $($_.Exception.Message)"
    }
    finally {
        if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
            Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
        }

        try {
            Complete-MailAgentE2eTest -TestId $Scenario.TestId `
                -TestTitle $Scenario.TestTitle `
                -Passed:$scenarioPassed `
                -FailureMessage $scenarioFailureMessage `
                -StartedAtUtc $startedAtUtc `
                -EvidencePathsOnFailure @($evidencePaths) `
                -RunLogPath $runLogPath
        }
        finally {
            Stop-MailAgentE2eRunLog
        }
    }

    return $scenarioPassed
}

$scenarioDefinitions = @(
    @{
        Key = 'Short'
        TestId = 'MA-02-C-Short'
        TestTitle = 'MA-02 C NCP-7307 short disconnect (10s) outbound delivery'
        Label = 'Short disconnect / reconnect'
        CommDownHoldSeconds = $ShortCommDownHoldSeconds
        ReconnectTimeoutSec = $ShortReconnectTimeoutSec
    },
    @{
        Key = 'Long'
        TestId = 'MA-02-C-Long'
        TestTitle = 'MA-02 C NCP-7307 long disconnect (30s+) outbound delivery'
        Label = 'Long disconnect / reconnect'
        CommDownHoldSeconds = $LongCommDownHoldSeconds
        ReconnectTimeoutSec = $LongReconnectTimeoutSec
    }
)

$selectedScenarios = switch ($Scenarios) {
    'Short' { @($scenarioDefinitions | Where-Object { $_.Key -eq 'Short' }) }
    'Long' { @($scenarioDefinitions | Where-Object { $_.Key -eq 'Long' }) }
    default { $scenarioDefinitions }
}

try {
    $MailAgentDebugBaseUrl = Get-MailAgentDebugBaseUrl -Override $MailAgentDebugBaseUrl
    $CoreDebugBaseUrl = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl

    $testFilesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $PSScriptRoot
    $attachFolder = Get-MailAgentE2eAttachmentFolder -TestFilesRoot $testFilesRoot

    $smsExe = Resolve-SimpleMailServerPath -CallingScriptRoot $PSScriptRoot -Path $SimpleMailServerPath
    $bulkExe = Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $PSScriptRoot -Path $SendBulkAttachmentMailPath

    if ([string]::IsNullOrWhiteSpace($CaptureSaveFolder)) {
        $CaptureSaveFolder = Join-Path $env:TEMP 'MailE2e-CapturedOutbound'
    }
    $CaptureSaveFolder = [System.IO.Path]::GetFullPath($CaptureSaveFolder)
    $statusFilePath = Join-Path $CaptureSaveFolder 'simple-mail-server-status.json'

    $smsConfig = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\simple-mail-server.appsettings.json'
    if (-not (Test-Path -LiteralPath $smsConfig)) {
        throw "SimpleMailServer config not found: $smsConfig"
    }

    Write-TestStep 'Waiting for Core readiness (debug ready).'
    Wait-MailAgentCoreReady -BaseUrl $CoreDebugBaseUrl | Out-Null

    $script:CoreDebugHookUrl = Get-MailAgentE2eCoreDebugHookUrl -BaseUrl $CoreDebugBaseUrl -Override $CoreDebugHookUrl
    if (-not $SkipCorePolicySetup) {
        $policyTempFolder = Get-MailAgentE2eDefaultLabTempFolder -Override $MailTempFolder
        Write-TestStep ("Core: install mail lab policy (next hop 127.0.0.1:$SimpleMailPort).")
        Install-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl -RelayName $MailRelayName `
            -NextHopPort $SimpleMailPort -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder
        $script:PolicyStackPushed = $true
    }

    Write-TestStep 'Ensuring mail agent is running (debug hook).'
    $mailEnsure = Ensure-MailAgentE2eProcessRunning -CallingScriptRoot $PSScriptRoot `
        -BaseUrl $MailAgentDebugBaseUrl -MailAgentExePath $MailAgentExePath `
        -ExpectedInboundPort $InboundSmtpPort -StartupTimeoutSec $MailAgentStartupTimeoutSec `
        -SkipStart:$SkipStartMailAgent
    $mailAgentProcess = $mailEnsure.Process
    $mailAgentStartedByScript = [bool]$mailEnsure.StartedByScript

    Write-TestStep 'Waiting for mail agent debug readiness.'
    $agentStatus = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort
    Write-TestStep ("Mail agent: {0}" -f (Format-MailAgentDebugStatusSummary -Status $agentStatus))
    Initialize-MailAgentE2eComponentVersionFromDebug -BaseUrl $MailAgentDebugBaseUrl

    if ($script:PolicyStackPushed) {
        Write-TestStep 'Core: wait for lab policy on mail agent (agentcomm nudge only if first connect stalls).'
        Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $MailAgentDebugBaseUrl -HookUrl $script:CoreDebugHookUrl -TestId 'MA-02-C'
        $agentStatus = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort
        Write-TestStep ("Mail agent after policy apply: {0}" -f (Format-MailAgentDebugStatusSummary -Status $agentStatus))
        Assert-MailAgentE2ePolicyFromAgentLog -BaseUrl $MailAgentDebugBaseUrl -NextHopHost $SimpleMailListenHost -NextHopPort $SimpleMailPort
    }

    $tempRoot = Get-EffectiveMailTempFolder -MailAgentDebugUrl $MailAgentDebugBaseUrl
    $stagingFolder = Get-SanitizationOutputFolder -TempRoot $tempRoot
    Write-TestStep "Mail agent temp root: $tempRoot"

    Write-TestStep "Starting SimpleMailServer on ${SimpleMailListenHost}:$SimpleMailPort (delay ${ResponseDelaySeconds}s)."
    $smsEnsure = Ensure-MailAgentE2eSimpleMailServerHeadless `
        -SimpleMailServerExe $smsExe `
        -ConfigPath $smsConfig `
        -Port $SimpleMailPort `
        -ResponseDelaySeconds $ResponseDelaySeconds `
        -SaveFolder $CaptureSaveFolder `
        -StatusFilePath $statusFilePath `
        -ListenHost $SimpleMailListenHost `
        -StartupTimeoutSec $SimpleMailStartupTimeoutSec `
        -SkipStart:$SkipStartSimpleMailServer `
        -WipeSaveFolder
    $simpleMailProcess = $smsEnsure.Process
    $simpleMailStartedByScript = [bool]$smsEnsure.StartedByScript

    Assert-MailAgentE2eSimpleMailServerListening `
        -ListenHost $SimpleMailListenHost `
        -Port $SimpleMailPort `
        -SimpleMailServerExe $smsExe `
        -ConfigPath $smsConfig `
        -SaveFolder $CaptureSaveFolder `
        -ResponseDelaySeconds $ResponseDelaySeconds `
        -StatusFilePath $statusFilePath

    $scenarioIndex = 0
    foreach ($scenario in $selectedScenarios) {
        if ($scenarioIndex -gt 0) {
            Write-TestStep 'Brief pause before next scenario (inbound/outbound settle).'
            Start-Sleep -Seconds 2
        }
        Invoke-Ma01ReconnectScenario -Scenario $scenario -StagingFolder $stagingFolder `
            -AttachFolder $attachFolder -BulkExe $bulkExe -StatusFilePath $statusFilePath `
            -CaptureFolder $CaptureSaveFolder | Out-Null
        $scenarioIndex++
    }

    Write-TestStep "MA-02 C post-run: listen port check ($InboundSmtpServer`:$InboundSmtpPort)."
    Assert-MailAgentE2eInboundSmtpPortListening -ComputerName $InboundSmtpServer -Port $InboundSmtpPort `
        -BaseUrl $MailAgentDebugBaseUrl -Context 'MA-02 C after scenarios'
    Write-TestStep 'MA-02 C post-run: idle temp folder check (SanitizationInput/Output/SmtpInboundSpool/SmtpFailed = 0).'
    Assert-MailAgentE2eIdleTempFolders -BaseUrl $MailAgentDebugBaseUrl -Context 'MA-02 C after scenarios'
}
catch {
    $script:OverallPassed = $false
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    if ($script:PolicyStackPushed -and $script:CoreDebugHookUrl -and -not $SkipRestoreCorePolicy) {
        try {
            Write-TestStep 'Core: poppolicystate'
            Restore-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if (-not $SkipScenarioProcessTeardown -and $simpleMailStartedByScript -and $simpleMailProcess -and -not $simpleMailProcess.HasExited) {
        try {
            Stop-Process -Id $simpleMailProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    if (-not $SkipScenarioProcessTeardown -and $mailAgentStartedByScript -and $mailAgentProcess -and -not $mailAgentProcess.HasExited) {
        try {
            Write-TestStep "Stopping mail agent started by MA-02-C (pid=$($mailAgentProcess.Id))."
            Stop-Process -Id $mailAgentProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    if (-not $script:OverallPassed) {
        exit 1
    }
}
