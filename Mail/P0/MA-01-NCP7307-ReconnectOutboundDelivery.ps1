#Requires -Version 5.1
<#
.SYNOPSIS
  MA-01 / NCP-7307: After Core comm outage during outbound staging, sanitized mail is delivered when Core returns.

.DESCRIPTION
  Runs two commdown hold durations (short ~10s and long ~30s) against the same lab setup.
  Each scenario: bulk inbound send, staging detection, commdown/commup, mail agent reconnect wait, delivery assert.

  Prerequisites:
    - Core with EnableDebugInterface=True; mail agent with EnableDebugInterface=true (debug hook :4505).
    - Policy next hop on SimpleMailPort.
    - Optional -MailTempFolder / MAIL_E2E_TEMP_FOLDER; otherwise resolved from mail agent debug status (tempFolderRoot).

  Required fixtures and tools (local repo):
    Build once from repo root:
      dotnet build src\Resec.Agent.Mail.sln -c Debug -p:Platform=x64
    Or publish single-file (Rider/VS Publish on SimpleMailServer and SendBulkAttachmentMail).

    | Artifact | Purpose |
    | --- | --- |
    | SimpleMailServer\bin\x64\Debug\net10.0-windows7.0\win-x64\SimpleMailServer.exe (or bin\publish\single-file\) | Outbound capture SMTP (--cli); started by this script unless -SkipStartSimpleMailServer |
    | SendBulkAttachmentMail\bin\Debug\net10.0-windows7.0\win-x64\SendBulkAttachmentMail.exe (or publish single-file) | Inbound bulk send to mail agent SMTP |
    | src\Test\Config\simple-mail-server.appsettings.json | Headless SimpleMailServer config for MA-01 |
    | Fixtures\Mail\E2eAttach\ | Attachments for bulk send (e.g. clean-sample.txt, minimal-inbound.eml) |

    Tool paths (first match wins): -SimpleMailServerPath / -SendBulkAttachmentMailPath, then
    MAIL_E2E_SIMPLE_MAIL_SERVER_EXE / MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE, then repo build outputs and PATH.
    Dot-source src\Test\Common\Initialize-MailAgentE2eToolPaths.ps1 to discover tools and set those variables.
    Set MAILAGENT_TEST_FILES_ROOT for fixture overrides.
    See src\Test\Common\README.md for lab setup (Core/mail agent debug, Test Platform env).

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
    [switch] $SkipStartSimpleMailServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

function Write-Ma01RequiredFixturesHelp {
    $testTreeRoot = Get-LabMailTestTreeRoot
    $repoRoot = Get-LabProductRepoRoot -Product Mail
    $sln = Join-Path (Get-LabMailProductRoot) 'Resec.Agent.Mail.sln'

    Write-Host ''
    Write-Host '=== MA-01 required fixtures and tools ==='
    Write-Host 'Build E2E utilities (from repo root):'
    Write-Host "  dotnet build `"$sln`" -c Debug -p:Platform=x64"
    Write-Host ''
    Write-Host 'Set tool paths (session):'
    Write-Host "  . $(Join-Path $script:MaE2eCommonRoot 'Initialize-MailAgentE2eToolPaths.ps1')"
    Write-Host ''
    Write-Host 'Or set MAIL_E2E_SIMPLE_MAIL_SERVER_EXE / MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE, or pass -SimpleMailServerPath / -SendBulkAttachmentMailPath.'
    Write-Host 'Typical build outputs:'
    Write-Host "  $(Join-Path $repoRoot 'SimpleMailServer\bin\x64\Debug\net10.0-windows7.0\win-x64\SimpleMailServer.exe')"
    Write-Host "  $(Join-Path $repoRoot 'SendBulkAttachmentMail\bin\Debug\net10.0-windows7.0\win-x64\SendBulkAttachmentMail.exe')"
    Write-Host ''
    Write-Host 'Repo fixtures (or set MAILAGENT_TEST_FILES_ROOT):'
    Write-Host "  $(Join-Path $testTreeRoot 'Config\simple-mail-server.appsettings.json')"
    Write-Host "  $(Join-Path (Get-LabFixturesRoot) 'Mail\E2eAttach\') (attachments for bulk inbound send)"
    Write-Host ''
    Write-Host 'Running lab: Core + mail agent with debug enabled; policy next hop -> SimpleMailPort (default 26).'
    Write-Host 'Details: Resec.LabTests\Mail\Common\README.md'
    Write-Host '=========================================='
    Write-Host ''
}

function Assert-Ma01E2eArtifacts {
    param(
        [string] $SimpleMailServerPathOverride = '',
        [string] $SendBulkAttachmentMailPathOverride = ''
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $testTreeRoot = Split-Path $PSScriptRoot -Parent

    $smsConfig = Join-Path $testTreeRoot 'Config\simple-mail-server.appsettings.json'
    if (-not (Test-Path -LiteralPath $smsConfig)) {
        $failures.Add("Missing SimpleMailServer config: $smsConfig")
    }

    try {
        $testFilesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $PSScriptRoot
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
        Resolve-SimpleMailServerPath -CallingScriptRoot $PSScriptRoot -Path $SimpleMailServerPathOverride | Out-Null
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    try {
        Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $PSScriptRoot -Path $SendBulkAttachmentMailPathOverride | Out-Null
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    if ($failures.Count -gt 0) {
        Write-Ma01RequiredFixturesHelp
        throw ("MA-01 prerequisites not satisfied:`n - " + ($failures -join "`n - "))
    }
}

Assert-Ma01E2eArtifacts -SimpleMailServerPathOverride $SimpleMailServerPath `
    -SendBulkAttachmentMailPathOverride $SendBulkAttachmentMailPath

$script:OverallPassed = $true
$simpleMailProcess = $null
$simpleMailStartedByScript = $false

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Get-EffectiveMailTempFolder {
    param([string] $MailAgentDebugUrl = '')

    if (-not [string]::IsNullOrWhiteSpace($MailTempFolder)) {
        return [System.IO.Path]::GetFullPath($MailTempFolder)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_TEMP_FOLDER)) {
        return [System.IO.Path]::GetFullPath($env:MAIL_E2E_TEMP_FOLDER.Trim())
    }

    return Get-MailAgentDebugTempFolderRoot -BaseUrl $MailAgentDebugUrl
}

function Get-SanitizationOutputFolder {
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
                messageCount = ($MinMessageCount + 1)
                lastSubject = $folderHit.Subject
                lastSavedFilePath = $folderHit.SourcePath
                resolvedSubject = $folderHit.Subject
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
            # SendBulk may exit on inbound 4xx while the agent still creates staging briefly afterward.
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
        [string] $SubjectPrefix = ''
    )

    $settings = [ordered]@{
        Smtp = [ordered]@{
            Server = $SmtpServer
            Port = $SmtpPort
            ConnectTimeoutSeconds = 30
            SendTimeoutSeconds = $SendTimeoutSeconds
            UseSsl = $false
            ForceIPv4 = $true
            Username = $null
            Password = $null
        }
        Mail = [ordered]@{
            From = $From
            To = $To
        }
        Attachments = [ordered]@{
            RootFolder = (Split-Path -Parent $AttachmentFolder)
            Subfolder = (Split-Path -Leaf $AttachmentFolder)
        }
        MinAttachmentsPerEmail = 1
        MaxAttachmentsPerEmail = 1
        EmailsPerHour = 120
        MaxParallelSends = 1
        EmailCount = 1
        TestTimeMinutes = 0
        PercentToAllRecipients = 100
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
        Process = $proc
        ExpectedSubject = '{0}-1' -f $subjectPrefix
        SubjectPrefix = $subjectPrefix
        StdoutFile = $stdoutFile
        StderrFile = $stderrFile
    }
}

function Get-Ma01BulkSendFailureHints {
    param(
        [string] $FailureDetail = '',
        [string] $StderrText = ''
    )

    $blob = ($FailureDetail + ' ' + $StderrText).ToLowerInvariant()
    $hints = New-Object System.Collections.Generic.List[string]

    $hints.Add('SendBulkAttachmentMail submits to the mail agent inbound SMTP (see stderr host/port), not to SimpleMailServer.')
    $hints.Add('The mail agent may still deliver outbound to the policy next hop on port 26 after this failure; check the mail agent log and simple-mail-server-status.json.')

    if ($blob -match '451|service unavailable|try again later') {
        $hints.Add('Expected MA-01 / NCP-7307: Core commdown while the inbound session was still open; mail agent returns 451 (retry) instead of 554. Outbound to port 26 may still complete after staging.')
        $hints.Add('Check mail agent log for SMTP_REJECT_STAGE=CoreUnavailable and Message successfully sent on the policy next hop.')
    }
    elseif ($blob -match '554|taskcanceled|canceled|cancelled|disconnected|session') {
        $hints.Add('Likely MA-01 / NCP-7307: Core commdown while the inbound session was still open (policy Send Immediate Response off). Mail agent may reject with 554 when Core drops mid-processing—not because port 26 is down.')
        $hints.Add('Check mail agent log for DISCONNECTED from Resec Core, SanitizationOutputCleanup, and SMTP_REJECT_STAGE=MessageActionException near the failure time.')
    }
    elseif ($blob -match '421|service not available|closing connection') {
        $hints.Add('Likely temporary SMTP 421 from the mail agent (often next-hop or internal queue pressure during outbound).')
        $hints.Add('Confirm SimpleMailServer --cli on 127.0.0.1:26 stayed up for the full inbound session (this script starts it unless -SkipStartSimpleMailServer).')
    }
    else {
        $hints.Add('Common causes: (1) Core commdown during an open inbound session (554 / canceled processing); (2) next hop on port 26 unreachable (421); (3) SimpleMailServer stopped during the send.')
        $hints.Add('Mail agent log: GET http://127.0.0.1:4505/debug/hook?command=logpath (when debug enabled).')
    }

    return $hints
}

function Test-Ma01ExpectedCommdownInbound451 {
    param(
        [string] $FailureDetail = '',
        [string] $StderrText = '',
        [string] $StdoutText = ''
    )

    $blob = ($FailureDetail + ' ' + $StderrText + ' ' + $StdoutText).ToLowerInvariant()
    return ($blob -match '451') -or ($blob -match 'service unavailable') -or ($blob -match 'try again later')
}

function Complete-BulkSendOnce {
    param(
        [hashtable] $BulkJob,
        [int] $WaitExitTimeoutSec = 180,
        [switch] $AllowExpectedCommdown451
    )

    $proc = $BulkJob.Process
    if (-not $proc.WaitForExit($WaitExitTimeoutSec * 1000)) {
        throw "SendBulkAttachmentMail did not exit within ${WaitExitTimeoutSec}s (PID $($proc.Id))."
    }

    $exitCode = $proc.ExitCode
    $stdoutFile = $BulkJob.StdoutFile
    $stderrFile = $BulkJob.StderrFile
    $stdoutText = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { '' }

    $report = $null
    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        try {
            $report = $stdoutText.Trim() | ConvertFrom-Json
        }
        catch {
            $report = $null
        }
    }

    if ($null -eq $exitCode) {
        $exitCode = -1
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
        if ($AllowExpectedCommdown451 -and (Test-Ma01ExpectedCommdownInbound451 -FailureDetail $detail -StderrText $stderrText -StdoutText $stdoutText)) {
            Write-TestStep 'SendBulk exited non-zero with inbound 451 (expected during Core commdown on open session); continuing to outbound delivery assert.'
            if ($null -ne $report) {
                return $report
            }

            return @{
                subjectPrefix = $BulkJob.SubjectPrefix
                failedMessages = @(@{ detail = $detail })
            }
        }

        foreach ($hint in @(Get-Ma01BulkSendFailureHints -FailureDetail $detail -StderrText $stderrText)) {
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
        $bulkReport = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec -AllowExpectedCommdown451
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
        TestId = 'MA-01-Short'
        TestTitle = 'NCP-7307 short disconnect (10s) outbound delivery'
        Label = 'Short disconnect / reconnect'
        CommDownHoldSeconds = $ShortCommDownHoldSeconds
        ReconnectTimeoutSec = $ShortReconnectTimeoutSec
    },
    @{
        Key = 'Long'
        TestId = 'MA-01-Long'
        TestTitle = 'NCP-7307 long disconnect (30s+) outbound delivery'
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

    Write-TestStep 'Waiting for mail agent debug readiness.'
    $agentStatus = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort
    Write-TestStep ("Mail agent: {0}" -f (Format-MailAgentDebugStatusSummary -Status $agentStatus))
    Initialize-MailAgentE2eComponentVersionFromDebug -BaseUrl $MailAgentDebugBaseUrl

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
}
catch {
    $script:OverallPassed = $false
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    if ($simpleMailStartedByScript -and $simpleMailProcess -and -not $simpleMailProcess.HasExited) {
        try {
            Stop-Process -Id $simpleMailProcess.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    if (-not $script:OverallPassed) {
        exit 1
    }
}
