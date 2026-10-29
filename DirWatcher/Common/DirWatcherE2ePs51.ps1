#Requires -Version 5.1
Set-StrictMode -Version Latest

function Write-DwTestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-DirWatcherE2eRunningExePath {
    foreach ($procName in @('DirWatcher.exe', 'Resec.Agent.DirWatcher.exe')) {
        $proc = Get-CimInstance Win32_Process -Filter "Name='$procName'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $proc -or [string]::IsNullOrWhiteSpace($proc.ExecutablePath)) {
            continue
        }

        $exe = [System.IO.Path]::GetFullPath($proc.ExecutablePath.Trim())
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            return $exe
        }
    }

    return $null
}

function Resolve-DirWatcherE2eExePath {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $full = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "DirWatcher exe not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LAB_DIRWATCHER_EXE)) {
        $full = [System.IO.Path]::GetFullPath($env:LAB_DIRWATCHER_EXE.Trim())
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }

    $optional = $null
    if (Get-Command Get-LabOptionalPath -ErrorAction SilentlyContinue) {
        $optional = Get-LabOptionalPath -SettingName 'dirWatcherExe' -EnvironmentVariable 'LAB_DIRWATCHER_EXE'
    }
    if (-not [string]::IsNullOrWhiteSpace($optional) -and (Test-Path -LiteralPath $optional -PathType Leaf)) {
        return $optional
    }

    $candidates = @(
        'C:\Program Files\Resec Technologies\Resec Directory Watcher\DirWatcher.exe',
        'C:\Program Files\Resec Technologies\Resec Directory Watcher\Resec.Agent.DirWatcher.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $runningExe = Get-DirWatcherE2eRunningExePath
    if (-not [string]::IsNullOrWhiteSpace($runningExe)) {
        return $runningExe
    }

    throw 'DirWatcher exe not found. Pass -DirWatcherExe or set LAB_DIRWATCHER_EXE.'
}

function Stop-DirWatcherE2eProcesses {
    foreach ($name in @('DirWatcher', 'Resec.Agent.DirWatcher')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            Write-DwTestStep "Stopping process $($_.ProcessName) (pid $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Start-DirWatcherE2eProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $full = Resolve-DirWatcherE2eExePath -Override $ExePath
    Write-DwTestStep "Starting DirWatcher: $full"
    Start-Process -FilePath $full -WorkingDirectory ([System.IO.Path]::GetDirectoryName($full)) | Out-Null
}

function Test-DirWatcherE2eProcessRunning {
    foreach ($name in @('DirWatcher', 'Resec.Agent.DirWatcher')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Invoke-DirWatcherE2eAgentCommReconnectNudge {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $HoldSeconds = 2,
        [int] $SettleSeconds = 8
    )

    Write-DwTestStep 'agentcommblockon (force agents to reconnect after policy import)'
    $on = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockon'
    Assert-CoreE2eDebugHookResponse -Response $on -Step 'agentcommblockon'
    Start-Sleep -Seconds $HoldSeconds
    Write-DwTestStep 'agentcommblockoff'
    $off = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'agentcommblockoff'
    Assert-CoreE2eDebugHookResponse -Response $off -Step 'agentcommblockoff'
    if ($SettleSeconds -gt 0) {
        Start-Sleep -Seconds $SettleSeconds
    }
}

function Wait-DirWatcherE2eFileLeavesPath {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [int] $TimeoutSec = 10,
        [int] $PollMs = 250
    )

    $full = [System.IO.Path]::GetFullPath($FilePath)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

function Wait-DirWatcherE2eTempContainsCopy {
    param(
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [long] $ExpectedLength,
        [int] $TimeoutSec = 10,
        [int] $PollMs = 250
    )

    if ($TimeoutSec -le 0) {
        $PollMs = 0
    }

    $tempFull = [System.IO.Path]::GetFullPath($TempRoot)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max($TimeoutSec, 0))
    do {
        if (Test-Path -LiteralPath $tempFull -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $tempFull -File -Recurse -Force -ErrorAction SilentlyContinue)
            foreach ($f in $files) {
                if ($f.Length -eq $ExpectedLength) {
                    return $f.FullName
                }
            }
        }
        if ($TimeoutSec -le 0) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            break
        }
        Start-Sleep -Milliseconds $PollMs
    } while ($true)

    return $null
}

function Wait-DirWatcherE2eCleanOutput {
    param(
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [Parameter(Mandatory)]
        [string] $FileName,
        [int] $TimeoutSec = 10,
        [int] $PollMs = 500
    )

    $cleanFull = [System.IO.Path]::GetFullPath($CleanRoot)
    $expectedName = [System.IO.Path]::GetFileName($FileName)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $cleanFull -PathType Container) {
            $match = Get-ChildItem -LiteralPath $cleanFull -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $expectedName } |
                Select-Object -First 1
            if ($null -ne $match) {
                return $match.FullName
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $null
}

function New-DirWatcherE2eWorkLayout {
    param([string] $WorkRoot = '')

    if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
        $WorkRoot = Join-Path 'C:\test' ('DW-NCP7340-' + [Guid]::NewGuid().ToString('N'))
    }

    $root = [System.IO.Path]::GetFullPath($WorkRoot)
    $incoming = Join-Path $root 'incoming'
    $temp = Join-Path $root 'temp'
    $rejected = Join-Path $root 'rejected'
    $clean = Join-Path $root 'clean'

    foreach ($folder in @($incoming, $temp, $rejected, $clean)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }

    return [pscustomobject]@{
        WorkRoot = $root
        Incoming = $incoming
        Temp     = $temp
        Rejected = $rejected
        Clean    = $clean
    }
}

function Get-DirWatcherE2eLogDirectory {
    $candidates = @(
        'C:\Resec\Logs\Directory Watcher',
        'c:\resec\Logs\Directory Watcher'
    )
    if (-not [string]::IsNullOrWhiteSpace($env:DIRWATCHER_E2E_LOG_DIR)) {
        $candidates = @([System.IO.Path]::GetFullPath($env:DIRWATCHER_E2E_LOG_DIR.Trim())) + $candidates
    }

    foreach ($dir in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            return $dir
        }
    }

    return $null
}

function Wait-DirWatcherE2eMonitoringIncoming {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [int] $TimeoutSec = 60,
        [int] $PollMs = 500
    )

    $incomingFull = [System.IO.Path]::GetFullPath($IncomingRoot)
    $logDir = Get-DirWatcherE2eLogDirectory
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        Write-DwTestStep "DirWatcher log dir not found; waiting ${TimeoutSec}s after restart without log check"
        Start-Sleep -Seconds ([Math]::Min($TimeoutSec, 15))
        return $true
    }

    $needle = "Monitoring folder: $incomingFull"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $logFile = Get-ChildItem -LiteralPath $logDir -Filter 'log-DirWatcher-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $logFile) {
            $tail = Get-Content -LiteralPath $logFile.FullName -Tail 400 -ErrorAction SilentlyContinue
            if (@($tail | Where-Object { $_ -like "*$needle*" }).Count -gt 0) {
                Write-DwTestStep "DirWatcher log confirms monitoring: $incomingFull"
                return $true
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }

    throw "Timed out waiting for DirWatcher log to show monitoring incoming folder: $incomingFull"
}
