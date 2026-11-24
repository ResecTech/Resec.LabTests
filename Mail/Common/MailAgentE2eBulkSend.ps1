#Requires -Version 5.1
<#
.SYNOPSIS
  Shared SendBulkAttachmentMail + SimpleMailServer capture helpers for Mail Agent E2E scripts.
#>
Set-StrictMode -Version Latest

function Write-MailAgentE2eBulkPrerequisitesHelp {
    param([string] $CallingScriptRoot = '')

    $commonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
    if ([string]::IsNullOrWhiteSpace($CallingScriptRoot)) {
        $CallingScriptRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'P0'
    }

    $testTreeRoot = Get-LabMailTestTreeRoot
    $labTestsRoot = Get-LabTestsRootForMailE2eTools
    $repoRoot = Get-MailAgentE2eRepoRoot -CallingScriptRoot $CallingScriptRoot
    $sln = Join-Path (Get-LabMailProductRoot) 'Resec.Agent.Mail.sln'

    Write-Host ''
    Write-Host '=== Mail Agent E2E — required fixtures and tools ==='
    Write-Host 'Build SimpleMailServer (Resec.LabTests):'
    Write-Host "  dotnet build $(Join-Path $labTestsRoot 'Tools\SimpleMailServer\SimpleMailServer.csproj') -c Debug"
    Write-Host 'Build SendBulkAttachmentMail (Resec.Agent.Mail):'
    Write-Host "  dotnet build `"$sln`" -c Debug -p:Platform=x64"
    Write-Host 'Optional for MA-01 step E only — SendEml:'
    Write-Host "  dotnet build `"$sln`" -c Debug (includes SendEml project)"
    Write-Host ''
    Write-Host 'Set tool paths (session):'
    Write-Host "  . $(Join-Path $commonRoot 'Initialize-MailAgentE2eToolPaths.ps1')"
    Write-Host ''
    Write-Host 'Or set MAIL_E2E_SIMPLE_MAIL_SERVER_EXE / MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE, or pass explicit -Path parameters.'
    Write-Host 'Typical build outputs:'
    Write-Host "  $(Join-Path $labTestsRoot 'Tools\SimpleMailServer\bin\x64\Debug\net11.0-windows7.0\win-x64\SimpleMailServer.exe')"
    Write-Host "  $(Join-Path $repoRoot 'SendBulkAttachmentMail\bin\Debug\net11.0-windows7.0\win-x64\SendBulkAttachmentMail.exe')"
    Write-Host ''
    Write-Host 'Repo fixtures (or set MAILAGENT_TEST_FILES_ROOT):'
    Write-Host "  $(Join-Path $testTreeRoot 'Config\simple-mail-server.appsettings.json')"
    Write-Host "  $(Join-Path (Get-LabFixturesRoot) 'Mail\E2eAttach\') (attachments for bulk inbound send)"
    Write-Host ''
    Write-Host 'Running lab: Core + mail agent with debug enabled; policy next hop -> SimpleMail port (default 26).'
    Write-Host 'Details: Resec.LabTests\Mail\Common\README.md'
    Write-Host '=========================================='
    Write-Host ''
}

function Assert-MailAgentE2eBulkPrerequisites {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $SimpleMailServerPathOverride = '',
        [string] $SendBulkAttachmentMailPathOverride = '',
        [switch] $RequireSendEml
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $testTreeRoot = Split-Path $CallingScriptRoot -Parent

    $smsConfig = Join-Path $testTreeRoot 'Config\simple-mail-server.appsettings.json'
    if (-not (Test-Path -LiteralPath $smsConfig)) {
        $failures.Add("Missing SimpleMailServer config: $smsConfig")
    }

    try {
        $testFilesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $CallingScriptRoot
        $attachFolder = Get-MailAgentE2eAttachmentFolder -TestFilesRoot $testFilesRoot
        $attachCount = @(Get-ChildItem -LiteralPath $attachFolder -File -Force -ErrorAction SilentlyContinue).Count
        if ($attachCount -lt 1) {
            $failures.Add("No attachment files under: $attachFolder")
        }
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    try {
        Resolve-SimpleMailServerPath -CallingScriptRoot $CallingScriptRoot -Path $SimpleMailServerPathOverride | Out-Null
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    try {
        Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $CallingScriptRoot -Path $SendBulkAttachmentMailPathOverride | Out-Null
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    if ($RequireSendEml) {
        try {
            Resolve-SendEmlPath -CallingScriptRoot $CallingScriptRoot | Out-Null
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }

    if ($failures.Count -gt 0) {
        Write-MailAgentE2eBulkPrerequisitesHelp -CallingScriptRoot $CallingScriptRoot
        throw ("Mail E2E prerequisites not satisfied:`n - " + ($failures -join "`n - "))
    }
}

function Resolve-MailAgentE2eTempFolder {
    param(
        [string] $OverridePath = '',
        [string] $MailAgentDebugUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return [System.IO.Path]::GetFullPath($OverridePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_TEMP_FOLDER)) {
        return [System.IO.Path]::GetFullPath($env:MAIL_E2E_TEMP_FOLDER.Trim())
    }

    return Get-MailAgentDebugTempFolderRoot -BaseUrl $MailAgentDebugUrl
}

function Get-MailAgentE2eSanitizationOutputFolder {
    param([string] $TempRoot)
    return Join-Path $TempRoot.TrimEnd('\') 'SanitizationOutput'
}

function Get-SanitizationStagingFileSnapshot {
    param([string] $OutputFolder)

    $snapshot = @{}
    if (-not [System.IO.Directory]::Exists($OutputFolder)) {
        return $snapshot
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $OutputFolder -File -Force -ErrorAction SilentlyContinue)) {
        $snapshot[$file.FullName] = $true
    }

    return $snapshot
}

function Get-FirstNewSanitizationStagingFile {
    param(
        [string] $OutputFolder,
        [hashtable] $ExcludePaths
    )

    if (-not [System.IO.Directory]::Exists($OutputFolder)) {
        return $null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $OutputFolder -File -Force -ErrorAction SilentlyContinue)) {
        if (-not $ExcludePaths.ContainsKey($file.FullName)) {
            return $file.FullName
        }
    }

    return $null
}

function Get-EmlSubjectLine {
    param([string] $EmlPath)

    if (-not (Test-Path -LiteralPath $EmlPath)) {
        return $null
    }

    foreach ($line in [System.IO.File]::ReadLines($EmlPath)) {
        if ($line -match '^Subject:\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Get-SimpleMailServerStatusSnapshot {
    param([string] $StatusPath)

    if (-not (Test-Path -LiteralPath $StatusPath)) {
        return @{ MessageCount = 0 }
    }

    try {
        $json = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
        return @{ MessageCount = [int]$json.messageCount }
    }
    catch {
        return @{ MessageCount = 0 }
    }
}

function Get-CaptureFolderFileSnapshot {
    param([string] $Folder)

    $snapshot = @{}
    if (-not [System.IO.Directory]::Exists($Folder)) {
        return $snapshot
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue)) {
        $snapshot[$file.FullName] = $true
    }

    return $snapshot
}

function Resolve-CapturedMailSubject {
    param(
        $StatusJson,
        [string] $CaptureFolder,
        [hashtable] $ExcludeCaptureFiles
    )

    $subject = [string]$StatusJson.lastSubject
    $savedPath = [string]$StatusJson.lastSavedFilePath
    if ([string]::IsNullOrWhiteSpace($subject) -and -not [string]::IsNullOrWhiteSpace($savedPath)) {
        $subject = Get-EmlSubjectLine -EmlPath $savedPath
    }

    if (-not [string]::IsNullOrWhiteSpace($subject)) {
        return @{ Subject = $subject; SourcePath = $savedPath }
    }

    if ([string]::IsNullOrWhiteSpace($CaptureFolder) -or -not (Test-Path -LiteralPath $CaptureFolder)) {
        return $null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $CaptureFolder -Filter '*.eml' -File -Force -ErrorAction SilentlyContinue)) {
        if ($ExcludeCaptureFiles.ContainsKey($file.FullName)) {
            continue
        }

        $fromFile = Get-EmlSubjectLine -EmlPath $file.FullName
        if (-not [string]::IsNullOrWhiteSpace($fromFile)) {
            return @{ Subject = $fromFile; SourcePath = $file.FullName }
        }
    }

    return $null
}

function Wait-ForCapturedSubject {
    param(
        [string] $StatusPath,
        [string] $ExpectedSubject,
        [int] $TimeoutSec,
        [int] $MinMessageCount = 0,
        [string] $CaptureFolder = '',
        [hashtable] $ExcludeCaptureFiles
    )

    if ($null -eq $ExcludeCaptureFiles) {
        $ExcludeCaptureFiles = @{}
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $StatusPath) {
            $json = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
            if ([int]$json.messageCount -gt $MinMessageCount) {
                $resolved = Resolve-CapturedMailSubject -StatusJson $json -CaptureFolder $CaptureFolder -ExcludeCaptureFiles $ExcludeCaptureFiles
                if ($null -ne $resolved -and $resolved.Subject -like "*$ExpectedSubject*") {
                    $json | Add-Member -NotePropertyName resolvedSubject -NotePropertyValue $resolved.Subject -Force
                    $json | Add-Member -NotePropertyName resolvedSavedFilePath -NotePropertyValue $resolved.SourcePath -Force
                    return $json
                }
            }
        }

        $folderHit = Resolve-CapturedMailSubject -StatusJson @{} -CaptureFolder $CaptureFolder -ExcludeCaptureFiles $ExcludeCaptureFiles
        if ($null -ne $folderHit -and $folderHit.Subject -like "*$ExpectedSubject*") {
            return [pscustomobject]@{
                messageCount          = ($MinMessageCount + 1)
                lastSubject           = $folderHit.Subject
                lastSavedFilePath     = $folderHit.SourcePath
                resolvedSubject       = $folderHit.Subject
                resolvedSavedFilePath = $folderHit.SourcePath
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "SimpleMailServer did not record subject containing '$ExpectedSubject' within ${TimeoutSec}s (status=$StatusPath)."
}

function Wait-ForSanitizationStagingWhileProcessRunning {
    param(
        [string] $OutputFolder,
        [System.Diagnostics.Process] $BulkProcess,
        [hashtable] $ExcludePaths,
        [int] $TimeoutSec
    )

    if (-not [System.IO.Directory]::Exists($OutputFolder)) {
        [System.IO.Directory]::CreateDirectory($OutputFolder) | Out-Null
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $file = Get-FirstNewSanitizationStagingFile -OutputFolder $OutputFolder -ExcludePaths $ExcludePaths
        if ($null -ne $file) {
            return $file
        }
        if ($BulkProcess.HasExited) {
            $graceDeadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
            while ([DateTimeOffset]::UtcNow -lt $graceDeadline) {
                $lateFile = Get-FirstNewSanitizationStagingFile -OutputFolder $OutputFolder -ExcludePaths $ExcludePaths
                if ($null -ne $lateFile) {
                    return $lateFile
                }
                Start-Sleep -Milliseconds 250
            }
            return $null
        }
        Start-Sleep -Milliseconds 250
    }

    return $null
}

function New-BulkSendAppsettings {
    param(
        [string] $AttachmentFolder,
        [string] $SmtpServer,
        [int] $SmtpPort,
        [string] $From,
        [string] $To,
        [int] $SendTimeoutSeconds = 90,
        [string] $SubjectPrefix = '',
        [int] $MinAttachmentsPerEmail = 1,
        [int] $MaxAttachmentsPerEmail = 1,
        [int] $EmailCount = 1,
        [int] $MaxParallelSends = 1
    )

    $settings = [ordered]@{
        Smtp                     = [ordered]@{
            Server                = $SmtpServer
            Port                  = $SmtpPort
            ConnectTimeoutSeconds = 30
            SendTimeoutSeconds    = $SendTimeoutSeconds
            UseSsl                = $false
            ForceIPv4             = $true
            Username              = $null
            Password              = $null
        }
        Mail                     = [ordered]@{
            From = $From
            To   = $To
        }
        Attachments              = [ordered]@{
            RootFolder = (Split-Path -Parent $AttachmentFolder)
            Subfolder  = (Split-Path -Leaf $AttachmentFolder)
        }
        MinAttachmentsPerEmail   = $MinAttachmentsPerEmail
        MaxAttachmentsPerEmail   = $MaxAttachmentsPerEmail
        EmailsPerHour            = 3600
        MaxParallelSends         = $MaxParallelSends
        EmailCount               = $EmailCount
        TestTimeMinutes          = 0
        PercentToAllRecipients   = 100
    }

    if (-not [string]::IsNullOrWhiteSpace($SubjectPrefix)) {
        $settings.SubjectPrefix = $SubjectPrefix
    }

    $path = Join-Path $env:TEMP "MailE2e-bulk-$(Get-Date -Format 'yyyyMMddHHmmssfff').json"
    ($settings | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Start-BulkSendOnce {
    param(
        [string] $ExePath,
        [string] $ConfigPath,
        [string] $SubjectPrefix
    )

    if ([string]::IsNullOrWhiteSpace($SubjectPrefix)) {
        $subjectPrefix = Get-Date -Format 'yyyyMMddHHmmss'
    }
    else {
        $subjectPrefix = $SubjectPrefix
    }
    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $stdoutFile = Join-Path $env:TEMP "MailE2e-bulk-stdout-$stamp.log"
    $stderrFile = Join-Path $env:TEMP "MailE2e-bulk-stderr-$stamp.log"

    $proc = Start-Process -FilePath $ExePath -ArgumentList @('--cli', '--json', '--config', $ConfigPath) `
        -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

    return @{
        Process         = $proc
        ExpectedSubject = '{0}-1' -f $subjectPrefix
        SubjectPrefix   = $subjectPrefix
        StdoutFile      = $stdoutFile
        StderrFile      = $stderrFile
    }
}

function Get-MailAgentE2eBulkSendFailureHints {
    param(
        [string] $FailureDetail = '',
        [string] $StderrText = ''
    )

    $blob = ($FailureDetail + ' ' + $StderrText).ToLowerInvariant()
    $hints = New-Object System.Collections.Generic.List[string]

    $hints.Add('SendBulkAttachmentMail submits to the mail agent inbound SMTP (see stderr host/port), not to SimpleMailServer.')
    $hints.Add('The mail agent may still deliver outbound to the policy next hop on port 26 after this failure; check the mail agent log and simple-mail-server-status.json.')

    if ($blob -match '451|service unavailable|try again later') {
        $hints.Add('Expected during Core commdown on open inbound session; mail agent may return 451 (retry).')
    }
    elseif ($blob -match '554|taskcanceled|canceled|cancelled|disconnected|session') {
        $hints.Add('Likely Core commdown while inbound session was open (Send Immediate Response off).')
    }
    elseif ($blob -match '421|service not available|closing connection') {
        $hints.Add('Likely temporary SMTP 421 from the mail agent (next-hop or queue pressure).')
    }
    elseif ($blob -match '120000 milliseconds') {
        $hints.Add('MailKit SmtpClient default 120s cap (rebuild SendBulkAttachmentMail after MailSendHelper.Timeout fix) or increase DeliveryTimeoutSec / Smtp:SendTimeoutSeconds when Send Immediate Response is off.')
    }
    else {
        $hints.Add('Mail agent log: GET http://127.0.0.1:4505/debug/hook?command=logpath (when debug enabled).')
    }

    return $hints
}

function Test-MailAgentE2eExpectedCommdownInbound451 {
    param(
        [string] $FailureDetail = '',
        [string] $StderrText = '',
        [string] $StdoutText = ''
    )

    $blob = ($FailureDetail + ' ' + $StderrText + ' ' + $StdoutText).ToLowerInvariant()
    return ($blob -match '451') -or ($blob -match 'service unavailable') -or ($blob -match 'try again later')
}

function Assert-MailAgentE2eCommdownInbound451Observed {
    param(
        [Parameter(Mandatory)]
        [hashtable] $BulkJob,
        [string] $FailureDetail = '',
        [string] $Context = 'MA-02 C commdown',
        [string] $MailAgentDebugUrl = '',
        [int] $AgentLogTailLines = 600
    )

    $redirect = Read-MailAgentE2eBulkSendRedirectFiles -StdoutFile $BulkJob.StdoutFile -StderrFile $BulkJob.StderrFile
    if (Test-MailAgentE2eExpectedCommdownInbound451 -FailureDetail $FailureDetail `
            -StderrText $redirect.Stderr -StdoutText $redirect.Stdout) {
        Write-Host "[INFO] $Context - inbound SMTP 451 (or equivalent) observed in SendBulk output."
        return
    }

    $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $MailAgentDebugUrl
    if (-not [string]::IsNullOrWhiteSpace($log) -and (Test-Path -LiteralPath $log)) {
        $tail = @(Get-Content -LiteralPath $log -Tail $AgentLogTailLines -ErrorAction SilentlyContinue)
        $blob = ($tail -join [Environment]::NewLine).ToLowerInvariant()
        if (($blob -match '\b451\b') -and ($blob -match 'smtp|inbound|service unavailable|try again')) {
            Write-Host "[INFO] $Context - inbound SMTP 451 observed in mail agent log tail."
            return
        }
    }

    throw "$Context - expected inbound SMTP 451 during Core commdown on open session; not found in SendBulk output or agent log."
}

function Read-MailAgentE2eBulkSendRedirectFiles {
    param(
        [Parameter(Mandatory)][string] $StdoutFile,
        [Parameter(Mandatory)][string] $StderrFile,
        [int] $SettleWaitMs = 250
    )

    $stdoutText = ''
    $stderrText = ''
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([Math]::Max(0, $SettleWaitMs))
    do {
        if (Test-Path -LiteralPath $StdoutFile) {
            $stdoutText = [System.IO.File]::ReadAllText($StdoutFile)
        }
        if (Test-Path -LiteralPath $StderrFile) {
            $stderrText = [System.IO.File]::ReadAllText($StderrFile)
        }
        if (-not [string]::IsNullOrWhiteSpace($stdoutText.Trim())) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Milliseconds 50
    } while ($true)

    return @{
        Stdout = $stdoutText
        Stderr = $stderrText
    }
}

function ConvertFrom-MailAgentE2eBulkSendJsonReport {
    param([string] $StdoutText)

    if ([string]::IsNullOrWhiteSpace($StdoutText)) {
        return $null
    }

    $candidates = @($StdoutText.Trim())
    foreach ($line in @($StdoutText -split '\r?\n')) {
        $trim = $line.Trim()
        if ($trim.StartsWith('{') -and $trim.EndsWith('}')) {
            $candidates += $trim
        }
    }

    foreach ($json in @($candidates | Select-Object -Unique)) {
        try {
            return $json | ConvertFrom-Json
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-MailAgentE2eBulkSendResolvedExitCode {
    param(
        $Process,
        $JsonReport
    )

    $Process.Refresh()
    $exitCode = $Process.ExitCode
    $jsonExit = $null
    if ($null -ne $JsonReport -and $null -ne $JsonReport.statistics) {
        $jsonExit = $JsonReport.statistics.exitCode
    }

    if ($null -eq $exitCode -or ($exitCode -eq -1 -and $null -ne $jsonExit -and [int]$jsonExit -ge 0)) {
        if ($null -ne $jsonExit) {
            return [int]$jsonExit
        }
    }

    if ($null -eq $exitCode) {
        return -1
    }

    return [int]$exitCode
}

function Complete-BulkSendOnce {
    param(
        [hashtable] $BulkJob,
        [int] $WaitExitTimeoutSec = 180,
        [switch] $AllowExpectedCommdown451,
        [string] $ProgressLabel = '',
        [string] $MailAgentDebugUrl = '',
        [int] $ProgressIntervalSec = 5,
        [int] $InboundStallFailTimeoutSec = 75,
        [switch] $EmitLogMarks = $false,
        [string] $E2eTestId = '',
        [string] $CoreDebugHookUrl = ''
    )

    if ($EmitLogMarks -and [string]::IsNullOrWhiteSpace($E2eTestId)) {
        $EmitLogMarks = $false
    }

    $proc = $BulkJob.Process
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitExitTimeoutSec)
    $logProgress = -not [string]::IsNullOrWhiteSpace($ProgressLabel) -and -not [string]::IsNullOrWhiteSpace($MailAgentDebugUrl)
    $bulkStartedUtc = [DateTimeOffset]::UtcNow
    $emitLogMark = $EmitLogMarks -and `
        (-not [string]::IsNullOrWhiteSpace($CoreDebugHookUrl) -or -not [string]::IsNullOrWhiteSpace($MailAgentDebugUrl))

    if ($emitLogMark) {
        Write-MailAgentE2eCorrelationLogMark -TestId $E2eTestId `
            -Mark "$ProgressLabel | bulk SendBulkAttachmentMail started pid=$($proc.Id)" `
            -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $MailAgentDebugUrl
    }

    while (-not $proc.HasExited) {
        $remainingSec = ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds
        if ($remainingSec -le 0) {
            $hint = "With Send Immediate Response off the client waits for full sanitization+outbound on the open SMTP session; lab runs usually finish within 60s. If this exceeds ${WaitExitTimeoutSec}s, check Core sanitization, relay PutFile (StrPropType_RelayName), and next hop."
            throw "SendBulkAttachmentMail did not exit within ${WaitExitTimeoutSec}s (PID $($proc.Id)). $hint"
        }

        $waitMs = [Math]::Min($ProgressIntervalSec * 1000, [int][Math]::Ceiling($remainingSec * 1000))
        if (-not $proc.WaitForExit($waitMs)) {
            if ($logProgress) {
                $st = $null
                try {
                    $st = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $MailAgentDebugUrl
                }
                catch {
                    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    Write-Host ("[{0}] [STEP] {1} inbound wait (Send Immediate Response off): (status unavailable: $($_.Exception.Message))" -f $ts, $ProgressLabel)
                }

                if ($null -ne $st) {
                    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    $elapsedSec = [int][Math]::Floor(($bulkStartedUtc - [DateTimeOffset]::UtcNow).TotalSeconds * -1)
                    $summary = Format-MailAgentDebugStatusSummary -Status $st
                    Write-Host ("[{0}] [STEP] {1} inbound wait ({2}s elapsed, Send Immediate Response off): {3}" -f $ts, $ProgressLabel, $elapsedSec, $summary)
                    if ($emitLogMark) {
                        Write-MailAgentE2eCorrelationLogMark -TestId $E2eTestId `
                            -Mark "$ProgressLabel | wait ${elapsedSec}s | $summary" `
                            -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $MailAgentDebugUrl
                    }
                    if ($InboundStallFailTimeoutSec -gt 0 -and $elapsedSec -ge $InboundStallFailTimeoutSec -and (Test-MailAgentE2eRelayPutFileStall -Status $st)) {
                        throw ("Inbound delivery stalled after ${InboundStallFailTimeoutSec}s (open SMTP session, SanitizationInput backlog, outboundQueue=0). Core is likely waiting on relay PutFile (MQ can take up to 300s). Fix relay registration (StrPropType_RelayName=mail on lab policy), stop Resec.Agent.ScanAgent, then re-run. Last status: $(Format-MailAgentDebugStatusSummary -Status $st)")
                    }
                }
            }
        }
    }

    $null = $proc.WaitForExit()
    $proc.Refresh()

    $redirect = Read-MailAgentE2eBulkSendRedirectFiles -StdoutFile $BulkJob.StdoutFile -StderrFile $BulkJob.StderrFile
    $stdoutText = $redirect.Stdout
    $stderrText = $redirect.Stderr
    $report = ConvertFrom-MailAgentE2eBulkSendJsonReport -StdoutText $stdoutText
    $exitCode = Get-MailAgentE2eBulkSendResolvedExitCode -Process $proc -JsonReport $report

    if ($emitLogMark) {
        $exitHint = "exit=$exitCode"
        Write-MailAgentE2eCorrelationLogMark -TestId $E2eTestId `
            -Mark "$ProgressLabel | bulk SendBulkAttachmentMail finished $exitHint" `
            -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $MailAgentDebugUrl
    }

    if ($exitCode -ne 0) {
        $detail = $null
        if ($null -ne $report -and $null -ne $report.failedMessages -and @($report.failedMessages).Count -gt 0) {
            $first = @($report.failedMessages)[0]
            $detail = [string]$first.detail
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = [string]$first.subject
            }
        }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("SendBulkAttachmentMail failed (exit $exitCode).")
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $lines.Add("Detail: $detail")
        }
        $lines.Add('')
        if ($AllowExpectedCommdown451 -and (Test-MailAgentE2eExpectedCommdownInbound451 -FailureDetail $detail -StderrText $stderrText -StdoutText $stdoutText)) {
            Write-Host '[INFO] SendBulk exited non-zero with inbound 451 (expected during Core commdown on open session); continuing.'
            if ($null -ne $report) {
                return $report
            }

            return @{
                subjectPrefix  = $BulkJob.SubjectPrefix
                failedMessages = @(@{ detail = $detail })
            }
        }

        foreach ($hint in @(Get-MailAgentE2eBulkSendFailureHints -FailureDetail $detail -StderrText $stderrText)) {
            $lines.Add($hint)
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $lines.Add('')
            $lines.Add('stderr:')
            $lines.Add($stderrText.Trim())
        }
        throw ($lines -join [Environment]::NewLine)
    }

    if ($null -eq $report -or $null -eq $report.subjectPrefix) {
        throw "Bulk send JSON report missing subjectPrefix. stdout: $stdoutText"
    }

    return $report
}

function Complete-BulkSendExpectingFailure {
    param(
        [hashtable] $BulkJob,
        [int] $WaitExitTimeoutSec = 120,
        [switch] $RequireSmtp5xx
    )

    $proc = $BulkJob.Process
    if (-not $proc.WaitForExit($WaitExitTimeoutSec * 1000)) {
        throw "SendBulkAttachmentMail did not exit within ${WaitExitTimeoutSec}s (PID $($proc.Id))."
    }

    $null = $proc.WaitForExit()
    $proc.Refresh()

    $redirect = Read-MailAgentE2eBulkSendRedirectFiles -StdoutFile $BulkJob.StdoutFile -StderrFile $BulkJob.StderrFile
    $stdoutText = $redirect.Stdout
    $stderrText = $redirect.Stderr
    $combined = ($stdoutText + ' ' + $stderrText)
    $report = ConvertFrom-MailAgentE2eBulkSendJsonReport -StdoutText $stdoutText
    $exitCode = Get-MailAgentE2eBulkSendResolvedExitCode -Process $proc -JsonReport $report

    if ($exitCode -eq 0) {
        throw "Expected inbound SMTP failure (non-zero exit) for blocked/infected fixture, but SendBulk exited 0."
    }

    if ($RequireSmtp5xx -and ($combined -notmatch '\b5\d{2}\b')) {
        $failedCount = 0
        if ($null -ne $report -and $null -ne $report.statistics -and $null -ne $report.statistics.failed) {
            $failedCount = [int]$report.statistics.failed
        }
        if ($exitCode -ne 0 -and $failedCount -gt 0) {
            Write-Host '[INFO] SendBulk exited non-zero for blocked fixture without a literal 5xx token in output (rebuild SendBulkAttachmentMail for SMTP status in JSON failedMessages.detail).'
        }
        else {
            throw "Expected SMTP 5xx response in SendBulk output; exit=$exitCode output: $combined"
        }
    }

    return @{
        ExitCode  = $exitCode
        Output    = $combined
        Stderr    = $stderrText
    }
}

function Clear-CaptureFolder {
    param([string] $Folder)

    if (-not [System.IO.Directory]::Exists($Folder)) {
        [System.IO.Directory]::CreateDirectory($Folder) | Out-Null
        return
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function New-MailAgentE2eAttachmentStagingFolder {
    param(
        [Parameter(Mandatory)]
        [string[]] $SourceFilePaths
    )

    $dir = Join-Path $env:TEMP ('MailE2e-attach-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    foreach ($src in @($SourceFilePaths)) {
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Attachment staging source not found: $src"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dir (Split-Path -Leaf $src)) -Force
    }
    return $dir
}

function Test-UnicodeTextContainsResecSignatureMarker {
    param([Parameter(Mandatory)][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    return ($Text -match '(?i)ReSecure|resec')
}

function Test-CapturedEmlContainsResecSignature {
    param([Parameter(Mandatory)][string] $EmlPath)

    if (-not (Test-Path -LiteralPath $EmlPath)) {
        return $false
    }

    $text = [System.IO.File]::ReadAllText($EmlPath)
    if (Test-UnicodeTextContainsResecSignatureMarker -Text $text) {
        return $true
    }

    # Core plain-text mail signatures are usually in a base64-encoded text/plain part; raw .eml rarely contains literal "Resec".
    $plainB64Blocks = [regex]::Matches(
        $text,
        '(?is)Content-Type:\s*text/plain[^\r\n]*\r?\n(?:Content-[^\r\n]+\r?\n)*\r?\n([A-Za-z0-9+/=\r\n]+?)(?:\r?\n--|\r?\n\r?\n[A-Z]|$)')
    foreach ($match in $plainB64Blocks) {
        $b64 = ($match.Groups[1].Value -replace '\s', '')
        if ([string]::IsNullOrWhiteSpace($b64) -or ($b64.Length % 4) -ne 0) {
            continue
        }

        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            if (Test-UnicodeTextContainsResecSignatureMarker -Text $decoded) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

function Invoke-SendEmlToAgent {
    param(
        [Parameter(Mandatory)][string] $SendEmlExe,
        [Parameter(Mandatory)][string] $EmlPath,
        [Parameter(Mandatory)][string] $SmtpServer,
        [Parameter(Mandatory)][int] $SmtpPort,
        [string] $EnvelopeFromOverride
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add($EmlPath)
    $args.Add($SmtpServer)
    $args.Add([string]$SmtpPort)
    $args.Add('false')
    if ($PSBoundParameters.ContainsKey('EnvelopeFromOverride')) {
        $args.Add('')
        $args.Add('')
        $args.Add($EnvelopeFromOverride)
    }

    $stdoutFile = Join-Path $env:TEMP "MailE2e-sendeml-stdout-$(Get-Date -Format 'yyyyMMddHHmmssfff').log"
    $stderrFile = Join-Path $env:TEMP "MailE2e-sendeml-stderr-$(Get-Date -Format 'yyyyMMddHHmmssfff').log"
    $proc = Start-Process -FilePath $SendEmlExe -ArgumentList $args.ToArray() `
        -PassThru -NoNewWindow -Wait -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

    $stdout = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { '' }
    return @{
        ExitCode = $proc.ExitCode
        Output   = ($stdout + ' ' + $stderr).Trim()
        Stdout   = $stdout
        Stderr   = $stderr
    }
}