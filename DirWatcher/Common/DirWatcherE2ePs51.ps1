#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:DirWatcherE2eCachedExePath = $null
$script:DirWatcherE2eManagedByScenario = $false

function Register-DirWatcherE2eExePath {
    param([string] $ExePath)

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        return
    }

    $full = [System.IO.Path]::GetFullPath($ExePath.Trim())
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $script:DirWatcherE2eCachedExePath = $full
    }
}

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
        Register-DirWatcherE2eExePath -ExePath $full
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LAB_DIRWATCHER_EXE)) {
        $full = [System.IO.Path]::GetFullPath($env:LAB_DIRWATCHER_EXE.Trim())
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Register-DirWatcherE2eExePath -ExePath $full
            return $full
        }
    }

    $optional = $null
    if (Get-Command Get-LabOptionalPath -ErrorAction SilentlyContinue) {
        $optional = Get-LabOptionalPath -SettingName 'dirWatcherExe' -EnvironmentVariable 'LAB_DIRWATCHER_EXE'
    }
    if (-not [string]::IsNullOrWhiteSpace($optional) -and (Test-Path -LiteralPath $optional -PathType Leaf)) {
        Register-DirWatcherE2eExePath -ExePath $optional
        return $optional
    }

    $candidates = @(
        'C:\Program Files\Resec Technologies\Resec Directory Watcher\DirWatcher.exe',
        'C:\Program Files\Resec Technologies\Resec Directory Watcher\Resec.Agent.DirWatcher.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Register-DirWatcherE2eExePath -ExePath $candidate
            return $candidate
        }
    }

    $runningExe = Get-DirWatcherE2eRunningExePath
    if (-not [string]::IsNullOrWhiteSpace($runningExe)) {
        Register-DirWatcherE2eExePath -ExePath $runningExe
        return $runningExe
    }

    if (-not [string]::IsNullOrWhiteSpace($script:DirWatcherE2eCachedExePath)) {
        $cached = [System.IO.Path]::GetFullPath($script:DirWatcherE2eCachedExePath)
        if (Test-Path -LiteralPath $cached -PathType Leaf) {
            return $cached
        }
    }

    throw 'DirWatcher exe not found. Pass -DirWatcherExe or set LAB_DIRWATCHER_EXE.'
}

function Stop-DirWatcherE2eProcesses {
    foreach ($name in @('DirWatcher', 'Resec.Agent.DirWatcher')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue
                if ($null -ne $proc -and -not [string]::IsNullOrWhiteSpace($proc.ExecutablePath)) {
                    Register-DirWatcherE2eExePath -ExePath $proc.ExecutablePath
                }
            }
            catch {
                # optional
            }

            Write-DwTestStep "Stopping process $($_.ProcessName) (pid $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

function Stop-DirWatcherE2eProcessesForScenarioTeardown {
    param(
        [switch] $LeaveRunning
    )

    if ($LeaveRunning) {
        Write-DwTestStep 'Teardown: leaving DirWatcher running (-LeaveDirWatcherRunning)'
        return
    }

    if (-not $script:DirWatcherE2eManagedByScenario) {
        Write-DwTestStep 'Teardown: DirWatcher was already running before this scenario; not stopping'
        return
    }

    if (-not (Test-DirWatcherE2eProcessRunning)) {
        $script:DirWatcherE2eManagedByScenario = $false
        return
    }

    Write-DwTestStep 'Teardown: stopping DirWatcher started for this scenario'
    Stop-DirWatcherE2eProcesses
    $script:DirWatcherE2eManagedByScenario = $false
}

function Start-DirWatcherE2eProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $full = Resolve-DirWatcherE2eExePath -Override $ExePath
    Write-DwTestStep "Starting DirWatcher: $full"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $full
    $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($full)
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['DIRWATCHER_ENABLE_DEBUG_INTERFACE'] = 'true'
    [void][System.Diagnostics.Process]::Start($psi)
    $script:DirWatcherE2eManagedByScenario = $true
}

function Test-DirWatcherE2eProcessRunning {
    foreach ($name in @('DirWatcher', 'Resec.Agent.DirWatcher')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Set-DirWatcherE2eComponentVersionFromExe {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    try {
        $ver = (Get-Item -LiteralPath $ExePath).VersionInfo.ProductVersion
        Register-DirWatcherE2eExePath -ExePath $ExePath
        if (-not [string]::IsNullOrWhiteSpace($ver)) {
            $env:DIRWATCHER_COMPONENT_VERSION = $ver
            Write-DwTestStep "DirWatcher version: $ver"
        }
    }
    catch {
        # optional
    }
}

function Ensure-DirWatcherE2eProcessRunning {
    param(
        [string] $DirWatcherExe = '',
        [int] $StartupSettleSec = 5
    )

    if (Test-DirWatcherE2eProcessRunning) {
        $runningExe = Get-DirWatcherE2eRunningExePath
        if (-not [string]::IsNullOrWhiteSpace($runningExe)) {
            Set-DirWatcherE2eComponentVersionFromExe -ExePath $runningExe
        }
        return
    }

    $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
    Write-DwTestStep 'DirWatcher is not running; starting it for this test'
    Start-DirWatcherE2eProcess -ExePath $dwExe
    if ($StartupSettleSec -gt 0) {
        Start-Sleep -Seconds $StartupSettleSec
    }
    if (-not (Test-DirWatcherE2eProcessRunning)) {
        throw 'DirWatcher failed to start. Pass -DirWatcherExe or set LAB_DIRWATCHER_EXE to the deployed build.'
    }

    Set-DirWatcherE2eComponentVersionFromExe -ExePath $dwExe
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

function Wait-DirWatcherE2ePathAbsent {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [int] $TimeoutSec = 60,
        [int] $PollMs = 500
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (-not (Test-Path -LiteralPath $full)) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

function Wait-DirWatcherE2eCleanOutputDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [Parameter(Mandatory)]
        [string] $DirectoryName,
        [int] $TimeoutSec = 120,
        [int] $PollMs = 500
    )

    $cleanFull = [System.IO.Path]::GetFullPath($CleanRoot)
    $expectedName = [System.IO.Path]::GetFileName($DirectoryName.TrimEnd('\', '/'))
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $cleanFull -PathType Container) {
            $match = Get-ChildItem -LiteralPath $cleanFull -Directory -Recurse -Force -ErrorAction SilentlyContinue |
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

function Wait-DirWatcherE2ePathPresent {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [int] $TimeoutSec = 5,
        [int] $PollMs = 250
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $full) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

function Wait-DirWatcherE2eIncomingFolderDeletedByPolicy {
    <#
    .SYNOPSIS
      Waits until an incoming folder is removed by DW periodic cleanup (Delete processed folders after X minutes).
    .DESCRIPTION
      Deletion runs on periodic file check (default interval 1 min) after the policy age threshold.
      Waits until policy threshold plus one minute of slack (covers one missed periodic tick).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $IncomingFolderPath,
        [Parameter(Mandatory)]
        [datetime] $FolderCreatedAtLocal,
        [Parameter(Mandatory)]
        [int] $DeleteAfterMinutes,
        [int] $ExtraSlackAfterPolicyMinutes = 1,
        [int] $PollMs = 500
    )

    if ($DeleteAfterMinutes -le 0) {
        throw 'DeleteAfterMinutes must be positive for delete-by-policy wait.'
    }

    $eligibleAt = $FolderCreatedAtLocal.AddMinutes($DeleteAfterMinutes)
    $deadline = $eligibleAt.AddMinutes($ExtraSlackAfterPolicyMinutes)
    $full = [System.IO.Path]::GetFullPath($IncomingFolderPath)

    while ([datetime]::Now -lt $deadline) {
        if (-not (Test-Path -LiteralPath $full)) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    # Folder may be removed on the same second as the deadline (periodic tick alignment).
    return -not (Test-Path -LiteralPath $full)
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

function Test-DirWatcherE2eLogShowsMonitoringIncoming {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [datetime] $NotBeforeLocal = [datetime]::MinValue,
        [string] $DebugBaseUrl = ''
    )

    $incomingFull = [System.IO.Path]::GetFullPath($IncomingRoot)
    $incomingKey = Normalize-DirWatcherE2ePathKey -Path $incomingFull

    $logFilePath = $null
    if (Get-Command Get-DirWatcherE2eDebugLogPathEvidence -ErrorAction SilentlyContinue) {
        foreach ($p in Get-DirWatcherE2eDebugLogPathEvidence -BaseUrl $DebugBaseUrl) {
            if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Leaf)) {
                $logFilePath = $p
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($logFilePath)) {
        $logDir = Get-DirWatcherE2eLogDirectory
        if (-not [string]::IsNullOrWhiteSpace($logDir)) {
            $logFile = Get-ChildItem -LiteralPath $logDir -Filter 'log-DirWatcher-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($null -ne $logFile) {
                $logFilePath = $logFile.FullName
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($logFilePath)) {
        return $false
    }

    $tail = Get-Content -LiteralPath $logFilePath -Tail 600 -ErrorAction SilentlyContinue
    foreach ($line in @($tail)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        $lineText = [string]$line
        $pathHit = ($lineText.IndexOf($incomingKey, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $pathHit) {
            continue
        }

        if ($lineText -notmatch 'Monitoring folder:|Root folder:|DEBUG: E2E logmark:') {
            continue
        }

        if ($NotBeforeLocal -ne [datetime]::MinValue) {
            $timeOk = $false
            if ($lineText -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $loggedAt = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
                $timeOk = ($loggedAt -ge $NotBeforeLocal.AddSeconds(-3))
            }
            elseif ($lineText -match '(\d{1,2}:\d{2}:\d{2}):') {
                $today = Get-Date -Format 'yyyy-MM-dd'
                $loggedAt = [datetime]::ParseExact(('{0} {1}' -f $today, $matches[1]), 'yyyy-MM-dd H:mm:ss', $null)
                $timeOk = ($loggedAt -ge $NotBeforeLocal.AddSeconds(-3))
            }
            else {
                $timeOk = $true
            }

            if (-not $timeOk) {
                continue
            }
        }

        return $true
    }

    return $false
}

function Wait-DirWatcherE2eMonitoringIncoming {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [int] $TimeoutSec = 60,
        [int] $PollMs = 500,
        [datetime] $NotBeforeLocal = [datetime]::MinValue,
        [string] $DebugBaseUrl = ''
    )

    $incomingFull = [System.IO.Path]::GetFullPath($IncomingRoot)
    Write-DirWatcherE2eDebugLogMark -Message "Wait-DirWatcherE2eMonitoringIncoming $incomingFull" -BaseUrl $DebugBaseUrl

    if (Test-DirWatcherE2eDebugHookReachable -BaseUrl $DebugBaseUrl) {
        Write-DwTestStep "DirWatcher debug hook reachable; waiting connection.state for monitoring $incomingFull"
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
        $lastStatus = $null
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            try {
                $status = Invoke-DirWatcherE2eDebugHook -Command 'connection.state' -BaseUrl $DebugBaseUrl
                if ($null -ne $status) {
                    $lastStatus = $status
                }
            }
            catch {
                # keep last successful connection.state snapshot
            }

            if ($null -ne $lastStatus) {
                try {
                    if (Test-DirWatcherE2eDebugMonitoringIncoming -IncomingRoot $incomingFull -BaseUrl $DebugBaseUrl -Status $lastStatus) {
                        Write-DwTestStep "DirWatcher debug confirms monitoring: $incomingFull"
                        Write-DirWatcherE2eDebugLogMark -Message "Monitoring ready $incomingFull" -BaseUrl $DebugBaseUrl
                        return $true
                    }
                }
                catch {
                    # keep polling
                }
            }

            try {
                if (Test-DirWatcherE2eLogShowsMonitoringIncoming -IncomingRoot $incomingFull -NotBeforeLocal $NotBeforeLocal -DebugBaseUrl $DebugBaseUrl) {
                    Write-DwTestStep "DirWatcher log confirms monitoring (debug state still catching up): $incomingFull"
                    Write-DirWatcherE2eDebugLogMark -Message "Monitoring ready $incomingFull" -BaseUrl $DebugBaseUrl
                    return $true
                }
            }
            catch {
                # optional log tail
            }

            Start-Sleep -Milliseconds $PollMs
        }

        $detail = Format-DirWatcherE2eDebugConnectionSummary -Status $lastStatus
        throw "Timed out waiting for DirWatcher debug connection.state (monitoring $incomingFull within ${TimeoutSec}s). Last: $detail"
    }

    Write-DwTestStep 'DirWatcher debug hook not reachable; falling back to log tail for Monitoring folder:'
    $logDir = Get-DirWatcherE2eLogDirectory
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        Write-DwTestStep "DirWatcher log dir not found; waiting ${TimeoutSec}s after restart without log check"
        Start-Sleep -Seconds ([Math]::Min($TimeoutSec, 15))
        return $true
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Test-DirWatcherE2eLogShowsMonitoringIncoming -IncomingRoot $incomingFull -NotBeforeLocal $NotBeforeLocal -DebugBaseUrl $DebugBaseUrl) {
            Write-DwTestStep "DirWatcher log confirms monitoring: $incomingFull"
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    throw "Timed out waiting for DirWatcher log to show monitoring incoming folder: $incomingFull"
}
