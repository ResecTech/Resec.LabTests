#Requires -Version 5.1
<#
.SYNOPSIS
  Local SMTP capture for Core job notification E2E (SimpleMailServer --cli).
.NOTES
  Reuses Mail Agent E2E SimpleMailServer helpers. Set MAIL_E2E_SIMPLE_MAIL_SERVER_EXE or pass -SimpleMailServerPath.
#>
Set-StrictMode -Version Latest

function Get-CoreE2eEmlSubjectLine {
    param([Parameter(Mandatory)][string] $EmlPath)

    if (-not (Test-Path -LiteralPath $EmlPath -PathType Leaf)) {
        return $null
    }

    foreach ($line in [System.IO.File]::ReadLines($EmlPath)) {
        if ($line -match '^Subject:\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Get-CoreE2eSimpleMailServerStatusSnapshot {
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

function Resolve-CoreE2eCapturedMailArtifact {
    param(
        $StatusJson,
        [string] $CaptureFolder,
        [hashtable] $ExcludeCaptureFiles
    )

    if ($null -eq $ExcludeCaptureFiles) {
        $ExcludeCaptureFiles = @{}
    }

    $subject = [string]$StatusJson.lastSubject
    $savedPath = [string]$StatusJson.lastSavedFilePath
    if ([string]::IsNullOrWhiteSpace($subject) -and -not [string]::IsNullOrWhiteSpace($savedPath)) {
        $subject = Get-CoreE2eEmlSubjectLine -EmlPath $savedPath
    }

    if (-not [string]::IsNullOrWhiteSpace($subject) -and -not [string]::IsNullOrWhiteSpace($savedPath)) {
        return @{ Subject = $subject; SavedFilePath = $savedPath }
    }

    if ([string]::IsNullOrWhiteSpace($CaptureFolder) -or -not (Test-Path -LiteralPath $CaptureFolder)) {
        return $null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $CaptureFolder -Filter '*.eml' -File -Force -ErrorAction SilentlyContinue)) {
        if ($ExcludeCaptureFiles.ContainsKey($file.FullName)) {
            continue
        }

        $fromFile = Get-CoreE2eEmlSubjectLine -EmlPath $file.FullName
        if (-not [string]::IsNullOrWhiteSpace($fromFile)) {
            return @{ Subject = $fromFile; SavedFilePath = $file.FullName }
        }
    }

    return $null
}

function Wait-CoreE2eCapturedSmtpMessage {
    param(
        [Parameter(Mandatory)]
        [string] $StatusPath,
        [Parameter(Mandatory)]
        [string] $CaptureFolder,
        [int] $MinMessageCount = 0,
        [int] $TimeoutSec = 120,
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
                $resolved = Resolve-CoreE2eCapturedMailArtifact -StatusJson $json -CaptureFolder $CaptureFolder `
                    -ExcludeCaptureFiles $ExcludeCaptureFiles
                if ($null -ne $resolved) {
                    $body = $null
                    if (Test-Path -LiteralPath $resolved.SavedFilePath -PathType Leaf) {
                        $body = [System.IO.File]::ReadAllText($resolved.SavedFilePath)
                    }

                    return [pscustomobject]@{
                        Subject       = $resolved.Subject
                        SavedFilePath = $resolved.SavedFilePath
                        Body          = $body
                        MessageCount  = [int]$json.messageCount
                    }
                }
            }
        }

        $folderHit = Resolve-CoreE2eCapturedMailArtifact -StatusJson @{} -CaptureFolder $CaptureFolder `
            -ExcludeCaptureFiles $ExcludeCaptureFiles
        if ($null -ne $folderHit) {
            $body = $null
            if (Test-Path -LiteralPath $folderHit.SavedFilePath -PathType Leaf) {
                $body = [System.IO.File]::ReadAllText($folderHit.SavedFilePath)
            }

            return [pscustomobject]@{
                Subject       = $folderHit.Subject
                SavedFilePath = $folderHit.SavedFilePath
                Body          = $body
                MessageCount  = ($MinMessageCount + 1)
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "No SMTP message captured within ${TimeoutSec}s (status=$StatusPath, folder=$CaptureFolder)."
}

function Start-CoreE2eSmtpCapture {
    <#
    .OUTPUTS
      Hashtable: StatusPath, CaptureFolder, BaselineMessageCount, Process (may be null if -SkipStart),
      StartedByScript, SimpleMailServerExe, ListenHost, Port
    #>
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $SimpleMailServerPath = '',
        [string] $ListenHost = '127.0.0.1',
        [int] $Port = 2525,
        [string] $CaptureRoot = '',
        [switch] $SkipStart
    )

    $mailCommon = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Mail\Common'))
    . (Join-Path $mailCommon 'MailAgentE2ePaths.ps1')
    . (Join-Path $mailCommon 'MailAgentE2eSimpleMailServer.ps1')

    $smsExe = Resolve-SimpleMailServerPath -CallingScriptRoot $CallingScriptRoot -Path $SimpleMailServerPath
    if ([string]::IsNullOrWhiteSpace($smsExe)) {
        throw @(
            'SimpleMailServer.exe not found. Build Resec.LabTests\Tools\SimpleMailServer, set MAIL_E2E_SIMPLE_MAIL_SERVER_EXE,'
            'or pass -SimpleMailServerPath. See Mail\Common\README.md.'
        ) -join ' '
    }

    $mailConfigRoot = Join-Path (Split-Path $mailCommon -Parent) 'Config'
    $smsConfig = Join-Path $mailConfigRoot 'simple-mail-server.appsettings.json'
    if (-not (Test-Path -LiteralPath $smsConfig)) {
        throw "SimpleMailServer config not found: $smsConfig"
    }

    if ([string]::IsNullOrWhiteSpace($CaptureRoot)) {
        $CaptureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-SmtpCapture-' + [Guid]::NewGuid().ToString('N'))
    }

    $captureFolder = [System.IO.Path]::GetFullPath($CaptureRoot)
    New-Item -ItemType Directory -Path $captureFolder -Force | Out-Null
    $statusPath = Join-Path $captureFolder 'simple-mail-server-status.json'

    $baseline = (Get-CoreE2eSimpleMailServerStatusSnapshot -StatusPath $statusPath).MessageCount
    $process = $null
    $startedByScript = $false

    if (-not $SkipStart) {
        $ensure = Ensure-MailAgentE2eSimpleMailServerHeadless `
            -SimpleMailServerExe $smsExe `
            -ConfigPath $smsConfig `
            -ListenHost $ListenHost `
            -Port $Port `
            -SaveFolder $captureFolder `
            -StatusFilePath $statusPath `
            -ResponseDelaySeconds 0 `
            -SkipStart:$false

        $process = $ensure.Process
        $startedByScript = $ensure.StartedByScript
    }
    else {
        Assert-MailAgentE2eSimpleMailServerListening `
            -ListenHost $ListenHost `
            -Port $Port `
            -SimpleMailServerExe $smsExe `
            -ConfigPath $smsConfig `
            -SaveFolder $captureFolder `
            -StatusFilePath $statusPath `
            -ResponseDelaySeconds 0 | Out-Null
    }

    $excludeFiles = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $captureFolder -Filter '*.eml' -File -Force -ErrorAction SilentlyContinue)) {
        $excludeFiles[$file.FullName] = $true
    }

    return @{
        StatusPath            = $statusPath
        CaptureFolder         = $captureFolder
        BaselineMessageCount  = $baseline
        ExcludeCaptureFiles   = $excludeFiles
        Process               = $process
        StartedByScript       = $startedByScript
        SimpleMailServerExe   = $smsExe
        ListenHost            = $ListenHost
        Port                  = $Port
    }
}

function Stop-CoreE2eSmtpCapture {
    param(
        $CaptureSession
    )

    if ($null -eq $CaptureSession) {
        return
    }

    $proc = $CaptureSession.Process
    if ($CaptureSession.StartedByScript -and $null -ne $proc -and -not $proc.HasExited) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not stop SimpleMailServer (PID $($proc.Id)): $($_.Exception.Message)"
        }
    }
}
