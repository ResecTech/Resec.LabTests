#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:Ma02EDatabaseSimulationMayBeOn = $false

function Test-Ma02EDatabaseSimulationNeedsCleanup {
    return $script:Ma02EDatabaseSimulationMayBeOn -eq $true
}

function Get-MailAgentE2eMa02CoreRestUrl {
    param(
        [string] $CoreRestBaseUrl = '',
        [string] $CoreDebugBaseUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($CoreRestBaseUrl)) {
        return $CoreRestBaseUrl.TrimEnd('/')
    }

    $debug = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    if ($debug -like 'http*') {
        return $debug.TrimEnd('/')
    }

    return 'https://localhost:4504'
}

function Invoke-Ma02StepA {
    param(
        [string] $MailAgentDebugUrl,
        [string] $Context = 'MA-02 A'
    )

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Context - idle temp folder baseline check."
    Assert-MailAgentE2eIdleTempFolders -BaseUrl $MailAgentDebugUrl -Context $Context
}

function Test-MailAgentE2eLogShowsSanitizationOutputLockNoise {
    param(
        [string] $BaseUrl = '',
        [int] $TailLineCount = 400
    )

    $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $BaseUrl
    if ([string]::IsNullOrWhiteSpace($log) -or -not (Test-Path -LiteralPath $log)) {
        return $false
    }

    $tail = @(Get-Content -LiteralPath $log -Tail $TailLineCount -ErrorAction SilentlyContinue)
    $blob = ($tail -join [Environment]::NewLine)
    return ($blob -match '(?i)SanitizationOutput.*lock|lock.*SanitizationOutput')
}

function Invoke-Ma02StepB {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Lab,
        [int] $EmailCount = 8,
        [int] $MaxParallelSends = 3,
        [int] $RunningWaitSec = 90,
        [int] $TerminalWaitSec = 600,
        [string] $InboundServer,
        [int] $InboundPort,
        [string] $MailFrom,
        [string] $MailTo,
        [string] $CallingScriptRoot,
        [string] $CoreDebugHookUrl = ''
    )

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] MA-02 B - burst send $EmailCount messages; restart agent while some mail is still in flight."

    $subjectPrefix = 'MA02-B-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $Lab.AttachFolder -SmtpServer $InboundServer `
        -SmtpPort $InboundPort -From $MailFrom -To $MailTo -SendTimeoutSeconds $TerminalWaitSec `
        -SubjectPrefix $subjectPrefix -EmailCount $EmailCount -MaxParallelSends $MaxParallelSends `
        -MinAttachmentsPerEmail 1 -MaxAttachmentsPerEmail 1

    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $subjectPrefix
    Start-Sleep -Seconds 2

    if (-not [string]::IsNullOrWhiteSpace($CoreDebugHookUrl)) {
        $null = Wait-CoreE2eRunningSanitizationForSubject -HookUrl $CoreDebugHookUrl -SubjectPrefix $subjectPrefix `
            -TimeoutSec $RunningWaitSec -Context 'MA-02 B'
    }
    else {
        $null = Wait-MailAgentE2eBurstInFlight -BaseUrl $Lab.MailAgentDebugUrl -TimeoutSec $RunningWaitSec -Context 'MA-02 B'
    }

    Restart-MailAgentE2eWindowsServiceOrProcess -CallingScriptRoot $CallingScriptRoot `
        -MailAgentDebugUrl $Lab.MailAgentDebugUrl -MailAgentExePath $Lab.MailAgentExePath `
        -ExpectedInboundPort $InboundPort -StartupTimeoutSec $Lab.MailAgentStartupTimeoutSec

    $null = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $TerminalWaitSec `
        -ProgressLabel 'MA-02 B' -MailAgentDebugUrl $Lab.MailAgentDebugUrl -ProgressIntervalSec 5

    $status = Wait-MailAgentDebugReady -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $InboundPort
    $connProp = $status.PSObject.Properties['coreConnectionStatus']
    $conn = if ($null -ne $connProp) { [string]$connProp.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($conn)) {
        $conn = if ($status.coreConnected -eq $true) { 'Authenticated' } else { 'Disconnected' }
    }
    if ($conn -notmatch '(?i)authenticated') {
        throw "MA-02 B: mail agent not Authenticated after burst ($(Format-MailAgentDebugStatusSummary -Status $status))."
    }

    if (Test-MailAgentE2eLogShowsSanitizationOutputLockNoise -BaseUrl $Lab.MailAgentDebugUrl) {
        throw 'MA-02 B: mail agent log shows persistent SanitizationOutput lock errors.'
    }

    $null = Wait-MailAgentE2eIdleTempFolders -BaseUrl $Lab.MailAgentDebugUrl -TimeoutSec 90 -Context 'MA-02 B after burst'
    Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Ma02StepD {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Lab,
        [string] $CoreDebugBaseUrl,
        [int] $CommdownHoldSeconds = 300,
        [string] $InboundServer,
        [int] $InboundPort,
        [string] $MailFrom,
        [string] $MailTo,
        [int] $DeliveryTimeoutSec = 180
    )

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] MA-02 D - Core commdown ${CommdownHoldSeconds}s without restarting mail agent."

    $agentPidBefore = $null
    foreach ($proc in @(Get-MailAgentE2eDesktopAgentProcesses -AgentExePath $Lab.MailAgentExePath)) {
        $agentPidBefore = $proc.Id
        break
    }

    Set-MailAgentCoreAgentCommDown -BaseUrl $CoreDebugBaseUrl | Out-Null
    Start-Sleep -Seconds $CommdownHoldSeconds
    Set-MailAgentCoreAgentCommUp -BaseUrl $CoreDebugBaseUrl | Out-Null
    $null = Wait-MailAgentDebugReconnect -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $InboundPort -TimeoutSec 120

    if ($null -ne $agentPidBefore) {
        $still = @(Get-MailAgentE2eDesktopAgentProcesses -AgentExePath $Lab.MailAgentExePath | Where-Object { $_.Id -eq $agentPidBefore })
        if ($still.Count -eq 0) {
            throw "MA-02 D: mail agent process pid=$agentPidBefore exited during Core commdown (plan expects no manual agent restart)."
        }
    }

    Clear-CaptureFolder -Folder $Lab.CaptureFolder
    $captureBaseline = Get-CaptureFolderFileSnapshot -Folder $Lab.CaptureFolder
    $statusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $subjectPrefix = 'MA02-D-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $Lab.AttachFolder -SmtpServer $InboundServer `
        -SmtpPort $InboundPort -From $MailFrom -To $MailTo -SendTimeoutSeconds $DeliveryTimeoutSec `
        -SubjectPrefix $subjectPrefix
    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $subjectPrefix
    $bulkReport = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec `
        -ProgressLabel 'MA-02 D' -MailAgentDebugUrl $Lab.MailAgentDebugUrl -ProgressIntervalSec 5
    $expectedSubject = '{0}-1' -f [string]$bulkReport.subjectPrefix
    $null = Wait-ForCapturedSubject -StatusPath $Lab.StatusFilePath -ExpectedSubject $expectedSubject `
        -TimeoutSec $DeliveryTimeoutSec -MinMessageCount $statusBaseline -CaptureFolder $Lab.CaptureFolder `
        -ExcludeCaptureFiles $captureBaseline

    $status = Wait-MailAgentDebugReady -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $InboundPort
    $connProp = $status.PSObject.Properties['coreConnectionStatus']
    $conn = if ($null -ne $connProp) { [string]$connProp.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($conn)) {
        $conn = if ($status.coreConnected -eq $true) { 'Authenticated' } else { 'Disconnected' }
    }
    if ($conn -notmatch '(?i)authenticated') {
        throw "MA-02 D: mail agent not Authenticated after commdown recovery ($(Format-MailAgentDebugStatusSummary -Status $status))."
    }

    Assert-MailAgentE2eIdleTempFolders -BaseUrl $Lab.MailAgentDebugUrl -Context 'MA-02 D after delivery'
    Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Ma02StepE {
    param(
        [string] $ComputerName = '127.0.0.1',
        [int] $Port,
        [string] $MailAgentDebugUrl = '',
        [string] $CoreDebugHookUrl = '',
        [int] $TotalMinutes = 15,
        [int] $IntervalMinutes = 5,
        [switch] $SkipCoreDatabaseSimulation
    )

    if (-not $SkipCoreDatabaseSimulation -and [string]::IsNullOrWhiteSpace($CoreDebugHookUrl)) {
        throw 'MA-02 E requires Core debug hook URL for dbsimulate (set -CoreDebugHookUrl or use -SkipCoreDatabaseSimulation for listen-only).'
    }

    $useDbSim = -not $SkipCoreDatabaseSimulation
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] MA-02 E - listen port soak ${TotalMinutes}m every ${IntervalMinutes}m (NCP-7217 class)."
    if ($useDbSim) {
        Write-Host '[INFO] MA-02 E: enabling Core dbsimulateon for soak (EF connection open blocked; does not stop SQL Server service).'
        Set-CoreE2eDatabaseSimulation -HookUrl $CoreDebugHookUrl -SimulateOffline $true | Out-Null
        Assert-CoreE2eDatabaseSimulationActive -HookUrl $CoreDebugHookUrl -Context 'MA-02 E after dbsimulateon'
        $script:Ma02EDatabaseSimulationMayBeOn = $true
    }
    else {
        Write-Host '[INFO] MA-02 E: listen-port soak only (-SkipCoreDatabaseSimulation); perform real SQL maintenance separately if needed.'
    }

    try {
        Invoke-MailAgentE2eListenPortSoak -ComputerName $ComputerName -Port $Port -BaseUrl $MailAgentDebugUrl `
            -TotalMinutes $TotalMinutes -IntervalMinutes $IntervalMinutes -Context 'MA-02 E' `
            -CoreDebugHookUrl $(if ($useDbSim) { $CoreDebugHookUrl } else { '' })
    }
    finally {
        if ($useDbSim) {
            try {
                Set-CoreE2eDatabaseSimulation -HookUrl $CoreDebugHookUrl -SimulateOffline $false | Out-Null
            }
            finally {
                $script:Ma02EDatabaseSimulationMayBeOn = $false
            }
        }
    }
}

function Initialize-MailAgentE2eMa02SharedLab {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $MailAgentDebugUrl,
        [string] $CoreDebugHookUrl,
        [string] $BulkExe,
        [string] $SmsExe,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort,
        [double] $ResponseDelaySeconds,
        [string] $CaptureSaveFolder,
        [string] $SmsConfig,
        [int] $SimpleMailStartupTimeoutSec,
        [switch] $SkipStartSimpleMailServer,
        [string] $MailAgentExePath,
        [int] $MailAgentStartupTimeoutSec,
        [int] $InboundPort
    )

    $testFilesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $CallingScriptRoot
    $attachRoot = Get-MailAgentE2eAttachmentFolder -TestFilesRoot $testFilesRoot
    $cleanSample = Join-Path $attachRoot 'clean-sample.txt'
    if (-not (Test-Path -LiteralPath $cleanSample)) {
        throw "MA-02 lab: missing fixture $cleanSample"
    }
    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($cleanSample)

    if ([string]::IsNullOrWhiteSpace($CaptureSaveFolder)) {
        $CaptureSaveFolder = Join-Path $env:TEMP 'MailE2e-MA02-CapturedOutbound'
    }
    $CaptureSaveFolder = [System.IO.Path]::GetFullPath($CaptureSaveFolder)
    $statusFilePath = Join-Path $CaptureSaveFolder 'simple-mail-server-status.json'

    $smsEnsure = Ensure-MailAgentE2eSimpleMailServerHeadless -SimpleMailServerExe $SmsExe -ConfigPath $SmsConfig `
        -Port $SimpleMailPort -ResponseDelaySeconds $ResponseDelaySeconds -SaveFolder $CaptureSaveFolder `
        -StatusFilePath $statusFilePath -ListenHost $SimpleMailListenHost `
        -StartupTimeoutSec $SimpleMailStartupTimeoutSec -SkipStart:$SkipStartSimpleMailServer
    Assert-MailAgentE2eSimpleMailServerListening -ListenHost $SimpleMailListenHost -Port $SimpleMailPort `
        -SimpleMailServerExe $SmsExe -ConfigPath $SmsConfig -SaveFolder $CaptureSaveFolder `
        -ResponseDelaySeconds $ResponseDelaySeconds -StatusFilePath $statusFilePath

    return @{
        MailAgentDebugUrl          = $MailAgentDebugUrl
        CoreDebugHookUrl           = $CoreDebugHookUrl
        BulkExe                    = $BulkExe
        AttachFolder               = $attachFolder
        CaptureFolder              = $CaptureSaveFolder
        StatusFilePath             = $statusFilePath
        SimpleMailProcess          = $smsEnsure.Process
        SimpleMailStartedByScript  = [bool]$smsEnsure.StartedByScript
        MailAgentExePath           = $MailAgentExePath
        MailAgentStartupTimeoutSec = $MailAgentStartupTimeoutSec
        InboundPort                = $InboundPort
    }
}