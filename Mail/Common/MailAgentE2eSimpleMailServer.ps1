#Requires -Version 5.1
Set-StrictMode -Version Latest

function Test-MailAgentE2ePortListening {
    param(
        [string] $HostName = '127.0.0.1',
        [Parameter(Mandatory)]
        [int] $Port,
        [int] $TimeoutMs = 800
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return $false
        }
        $client.EndConnect($connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-MailAgentE2eTcpListenerProcessId {
    param(
        [Parameter(Mandatory)]
        [int] $Port
    )

    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $conn) {
            return $null
        }
        return [int]$conn.OwningProcess
    }
    catch {
        return $null
    }
}

function Get-MailAgentE2eProcessImageFileName {
    param([int] $ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    try {
        return (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName
    }
    catch {
        return $null
    }
}

function Wait-MailAgentE2ePortListening {
    param(
        [string] $HostName = '127.0.0.1',
        [Parameter(Mandatory)]
        [int] $Port,
        [int] $TimeoutSec = 20,
        [int] $PollMs = 250
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-MailAgentE2ePortListening -HostName $HostName -Port $Port) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

function New-MailAgentE2eSimpleMailServerNotListeningMessage {
    param(
        [string] $HostName,
        [int] $Port,
        [string] $SimpleMailServerExe,
        [string] $ConfigPath,
        [string] $SaveFolder,
        [double] $DelaySeconds,
        [string] $StatusFile,
        [switch] $SkipStartRequested
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("SimpleMailServer (headless) is not accepting TCP connections on ${HostName}:$Port.")
    $lines.Add('')
    $lines.Add('The mail agent policy next hop must reach this capture SMTP server before inbound mail is sent.')
    $lines.Add('If the listener is down, sanitization can finish but outbound delivery fails and the inbound SMTP client may see 421.')
    $lines.Add('')
    if ($SkipStartRequested) {
        $lines.Add('This script was run with -SkipStartSimpleMailServer but nothing is listening on that port.')
    }
    else {
        $lines.Add('The script tried to start SimpleMailServer.exe --cli but the port did not become ready in time.')
    }
    $lines.Add('')
    $lines.Add('Start manually (example):')
    $lines.Add("  `"$SimpleMailServerExe`" --cli --config `"$ConfigPath`" --port $Port --response-delay $DelaySeconds --save-folder `"$SaveFolder`" --save-incoming --status-file `"$StatusFile`"")
    $lines.Add('')
    $lines.Add('Or run MA-01 without -SkipStartSimpleMailServer (default).')
    return ($lines -join [Environment]::NewLine)
}

function New-MailAgentE2eSimpleMailServerWrongProcessMessage {
    param(
        [int] $Port,
        [int] $ProcessId,
        [string] $ProcessName
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("TCP port $Port is already in use by another process (PID $ProcessId, name '$ProcessName'), not SimpleMailServer.")
    $lines.Add('Stop that listener or choose a different -SimpleMailPort aligned with the mail agent policy next hop.')
    return ($lines -join [Environment]::NewLine)
}

function Ensure-MailAgentE2eSimpleMailServerHeadless {
    <#
    .SYNOPSIS
      Ensures SimpleMailServer.exe --cli is listening on the capture port before inbound mail is sent.
    .OUTPUTS
      Hashtable: Process (nullable), StartedByScript (bool)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SimpleMailServerExe,
        [Parameter(Mandatory)]
        [string] $ConfigPath,
        [Parameter(Mandatory)]
        [int] $Port,
        [double] $ResponseDelaySeconds,
        [Parameter(Mandatory)]
        [string] $SaveFolder,
        [Parameter(Mandatory)]
        [string] $StatusFilePath,
        [string] $ListenHost = '127.0.0.1',
        [int] $StartupTimeoutSec = 20,
        [switch] $SkipStart,
        [switch] $WipeSaveFolder
    )

    $expectedProcessName = 'SimpleMailServer'
    $listening = Test-MailAgentE2ePortListening -HostName $ListenHost -Port $Port
    $listenerPid = $null
    if ($listening) {
        $listenerPid = Get-MailAgentE2eTcpListenerProcessId -Port $Port
        $imageName = Get-MailAgentE2eProcessImageFileName -ProcessId $listenerPid
        if ($null -ne $imageName -and -not $imageName.Equals($expectedProcessName, [StringComparison]::OrdinalIgnoreCase)) {
            throw (New-MailAgentE2eSimpleMailServerWrongProcessMessage -Port $Port -ProcessId $listenerPid -ProcessName $imageName)
        }

        if ($SkipStart) {
            return @{ Process = $null; StartedByScript = $false }
        }

        if ($null -ne $imageName -and $imageName.Equals($expectedProcessName, [StringComparison]::OrdinalIgnoreCase)) {
            return @{ Process = $null; StartedByScript = $false }
        }

        # Port open but owning process unknown — treat as OK for connect test only.
        return @{ Process = $null; StartedByScript = $false }
    }

    if ($SkipStart) {
        throw (New-MailAgentE2eSimpleMailServerNotListeningMessage -HostName $ListenHost -Port $Port `
                -SimpleMailServerExe $SimpleMailServerExe -ConfigPath $ConfigPath -SaveFolder $SaveFolder `
                -DelaySeconds $ResponseDelaySeconds -StatusFile $StatusFilePath -SkipStartRequested)
    }

    [System.IO.Directory]::CreateDirectory($SaveFolder) | Out-Null

    $args = @(
        '--cli',
        '--config', $ConfigPath,
        '--port', $Port,
        '--response-delay', $ResponseDelaySeconds,
        '--save-folder', $SaveFolder,
        '--save-incoming',
        '--status-file', $StatusFilePath
    )
    if ($WipeSaveFolder) {
        $args += '--wipe-save-folder'
    }

    $proc = Start-Process -FilePath $SimpleMailServerExe -ArgumentList $args -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) {
        throw "SimpleMailServer.exe --cli exited immediately (exit code $($proc.ExitCode)). Check console output by running the same command in an interactive shell."
    }

    if (-not (Wait-MailAgentE2ePortListening -HostName $ListenHost -Port $Port -TimeoutSec $StartupTimeoutSec)) {
        try {
            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }

        throw (New-MailAgentE2eSimpleMailServerNotListeningMessage -HostName $ListenHost -Port $Port `
                -SimpleMailServerExe $SimpleMailServerExe -ConfigPath $ConfigPath -SaveFolder $SaveFolder `
                -DelaySeconds $ResponseDelaySeconds -StatusFile $StatusFilePath)
    }

    return @{ Process = $proc; StartedByScript = $true }
}

function Assert-MailAgentE2eSimpleMailServerListening {
    param(
        [string] $ListenHost = '127.0.0.1',
        [Parameter(Mandatory)]
        [int] $Port,
        [Parameter(Mandatory)]
        [string] $SimpleMailServerExe,
        [Parameter(Mandatory)]
        [string] $ConfigPath,
        [Parameter(Mandatory)]
        [string] $SaveFolder,
        [double] $ResponseDelaySeconds,
        [Parameter(Mandatory)]
        [string] $StatusFilePath
    )

    if (Test-MailAgentE2ePortListening -HostName $ListenHost -Port $Port) {
        return
    }

    throw (New-MailAgentE2eSimpleMailServerNotListeningMessage -HostName $ListenHost -Port $Port `
            -SimpleMailServerExe $SimpleMailServerExe -ConfigPath $ConfigPath -SaveFolder $SaveFolder `
            -DelaySeconds $ResponseDelaySeconds -StatusFile $StatusFilePath -SkipStartRequested)
}
