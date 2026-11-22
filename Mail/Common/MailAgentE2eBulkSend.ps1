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
    Write-Host ''
    Write-Host 'Set tool paths (session):'
    Write-Host "  . $(Join-Path $commonRoot 'Initialize-MailAgentE2eToolPaths.ps1')"
    Write-Host ''
    Write-Host 'Or set MAIL_E2E_SIMPLE_MAIL_SERVER_EXE / MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE, or pass explicit -Path parameters.'
    Write-Host 'Typical build outputs:'
    Write-Host "  $(Join-Path $labTestsRoot 'Tools\SimpleMailServer\bin\x64\Debug\net10.0-windows7.0\win-x64\SimpleMailServer.exe')"
    Write-Host "  $(Join-Path $repoRoot 'SendBulkAttachmentMail\bin\Debug\net10.0-windows7.0\win-x64\SendBulkAttachmentMail.exe')"
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
        [int] $EmailCount = 1
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
        EmailsPerHour            = 120
        MaxParallelSends         = 1
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

    $stdoutFile = $BulkJob.StdoutFile
    $stderrFile = $BulkJob.StderrFile
    $stdoutText = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile) } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrFile) { [System.IO.File]::ReadAllText($stderrFile) } else { '' }
    $combined = ($stdoutText + ' ' + $stderrText)

    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) {
        $exitCode = -1
    }

    if ($exitCode -eq 0) {
        throw "Expected inbound SMTP failure (non-zero exit) for blocked/infected fixture, but SendBulk exited 0."
    }

    if ($RequireSmtp5xx -and ($combined -notmatch '\b5\d{2}\b')) {
        throw "Expected SMTP 5xx response in SendBulk output; exit=$exitCode output: $combined"
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

function Test-CapturedEmlContainsResecSignature {
    param([Parameter(Mandatory)][string] $EmlPath)

    if (-not (Test-Path -LiteralPath $EmlPath)) {
        return $false
    }

    $text = [System.IO.File]::ReadAllText($EmlPath)
    return ($text -match '(?i)ReSecure|resec')
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