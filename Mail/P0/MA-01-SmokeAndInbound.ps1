#Requires -Version 5.1
<#
.SYNOPSIS
  MA-01: Mail Agent smoke and inbound (minimal functional test plan P0 #1).

.DESCRIPTION
  Automates MA-01 substeps A–E and F1 (Core commdown ~10s during inbound). Optional:
  -IncludeMa02CLongCommdown runs MA-02-C-NCP7307 long reconnect scenario.
  Steps F2, F3, G, H are manual-only unless explicitly enabled (default: SKIP log).

  Prerequisites match Mail/Common/README.md (same base tools as MA-02-C):
    Core debug (4504), mail agent debug (4505), SendBulkAttachmentMail + SimpleMailServer built.
    Script installs lab Core policy (Send Immediate Response off, next hop :26, mail_agent) unless -SkipCorePolicySetup.
    SendEml.exe only for step E (or -SkipStepE).

.NOTES
  Exit 0 = passed; Exit 1 = failed.
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
    [string] $MailTo = 'recipient@example.com',
    [string] $MailFrom = 'sender@example.com',
    [string] $SimpleMailServerPath = '',
    [string] $SendBulkAttachmentMailPath = '',
    [string] $SendEmlPath = '',
    [string] $CaptureSaveFolder = '',
    [string] $SimpleMailListenHost = '127.0.0.1',
    [int] $SimpleMailStartupTimeoutSec = 20,
    [int] $DeliveryTimeoutSec = 120,
    [int] $ProgressIntervalSec = 5,
    [int] $InboundStallFailTimeoutSec = 75,
    [int] $F1CommDownHoldSeconds = 10,
    [int] $F1StagingTimeoutSec = 120,
    [switch] $SkipCorePolicySetup,
    [string] $MailRelayName = '',
    [string] $CoreDebugHookUrl = '',
    [switch] $ConfirmSirOffForStepB,
    [switch] $SkipWmcCheck,
    [string] $WmcUser = '',
    [string] $WmcPassword = '',
    [switch] $SkipStartSimpleMailServer,
    [string] $MailAgentExePath = '',
    [int] $MailAgentStartupTimeoutSec = 90,
    [switch] $SkipStartMailAgent,
    [switch] $IncludeMa02CLongCommdown,
    [switch] $RunStepF2,
    [switch] $RunStepF3,
    [switch] $RunStepG,
    [switch] $RunStepH,
    [switch] $SkipStepA,
    [switch] $SkipStepB,
    [switch] $SkipStepC,
    [switch] $SkipStepD,
    [switch] $SkipStepE,
    [switch] $SkipStepF1,
    [switch] $FailOnRunningScanAgent
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

Assert-MailAgentE2eBulkPrerequisites -CallingScriptRoot $PSScriptRoot `
    -SimpleMailServerPathOverride $SimpleMailServerPath `
    -SendBulkAttachmentMailPathOverride $SendBulkAttachmentMailPath

$script:TestId = 'MA-01'
$script:TestTitle = 'MA-01 smoke and inbound (minimal functional test plan)'
$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:EvidencePaths = New-Object System.Collections.Generic.List[string]

$simpleMailProcess = $null
$simpleMailStartedByScript = $false
$mailAgentProcess = $null
$mailAgentStartedByScript = $false
$stagingFoldersToRemove = New-Object System.Collections.Generic.List[string]
$script:PolicyStackPushed = $false
$script:CoreDebugHookUrl = $null
$script:MaE2eEmitLogMarks = $true
$script:MaE2eMailAgentDebugUrl = $null

function Write-TestStep {
    param([string] $Message)
    Write-Host ("[{0}] [STEP] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    if ($script:MaE2eEmitLogMarks -and -not [string]::IsNullOrWhiteSpace($script:CoreDebugHookUrl)) {
        Write-MailAgentE2eCorrelationLogMark -TestId $script:TestId -Mark $Message `
            -CoreDebugHookUrl $script:CoreDebugHookUrl -MailAgentDebugUrl $script:MaE2eMailAgentDebugUrl
    }
}

function Get-CoreRestBaseUrlEffective {
    if (-not [string]::IsNullOrWhiteSpace($CoreRestBaseUrl)) {
        return $CoreRestBaseUrl.TrimEnd('/')
    }
    $debug = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    if ($debug -like 'https://*') {
        return $debug.TrimEnd('/')
    }
    if ($debug -like 'http://*') {
        return $debug.TrimEnd('/')
    }
    return 'https://localhost:4504'
}

function Invoke-Ma01StepA {
    param(
        [string] $MailAgentDebugUrl,
        [int] $InboundPort
    )

    Write-TestStep 'MA-01 A  - agent smoke (debug status + SMTP listen port).'
    $status = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugUrl -ExpectedInboundPort $InboundPort
    Write-TestStep ("Agent ready: {0}" -f (Format-MailAgentDebugStatusSummary -Status $status))

    $tn = Test-NetConnection -ComputerName $InboundSmtpServer -Port $InboundPort -WarningAction SilentlyContinue
    if ($tn.TcpTestSucceeded -ne $true) {
        throw "MA-01 A failed: inbound SMTP port $InboundSmtpServer`:$InboundPort is not listening."
    }
    Write-TestStep "Test-NetConnection OK for $InboundSmtpServer`:$InboundPort."

    $logPath = Get-MailAgentDebugLogPathEvidence -BaseUrl $MailAgentDebugUrl
    if ($logPath) {
        $tail = @(Get-Content -LiteralPath $logPath -Tail 300 -ErrorAction SilentlyContinue)
        $applyCount = @($tail | Where-Object { $_ -match 'Email agent configuration applied from Resec Core policy' }).Count
        if ($applyCount -gt 8) {
            throw "MA-01 A: policy apply spam suspected ($applyCount configuration-applied lines in last 300 log lines)."
        }
        Write-TestStep "Log policy-apply lines in tail (300): $applyCount."
        $script:EvidencePaths.Add($logPath) | Out-Null
    }
    else {
        Write-TestStep 'MA-01 A: logpath not available (skipped policy-apply log check).'
    }
}

function Send-InboundBulkAndWaitCapture {
    param(
        [Parameter(Mandatory)][string] $AttachmentFolder,
        [Parameter(Mandatory)][string] $BulkExe,
        [Parameter(Mandatory)][string] $StatusFilePath,
        [Parameter(Mandatory)][string] $CaptureFolder,
        [string] $To,
        [string] $From,
        [string] $SubjectPrefix,
        [int] $MinAttach = 1,
        [int] $MaxAttach = 2,
        [hashtable] $CaptureFileBaseline,
        [int] $CaptureStatusBaseline,
        [string] $StepLabel,
        [string] $MailAgentDebugUrl = ''
    )

    $bulkConfigPath = $null
    try {
        $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $AttachmentFolder `
            -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort -From $From -To $To `
            -SendTimeoutSeconds $DeliveryTimeoutSec -SubjectPrefix $SubjectPrefix `
            -MinAttachmentsPerEmail $MinAttach -MaxAttachmentsPerEmail $MaxAttach
        Write-TestStep "$StepLabel  - bulk send started (Send Immediate Response off: SMTP session open until Core delivers to next hop; usual lab time under 60s)."
        $bulkJob = Start-BulkSendOnce -ExePath $BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $SubjectPrefix
        $report = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec `
            -ProgressLabel $StepLabel -MailAgentDebugUrl $MailAgentDebugUrl `
            -ProgressIntervalSec $ProgressIntervalSec -InboundStallFailTimeoutSec $InboundStallFailTimeoutSec `
            -EmitLogMarks -E2eTestId $script:TestId -CoreDebugHookUrl $script:CoreDebugHookUrl
        $expectedSubject = '{0}-1' -f [string]$report.subjectPrefix
        Write-TestStep "$StepLabel  - bulk send OK; expect capture subject *$expectedSubject*."
        $capture = Wait-ForCapturedSubject -StatusPath $StatusFilePath -ExpectedSubject $expectedSubject `
            -TimeoutSec $DeliveryTimeoutSec -MinMessageCount $CaptureStatusBaseline `
            -CaptureFolder $CaptureFolder -ExcludeCaptureFiles $CaptureFileBaseline
        return @{
            ExpectedSubject = $expectedSubject
            Capture         = $capture
        }
    }
    finally {
        if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
            Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Ma01StepB {
    param(
        [hashtable] $Lab,
        [string] $WmcToken,
        [string] $CoreRestUrl
    )

    if ($ConfirmSirOffForStepB) {
        Write-TestStep 'MA-01 B: -ConfirmSirOffForStepB is deprecated (lab policy sets Send Immediate Response off automatically).'
    }

    Write-TestStep 'MA-01 B  - clean inbound with attachments (Send Immediate Response off).'
    $fixturesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $PSScriptRoot
    $cleanSample = Join-Path (Get-MailAgentE2eAttachmentFolder -TestFilesRoot $fixturesRoot) 'clean-sample.txt'
    $docx = Join-Path (Get-LabFixturesRoot) 'Office\NCP-7344\simple.docx'
    if (-not (Test-Path -LiteralPath $docx)) {
        throw "MA-01 B: missing fixture $docx"
    }

    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($cleanSample, $docx)
    [void]$stagingFoldersToRemove.Add($attachFolder)

    Clear-CaptureFolder -Folder $Lab.CaptureFolder
    $captureBaseline = Get-CaptureFolderFileSnapshot -Folder $Lab.CaptureFolder
    $statusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $subjectPrefix = 'MA01-B-' + (Get-Date -Format 'yyyyMMddHHmmss')

    $send = Send-InboundBulkAndWaitCapture -AttachmentFolder $attachFolder -BulkExe $Lab.BulkExe `
        -StatusFilePath $Lab.StatusFilePath -CaptureFolder $Lab.CaptureFolder -To $MailTo -From $MailFrom `
        -SubjectPrefix $subjectPrefix -CaptureFileBaseline $captureBaseline -CaptureStatusBaseline $statusBaseline `
        -StepLabel 'MA-01 B' -MailAgentDebugUrl $Lab.MailAgentDebugUrl

    $emlPath = [string]$send.Capture.resolvedSavedFilePath
    if ([string]::IsNullOrWhiteSpace($emlPath)) {
        $emlPath = [string]$send.Capture.lastSavedFilePath
    }
    if (-not [string]::IsNullOrWhiteSpace($emlPath) -and -not (Test-CapturedEmlContainsResecSignature -EmlPath $emlPath)) {
        throw "MA-01 B: captured message at '$emlPath' does not contain ReSecure/Resec signature marker."
    }
    Write-TestStep 'MA-01 B: capture contains Resec processing marker.'

    if (-not $SkipWmcCheck -and -not [string]::IsNullOrWhiteSpace($WmcToken)) {
        Write-TestStep "MA-01 B: WMC wait for Pass (subject *$($send.ExpectedSubject)*, up to 120s)."
        $row = Wait-CoreE2eWmcEmailSanitizationBySubject -BaseUrl $CoreRestUrl -ApiToken $WmcToken `
            -SubjectContains $send.ExpectedSubject -MailTo @($MailTo) -TimeoutSec 120
        $outcome = [string](Get-CoreE2eWmcRestPropertyValue -Object $row -Names @('outcome', 'Outcome'))
        Write-TestStep "MA-01 B: WMC outcome=$outcome for subject $($send.ExpectedSubject)."
    }
    elseif ($SkipWmcCheck) {
        Write-TestStep 'MA-01 B: WMC check skipped (-SkipWmcCheck).'
    }

    Assert-MailAgentE2eIdleTempFolders -BaseUrl $Lab.MailAgentDebugUrl -Context 'MA-01 B after delivery'
    Wait-MailAgentDebugSanitizationOutputEmpty -BaseUrl $Lab.MailAgentDebugUrl -TimeoutSec 30 | Out-Null
}

function Invoke-Ma01StepC {
    param([hashtable] $Lab)

    Write-TestStep 'MA-01 C  - multi-recipient (comma-separated To).'
    $fixturesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $PSScriptRoot
    $cleanSample = Join-Path (Get-MailAgentE2eAttachmentFolder -TestFilesRoot $fixturesRoot) 'clean-sample.txt'
    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($cleanSample)
    [void]$stagingFoldersToRemove.Add($attachFolder)

    $toList = '{0},{1}' -f $MailTo, ('cc-' + $MailTo)
    $captureBaseline = Get-CaptureFolderFileSnapshot -Folder $Lab.CaptureFolder
    $statusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $subjectPrefix = 'MA01-C-' + (Get-Date -Format 'yyyyMMddHHmmss')

    $send = Send-InboundBulkAndWaitCapture -AttachmentFolder $attachFolder -BulkExe $Lab.BulkExe `
        -StatusFilePath $Lab.StatusFilePath -CaptureFolder $Lab.CaptureFolder -To $toList -From $MailFrom `
        -SubjectPrefix $subjectPrefix -MinAttach 1 -MaxAttach 1 `
        -CaptureFileBaseline $captureBaseline -CaptureStatusBaseline $statusBaseline -StepLabel 'MA-01 C' `
        -MailAgentDebugUrl $Lab.MailAgentDebugUrl

    $emlPath = [string]$send.Capture.resolvedSavedFilePath
    if ([string]::IsNullOrWhiteSpace($emlPath)) {
        $emlPath = [string]$send.Capture.lastSavedFilePath
    }
    if ([string]::IsNullOrWhiteSpace($emlPath) -or -not (Test-Path -LiteralPath $emlPath)) {
        throw 'MA-01 C: no captured .eml to verify recipients.'
    }
    $emlText = [System.IO.File]::ReadAllText($emlPath)
    foreach ($addr in @($MailTo, 'cc-' + $MailTo)) {
        if ($emlText -notmatch [Regex]::Escape($addr)) {
            throw "MA-01 C: capture does not include recipient '$addr'."
        }
    }
    Write-TestStep 'MA-01 C: capture lists both recipients.'
}

function Invoke-Ma01StepD {
    param([hashtable] $Lab)

    Write-TestStep 'MA-01 D  - disallowed attachment (Scripts/Executables=False) expects SMTP 5xx.'
    $blockedVbs = Join-Path (Get-LabFixturesRoot) 'Blocked\FileTypeNotAllowed\vbs_Windows XP Theme Changer.vbs'
    if (-not (Test-Path -LiteralPath $blockedVbs)) {
        throw "MA-01 D: missing $blockedVbs"
    }
    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($blockedVbs)
    [void]$stagingFoldersToRemove.Add($attachFolder)

    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $attachFolder `
        -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort -From $MailFrom -To $MailTo `
        -SendTimeoutSeconds 90 -SubjectPrefix ('MA01-D-' + (Get-Date -Format 'yyyyMMddHHmmss')) `
        -MinAttachmentsPerEmail 1 -MaxAttachmentsPerEmail 1
    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix ''
    $result = Complete-BulkSendExpectingFailure -BulkJob $bulkJob -RequireSmtp5xx
    Write-TestStep ("MA-01 D: inbound rejected (exit $($result.ExitCode)); 5xx observed.")

    if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
        Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
    }
}

function New-MailAgentE2eNullFromEml {
    param(
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $To,
        [Parameter(Mandatory)][string] $Subject
    )

    $lines = @(
        "To: $To",
        "Subject: $Subject",
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'MA-01 E null reverse-path probe.'
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($OutputPath, $lines, $utf8)
    return $OutputPath
}

function Invoke-Ma01StepE {
    param(
        [hashtable] $Lab,
        [string] $SendEmlExePath = ''
    )

    Write-TestStep 'MA-01 E  - empty / null MAIL FROM (SMTP dialog documented).'
    $sendEmlExe = Resolve-SendEmlPath -CallingScriptRoot $PSScriptRoot -Path $SendEmlExePath
    $emlNull = Join-Path $env:TEMP ('MA01-E-nullfrom-' + [Guid]::NewGuid().ToString('N') + '.eml')
    $null = New-MailAgentE2eNullFromEml -OutputPath $emlNull -To $MailTo -Subject ('MA01-E-null-' + (Get-Date -Format 'yyyyMMddHHmmss'))

    $results = New-Object System.Collections.Generic.List[string]
    foreach ($case in @(
            @{ Label = 'header-empty-envelope-default'; UseOverride = $false },
            @{ Label = 'MAIL-FROM-angle-brackets'; UseOverride = $true; Envelope = '<>' }
        )) {
        if ($case.UseOverride) {
            $send = Invoke-SendEmlToAgent -SendEmlExe $sendEmlExe -EmlPath $emlNull `
                -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort -EnvelopeFromOverride $case.Envelope
        }
        else {
            $send = Invoke-SendEmlToAgent -SendEmlExe $sendEmlExe -EmlPath $emlNull `
                -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort
        }
        $results.Add(("{0}: exit={1} output={2}" -f $case.Label, $send.ExitCode, ($send.Output -replace '\s+', ' ').Trim()))
        Write-TestStep ("MA-01 E [{0}] exit={1}" -f $case.Label, $send.ExitCode)
    }

    Write-TestStep ('MA-01 E summary: ' + ($results -join ' | '))
    Remove-Item -LiteralPath $emlNull -Force -ErrorAction SilentlyContinue
}

function Invoke-Ma01StepF1 {
    param([hashtable] $Lab)

    Write-TestStep "MA-01 F1  - Core commdown ~${F1CommDownHoldSeconds}s during inbound (expect 451)."
    Set-MailAgentCoreAgentCommUp -BaseUrl $Lab.CoreDebugUrl | Out-Null

    $fixturesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $PSScriptRoot
    $cleanSample = Join-Path (Get-MailAgentE2eAttachmentFolder -TestFilesRoot $fixturesRoot) 'clean-sample.txt'
    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($cleanSample)
    [void]$stagingFoldersToRemove.Add($attachFolder)

    $captureBaseline = Get-CaptureFolderFileSnapshot -Folder $Lab.CaptureFolder
    $statusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $subjectPrefix = 'MA01-F1-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $bulkSendTimeoutSec = [Math]::Max(90, $F1CommDownHoldSeconds + 90)

    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $attachFolder `
        -SmtpServer $InboundSmtpServer -SmtpPort $InboundSmtpPort -From $MailFrom -To $MailTo `
        -SendTimeoutSeconds $bulkSendTimeoutSec -SubjectPrefix $subjectPrefix `
        -MinAttachmentsPerEmail 1 -MaxAttachmentsPerEmail 1
    $stagingSnapshot = Get-SanitizationStagingFileSnapshot -OutputFolder $Lab.StagingFolder
    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $subjectPrefix

    $stagingFile = Wait-ForSanitizationStagingWhileProcessRunning -OutputFolder $Lab.StagingFolder `
        -BulkProcess $bulkJob.Process -ExcludePaths $stagingSnapshot -TimeoutSec $F1StagingTimeoutSec
    if ([string]::IsNullOrWhiteSpace($stagingFile)) {
        throw 'MA-01 F1: no staging file before commdown (open inbound session required).'
    }

    Set-MailAgentCoreAgentCommDown -BaseUrl $Lab.CoreDebugUrl | Out-Null
    Start-Sleep -Seconds $F1CommDownHoldSeconds
    Set-MailAgentCoreAgentCommUp -BaseUrl $Lab.CoreDebugUrl | Out-Null
    $null = Wait-MailAgentDebugReconnect -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $InboundSmtpPort -TimeoutSec 60

    $bulkReport = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec -AllowExpectedCommdown451 `
        -ProgressLabel 'MA-01 F1' -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
        -ProgressIntervalSec $ProgressIntervalSec -InboundStallFailTimeoutSec $InboundStallFailTimeoutSec
    $expectedSubject = '{0}-1' -f [string]$bulkReport.subjectPrefix
    $capture = Wait-ForCapturedSubject -StatusPath $Lab.StatusFilePath -ExpectedSubject $expectedSubject `
        -TimeoutSec $DeliveryTimeoutSec -MinMessageCount $statusBaseline `
        -CaptureFolder $Lab.CaptureFolder -ExcludeCaptureFiles $captureBaseline
    Write-TestStep "MA-01 F1: delivered after commdown; subject=$expectedSubject (SMTP 451 during commdown accepted when SendBulk reports it)."

    $null = Wait-MailAgentDebugSanitizationOutputEmpty -BaseUrl $Lab.MailAgentDebugUrl -TimeoutSec 60
    $repaired = Repair-MailAgentE2eOrphanInboundTempWhenIdle -BaseUrl $Lab.MailAgentDebugUrl -Context 'MA-01 F1 after delivery'
    $idleWaitSec = if ($repaired) { 30 } else { 60 }
    $null = Wait-MailAgentE2eIdleTempFolders -BaseUrl $Lab.MailAgentDebugUrl -TimeoutSec $idleWaitSec -Context 'MA-01 F1 after delivery'

    if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
        Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-Ma01ManualStepsSkipped {
    if ($RunStepF2 -or $RunStepF3 -or $RunStepG -or $RunStepH) {
        Write-TestStep 'Optional steps F2/F3/G/H requested but not automated in this script revision  - perform manually per test plan.'
        return
    }
    Write-TestStep 'SKIP MA-01 F2/F3/G/H (manual / lab prep)  - pass -RunStepF2 etc. when automation is added.'
}

$runLogPath = $null
$startedAtUtc = [DateTimeOffset]::UtcNow

try {
    $runLogPath = Start-MailAgentE2eRunLog -TestId $script:TestId

    $MailAgentDebugBaseUrl = Get-MailAgentDebugBaseUrl -Override $MailAgentDebugBaseUrl
    $script:MaE2eMailAgentDebugUrl = $MailAgentDebugBaseUrl
    $CoreDebugBaseUrl = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    $coreRestUrl = Get-CoreRestBaseUrlEffective

    $smsExe = Resolve-SimpleMailServerPath -CallingScriptRoot $PSScriptRoot -Path $SimpleMailServerPath
    $bulkExe = Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $PSScriptRoot -Path $SendBulkAttachmentMailPath
    if ([string]::IsNullOrWhiteSpace($CaptureSaveFolder)) {
        $CaptureSaveFolder = Join-Path $env:TEMP 'MailE2e-MA01-CapturedOutbound'
    }
    $CaptureSaveFolder = [System.IO.Path]::GetFullPath($CaptureSaveFolder)
    $statusFilePath = Join-Path $CaptureSaveFolder 'simple-mail-server-status.json'
    $smsConfig = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\simple-mail-server.appsettings.json'

    $script:CoreDebugHookUrl = Get-MailAgentE2eCoreDebugHookUrl -BaseUrl $CoreDebugBaseUrl -Override $CoreDebugHookUrl
    Write-TestStep 'Waiting for Core readiness.'
    Wait-MailAgentCoreReady -BaseUrl $CoreDebugBaseUrl | Out-Null
    if (-not $SkipCorePolicySetup) {
        $policyTempFolder = Get-MailAgentE2eDefaultLabTempFolder -Override $MailTempFolder
        Write-TestStep ("Core: install mail lab policy (Send Immediate Response off, next hop 127.0.0.1:$SimpleMailPort, relay $(Get-MailAgentE2eDefaultRelayName -Override $MailRelayName)).")
        Install-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl -RelayName $MailRelayName `
            -NextHopPort $SimpleMailPort -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder
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
    Initialize-MailAgentE2eComponentVersionFromDebug -BaseUrl $MailAgentDebugBaseUrl

    if ($script:PolicyStackPushed) {
        Write-TestStep 'Core: wait for lab policy on mail agent (agentcomm nudge only if first connect stalls).'
        Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $MailAgentDebugBaseUrl -HookUrl $script:CoreDebugHookUrl `
            -TestId $script:TestId
        $null = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort
        Assert-MailAgentE2ePolicyFromAgentLog -BaseUrl $MailAgentDebugBaseUrl -NextHopHost '127.0.0.1' -NextHopPort $SimpleMailPort
    }

    $scanAgentAssert = @{ RelayName = (Get-MailAgentE2eDefaultRelayName -Override $MailRelayName) }
    if ($FailOnRunningScanAgent) { $scanAgentAssert.FailOnScanAgent = $true }
    Assert-MailAgentE2eLabRelayEnvironment @scanAgentAssert

    $tempRoot = Resolve-MailAgentE2eTempFolder -OverridePath $MailTempFolder -MailAgentDebugUrl $MailAgentDebugBaseUrl
    $stagingFolder = Get-MailAgentE2eSanitizationOutputFolder -TempRoot $tempRoot

    $smsEnsure = Ensure-MailAgentE2eSimpleMailServerHeadless `
        -SimpleMailServerExe $smsExe -ConfigPath $smsConfig -Port $SimpleMailPort `
        -ResponseDelaySeconds $ResponseDelaySeconds -SaveFolder $CaptureSaveFolder `
        -StatusFilePath $statusFilePath -ListenHost $SimpleMailListenHost `
        -StartupTimeoutSec $SimpleMailStartupTimeoutSec -SkipStart:$SkipStartSimpleMailServer -WipeSaveFolder
    $simpleMailProcess = $smsEnsure.Process
    $simpleMailStartedByScript = [bool]$smsEnsure.StartedByScript

    Assert-MailAgentE2eSimpleMailServerListening -ListenHost $SimpleMailListenHost -Port $SimpleMailPort `
        -SimpleMailServerExe $smsExe -ConfigPath $smsConfig -SaveFolder $CaptureSaveFolder `
        -ResponseDelaySeconds $ResponseDelaySeconds -StatusFilePath $statusFilePath

    $wmcToken = $null
    if (-not $SkipWmcCheck) {
        Write-TestStep 'WMC login for step B Pass check.'
        $wmcToken = Connect-CoreE2eWmcRestSession -BaseUrl $coreRestUrl -User $WmcUser -Password $WmcPassword
    }

    $lab = @{
        BulkExe             = $bulkExe
        CaptureFolder       = $CaptureSaveFolder
        StatusFilePath      = $statusFilePath
        StagingFolder       = $stagingFolder
        MailAgentDebugUrl   = $MailAgentDebugBaseUrl
        CoreDebugUrl        = $CoreDebugBaseUrl
        CoreDebugHookUrl    = $script:CoreDebugHookUrl
    }

    if (-not $SkipStepA) { Invoke-Ma01StepA -MailAgentDebugUrl $MailAgentDebugBaseUrl -InboundPort $InboundSmtpPort }
    if (-not $SkipStepB) { Invoke-Ma01StepB -Lab $lab -WmcToken $wmcToken -CoreRestUrl $coreRestUrl }
    if (-not $SkipStepC) { Invoke-Ma01StepC -Lab $lab }
    if (-not $SkipStepD) { Invoke-Ma01StepD -Lab $lab }
    if (-not $SkipStepE) { Invoke-Ma01StepE -Lab $lab -SendEmlExePath $SendEmlPath }
    if (-not $SkipStepF1) { Invoke-Ma01StepF1 -Lab $lab }

    Write-Ma01ManualStepsSkipped

    if ($IncludeMa02CLongCommdown) {
        Write-TestStep 'Including MA-02 C long commdown via MA-02-C-NCP7307 (Long scenario only).'
        & (Join-Path $PSScriptRoot 'MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1') `
            -Scenarios Long -SkipStartSimpleMailServer:$SkipStartSimpleMailServer `
            -SkipStartMailAgent:$SkipStartMailAgent -MailTempFolder $MailTempFolder `
            -CoreDebugBaseUrl $CoreDebugBaseUrl -MailAgentDebugBaseUrl $MailAgentDebugBaseUrl `
            -SimpleMailServerPath $SimpleMailServerPath -SendBulkAttachmentMailPath $SendBulkAttachmentMailPath `
            -CaptureSaveFolder $CaptureSaveFolder -SimpleMailPort $SimpleMailPort `
            -SkipCorePolicySetup:($script:PolicyStackPushed -or $SkipCorePolicySetup)
        if ($LASTEXITCODE -ne 0) {
            throw 'MA-02 C long reconnect scenario failed (MA-02-C-NCP7307 exit non-zero).'
        }
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
    if ($statusFilePath) { [void]$script:EvidencePaths.Add($statusFilePath) }
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    if ($script:PolicyStackPushed -and $script:CoreDebugHookUrl) {
        try {
            Write-TestStep 'Core: poppolicystate'
            Restore-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    foreach ($folder in @($stagingFoldersToRemove)) {
        if ($folder -and (Test-Path -LiteralPath $folder)) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
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