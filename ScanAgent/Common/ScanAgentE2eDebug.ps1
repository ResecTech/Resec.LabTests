#Requires -Version 5.1
<#
.SYNOPSIS
  Shared ScanAgentDebug helpers for Scan Agent E2E scripts under Resec.LabTests\ScanAgent.
#>
Set-StrictMode -Version Latest

$script:ScanAgentE2eLabPathsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $script:ScanAgentE2eLabPathsRoot 'Common\LabDeployExeLocation.ps1')
. (Join-Path $script:ScanAgentE2eLabPathsRoot 'Common\LabRuntimeTools.ps1'

function Resolve-ScanAgentDebugPath {
    <#
    .SYNOPSIS
      Locates ScanAgentDebug.exe for E2E scripts (PS 5.1+).
    #>
    param(
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot
    )

    if (-not (Get-Command Get-LabScanAgentTestTreeRoot -ErrorAction SilentlyContinue)) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        . (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
    }

    $testTreeRoot = Get-LabScanAgentTestTreeRoot
    $srcRoot = Get-LabScanAgentProductRoot
    $agentBin = Join-Path $srcRoot 'Resec.Agent.ScanAgent\bin'
    $debugClientBin = Join-Path $srcRoot 'Resec.Agent.ScanAgent.DebugClient\bin'

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path)
    }

    $fromConfig = Get-LabOptionalPath -SettingName 'scanAgentDebugExe' -EnvironmentVariable 'LAB_SCANAGENT_DEBUG_EXE'
    if (-not [string]::IsNullOrWhiteSpace($fromConfig)) {
        $candidates.Add($fromConfig)
    }

    $runtimeDebug = Get-LabRuntimeToolExePath -ExecutableFileName 'ScanAgentDebug.exe'
    if ($null -ne $runtimeDebug) {
        $candidates.Add($runtimeDebug)
    }

    $candidates.Add((Join-Path $testTreeRoot 'ScanAgentDebug.exe'))
    $candidates.Add((Join-Path $CallingScriptRoot '..\ScanAgentDebug.exe'))
  # Prefer x64 build output (solution default) so co-located Resec.Agent.ScanAgent.exe matches the debug client.
    foreach ($configuration in @('Debug', 'Release')) {
        $candidates.Add((Join-Path $agentBin "x64\$configuration\net11.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $debugClientBin "x64\$configuration\net11.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $agentBin "$configuration\net11.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $debugClientBin "$configuration\net11.0-windows\ScanAgentDebug.exe"))
    }

    $checked = @{}
    foreach ($candidate in $candidates) {
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        if ($checked.ContainsKey($resolved)) {
            continue
        }
        $checked[$resolved] = $true
        if (Test-Path -LiteralPath $resolved) {
            return $resolved
        }
    }

    $runtimeDir = Get-LabRuntimeToolsWinX64Directory
    throw "ScanAgentDebug not found. Use checked-in $runtimeDir\ScanAgentDebug.exe, build Resec.Agent.ScanAgent.DebugClient, set optional.scanAgentDebugExe in config\lab.local.json, set LAB_SCANAGENT_DEBUG_EXE, copy ScanAgentDebug.exe under Resec.LabTests\ScanAgent\, or pass -ScanAgentDebug."
}

function Format-ScanAgentE2eComponentVersion {
    param(
        [Parameter(Mandatory)]
        $AgentInfo
    )

    if ($null -eq $AgentInfo) {
        return $null
    }

    $ok = $false
    if ($AgentInfo.PSObject.Properties.Name -contains 'ok') {
        $ok = [bool]$AgentInfo.ok
    }
    if (-not $ok) {
        return $null
    }

    $agentVersion = [string]$AgentInfo.version
    $gatewayVersion = [string]$AgentInfo.gatewayVersion
    if ([string]::IsNullOrWhiteSpace($agentVersion)) {
        $agentVersion = [string]$AgentInfo.assemblyVersion
    }
    if ([string]::IsNullOrWhiteSpace($agentVersion)) {
        return $null
    }

    $agentVersion = $agentVersion.Trim()
    if ([string]::IsNullOrWhiteSpace($gatewayVersion)) {
        return $agentVersion
    }

    return ('{0} (gateway {1})' -f $agentVersion, $gatewayVersion.Trim())
}

function Get-ScanAgentE2eProductVersionFromPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath)
    $version = [string]$info.ProductVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = [string]$info.FileVersion
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    return $version.Trim()
}

function Get-ScanAgentE2eAgentExeCandidates {
    param(
        [string] $PreferredExePath
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string] $Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try {
            $resolved = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            return
        }
        if ($candidates -notcontains $resolved) {
            $candidates.Add($resolved)
        }
    }

    & $add $PreferredExePath
    $fromLabEnv = Get-ResecLabExePathFromEnvironment -EnvironmentVariableNames @(
        'RESEC_SCANAGENT_EXE_LOCATION',
        'LAB_SCANAGENT_EXE',
        'SCANAGENT_EXE'
    )
    & $add $fromLabEnv
    $configuredAgentExe = ''
    if (Get-Variable -Scope Script -Name SaE2eScanAgentExe -ErrorAction SilentlyContinue) {
        $configuredAgentExe = [string]$script:SaE2eScanAgentExe
    }
    & $add $configuredAgentExe
    & $add 'C:\Program Files\Resec Technologies\Resec Scan Agent\Resec.Agent.ScanAgent.exe'

    $processNames = @('Resec.Agent.ScanAgent', 'Resec Scan Agent')
    foreach ($processName in $processNames) {
        foreach ($proc in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            try {
                if ($proc.Path) {
                    & $add $proc.Path
                }
            }
            catch {
                # Access denied for Path on some hosts.
            }
        }
    }

    return @($candidates)
}

function Format-ScanAgentE2eComponentVersionFromInstall {
    param(
        [Parameter(Mandatory)]
        [string] $AgentExePath
    )

    $agentVersion = Get-ScanAgentE2eProductVersionFromPath -Path $AgentExePath
    if ([string]::IsNullOrWhiteSpace($agentVersion)) {
        return $null
    }

    $installDir = [System.IO.Path]::GetDirectoryName($AgentExePath)
    $gatewayDll = Join-Path $installDir 'Resec.Agent.Gateway.dll'
    $gatewayVersion = Get-ScanAgentE2eProductVersionFromPath -Path $gatewayDll
    if ([string]::IsNullOrWhiteSpace($gatewayVersion)) {
        return $agentVersion
    }

    return ('{0} (gateway {1})' -f $agentVersion, $gatewayVersion.Trim())
}

function Invoke-ScanAgentDebugProcess {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
        $stderr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
            StdErr   = if ($stderr) { $stderr.Trim() } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Try-Get-ScanAgentDebugAgentInfo {
    param(
        [Parameter(Mandatory)]
        [string] $Exe
    )

    $result = Invoke-ScanAgentDebugProcess -Exe $Exe -Arguments @('agent.info')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
        return $null
    }

    try {
        return ($result.StdOut | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Ensure-ScanAgentE2eComponentVersionRegistered {
    <#
    .SYNOPSIS
      Best-effort SCANAGENT_COMPONENT_VERSION for Test Platform (success or early failure).
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_COMPONENT_VERSION)) {
        return $env:SCANAGENT_COMPONENT_VERSION
    }

    $callingRoot = ''
    if (Get-Variable -Scope Script -Name SaE2eCallingScriptRoot -ErrorAction SilentlyContinue) {
        $callingRoot = [string]$script:SaE2eCallingScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($callingRoot)) {
        $callingRoot = $PSScriptRoot
        if ($callingRoot -match '\\Common$') {
            $callingRoot = Join-Path (Split-Path (Split-Path $callingRoot -Parent) -Parent) 'P0'
        }
    }

    $debugOverride = ''
    if (Get-Variable -Scope Script -Name SaE2eScanAgentDebug -ErrorAction SilentlyContinue) {
        $debugOverride = [string]$script:SaE2eScanAgentDebug
    }
    try {
        $debugExe = Resolve-ScanAgentDebugPath -Path $debugOverride -CallingScriptRoot $callingRoot
        $agentInfo = Try-Get-ScanAgentDebugAgentInfo -Exe $debugExe
        if ($null -ne $agentInfo) {
            $fromPipe = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
            if (-not [string]::IsNullOrWhiteSpace($fromPipe)) {
                return $fromPipe
            }
        }
    }
    catch {
        # ScanAgentDebug missing or agent.info unreachable — fall back to on-disk agent build.
    }

    $preferredAgentExe = ''
    if (Get-Variable -Scope Script -Name SaE2eScanAgentExe -ErrorAction SilentlyContinue) {
        $preferredAgentExe = [string]$script:SaE2eScanAgentExe
    }
    foreach ($agentExe in (Get-ScanAgentE2eAgentExeCandidates -PreferredExePath $preferredAgentExe)) {
        if (-not (Test-Path -LiteralPath $agentExe)) {
            continue
        }

        $fromInstall = Format-ScanAgentE2eComponentVersionFromInstall -AgentExePath $agentExe
        if ([string]::IsNullOrWhiteSpace($fromInstall)) {
            continue
        }

        $env:SCANAGENT_COMPONENT_VERSION = $fromInstall
        return $fromInstall
    }

    return $null
}

function Register-ScanAgentE2eVersionFromAgentInfo {
    <#
    .SYNOPSIS
      Sets SCANAGENT_COMPONENT_VERSION for Test Platform reporting (unless already set in the environment).
    #>
    param(
        [Parameter(Mandatory)]
        $AgentInfo
    )

    $formatted = Format-ScanAgentE2eComponentVersion -AgentInfo $AgentInfo
    if ([string]::IsNullOrWhiteSpace($formatted)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($env:SCANAGENT_COMPONENT_VERSION)) {
        $env:SCANAGENT_COMPONENT_VERSION = $formatted
    }

    return $formatted
}

$script:ScanAgentE2eDebugPipeEnsureAttempted = $false

function Get-ScanAgentE2eCurrentWindowsSessionId {
    return [System.Diagnostics.Process]::GetCurrentProcess().SessionId
}

function Resolve-ScanAgentE2eAgentExeFromDebugExe {
    param(
        [Parameter(Mandatory)]
        [string] $DebugExe
    )

    $agentDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($DebugExe))
    $coLocated = Join-Path $agentDir 'Resec.Agent.ScanAgent.exe'
    if (Test-Path -LiteralPath $coLocated) {
        return $coLocated
    }

    $normalizedDir = $agentDir.Replace('\', '/')
    if ($normalizedDir -match '/bin/Debug/net10\.0-windows$') {
        $x64Dir = $agentDir -replace '\\bin\\Debug\\', '\bin\x64\Debug\'
        $x64Agent = Join-Path $x64Dir 'Resec.Agent.ScanAgent.exe'
        if (Test-Path -LiteralPath $x64Agent) {
            return $x64Agent
        }
    }

    $preferred = ''
    if (Get-Variable -Scope Script -Name SaE2eScanAgentExe -ErrorAction SilentlyContinue) {
        $preferred = [string]$script:SaE2eScanAgentExe
    }

    foreach ($candidate in (Get-ScanAgentE2eAgentExeCandidates -PreferredExePath $preferred)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Cannot resolve Resec.Agent.ScanAgent.exe for debug client '$DebugExe' (set RESEC_SCANAGENT_EXE_LOCATION or run from a Debug build output folder)."
}

function Set-ScanAgentE2eDebugInterfaceEnabled {
    param(
        [Parameter(Mandatory)]
        [string] $AgentExePath,
        [switch] $Quiet
    )

    $agentFull = [System.IO.Path]::GetFullPath($AgentExePath)
    $settingsPath = Join-Path ([System.IO.Path]::GetDirectoryName($agentFull)) 'appsettings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "appsettings.json not found next to agent exe: $settingsPath"
    }

    $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    $changed = $false
    if ($json.PSObject.Properties.Name -contains 'DebugInterface') {
        if ($json.DebugInterface.Enabled -ne $true) {
            $json.DebugInterface.Enabled = $true
            $changed = $true
        }
    }
    else {
        $json | Add-Member -NotePropertyName 'DebugInterface' -NotePropertyValue ([pscustomobject]@{ Enabled = $true })
        $changed = $true
    }

    if ($changed) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 32) + [Environment]::NewLine, $utf8)
        if (-not $Quiet) {
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Enabled DebugInterface in $settingsPath"
        }
    }

    return [pscustomobject]@{ SettingsPath = $settingsPath; Changed = $changed }
}

function Get-ScanAgentE2eDesktopAgentProcesses {
    param(
        [int] $SessionId = -1,
        [string[]] $AgentExePaths = @()
    )

    if ($SessionId -lt 0) {
        $SessionId = Get-ScanAgentE2eCurrentWindowsSessionId
    }

    $normalizedTargets = @(
        $AgentExePaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    )

    $names = @('Resec.Agent.ScanAgent')
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($proc.SessionId -ne $SessionId) {
                continue
            }

            $path = $null
            try {
                $path = $proc.Path
            }
            catch {
                continue
            }

            if ($normalizedTargets.Count -gt 0) {
                if ([string]::IsNullOrWhiteSpace($path) -or ($normalizedTargets -notcontains [System.IO.Path]::GetFullPath($path))) {
                    continue
                }
            }

            [void]$result.Add($proc)
        }
    }

    if ($result.Count -eq 0) {
        return @()
    }

    return $result.ToArray()
}

function Start-ScanAgentE2eColdUiLaunch {
    param(
        [Parameter(Mandatory)]
        [string] $AgentExePath,
        [int] $SecondActivationDelaySec = 3,
        [int] $ProcessWaitSec = 45,
        [int] $UiWindowWaitSec = 120
    )

    $agentFull = [System.IO.Path]::GetFullPath($AgentExePath)
    if (-not (Test-Path -LiteralPath $agentFull)) {
        throw "Scan Agent executable not found: $agentFull"
    }

    $workDir = [System.IO.Path]::GetDirectoryName($agentFull)
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($agentFull)

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Start Scan Agent (first activation): $agentFull"
    Start-Process -FilePath $agentFull -WorkingDirectory $workDir | Out-Null

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($ProcessWaitSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -gt 0) {
            break
        }
        Start-Sleep -Milliseconds 400
    }

    if ($SecondActivationDelaySec -gt 0) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Pause ${SecondActivationDelaySec}s before second activation (UI)"
        Start-Sleep -Seconds $SecondActivationDelaySec
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Start Scan Agent (second activation UI): $agentFull"
    Start-Process -FilePath $agentFull -WorkingDirectory $workDir | Out-Null

    $uiDeadline = [DateTimeOffset]::UtcNow.AddSeconds($UiWindowWaitSec)
    while ([DateTimeOffset]::UtcNow -lt $uiDeadline) {
        foreach ($proc in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
            try {
                $proc.Refresh()
                if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Scan Agent UI window up: pid=$($proc.Id)"
                    return
                }
            }
            catch { }
        }
        Start-Sleep -Seconds 2
    }

    throw "Scan Agent UI window did not appear within ${UiWindowWaitSec}s after cold launch."
}

function Stop-ScanAgentE2eDesktopAgentsInSession {
    param(
        [string[]] $AgentExePaths = @(),
        [int] $SessionId = -1,
        [int] $WaitSec = 15
    )

    if ($SessionId -lt 0) {
        $SessionId = Get-ScanAgentE2eCurrentWindowsSessionId
    }

    $targets = @(Get-ScanAgentE2eDesktopAgentProcesses -SessionId $SessionId -AgentExePaths $AgentExePaths)
    foreach ($proc in $targets) {
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Stopping desktop Scan Agent pid $($proc.Id) (session $SessionId)"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }

    if ($targets.Length -eq 0) {
        return
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSec)
    $names = @('Resec.Agent.ScanAgent')
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $left = @()
        foreach ($name in $names) {
            $left += @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $SessionId })
        }
        if (@($left).Length -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 400
    }
}

function Add-ScanAgentE2eFromAgentSwitch {
    param([string[]] $Arguments)

    if ($Arguments -contains '--from-agent') {
        return $Arguments
    }

    if ($env:SCANAGENT_E2E_NO_FROM_AGENT -eq '1') {
        return $Arguments
    }

    return @('--from-agent') + @($Arguments)
}

function Test-ScanAgentE2eDebugPing {
    param(
        [Parameter(Mandatory)]
        [string] $DebugExe,
        [int] $ConnectTimeoutMs = 5000
    )

    $args = Add-ScanAgentE2eFromAgentSwitch -Arguments @('ping')
    if ($ConnectTimeoutMs -gt 0 -and ($args -notcontains '--timeout-ms')) {
        $args = $args + @('--timeout-ms', [string]$ConnectTimeoutMs)
    }

    $result = Invoke-ScanAgentDebugProcess -Exe $DebugExe -Arguments $args
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdErr) { $result.StdErr } else { $result.StdOut }
        return [pscustomobject]@{ Ok = $false; ExitCode = $result.ExitCode; Detail = $detail }
    }

    if ($result.StdOut -notmatch '"message"\s*:\s*"pong"') {
        return [pscustomobject]@{ Ok = $false; ExitCode = $result.ExitCode; Detail = $result.StdOut }
    }

    return [pscustomobject]@{ Ok = $true; ExitCode = 0; Detail = $result.StdOut }
}

function Ensure-ScanAgentE2eDebugPipeReady {
    param(
        [Parameter(Mandatory)]
        [string] $DebugExe,
        [int] $StartupTimeoutSec = 90
    )

    if ($env:SCANAGENT_E2E_NO_AUTOSTART -eq '1') {
        return
    }

    $ping = Test-ScanAgentE2eDebugPing -DebugExe $DebugExe
    if ($ping.Ok) {
        return
    }

    if ($script:ScanAgentE2eDebugPipeEnsureAttempted) {
        return
    }

    $script:ScanAgentE2eDebugPipeEnsureAttempted = $true
    $sessionId = Get-ScanAgentE2eCurrentWindowsSessionId
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Scan Agent debug pipe unavailable (session $sessionId); ensuring desktop agent with DebugInterface"

    $agentExe = Resolve-ScanAgentE2eAgentExeFromDebugExe -DebugExe $DebugExe
    $agentFull = [System.IO.Path]::GetFullPath($agentExe)
    $workDir = [System.IO.Path]::GetDirectoryName($agentFull)
    $settings = Set-ScanAgentE2eDebugInterfaceEnabled -AgentExePath $agentFull

    $running = @(Get-ScanAgentE2eDesktopAgentProcesses -SessionId $sessionId)
    if ($running.Length -gt 0) {
        $paths = @($running | ForEach-Object { $_.Path }) -join ', '
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Desktop Scan Agent in session $sessionId ($paths); restarting so debug pipe matches E2E client"
    }

    Stop-ScanAgentE2eDesktopAgentsInSession -AgentExePaths @() -SessionId $sessionId

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Starting desktop Scan Agent: $agentFull"
    Start-Process -FilePath $agentFull -WorkingDirectory $workDir | Out-Null

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $ping = Test-ScanAgentE2eDebugPing -DebugExe $DebugExe -ConnectTimeoutMs 3000
        if ($ping.Ok) {
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Scan Agent debug pipe ready (ping ok)"
            return
        }
        Start-Sleep -Seconds 2
    }

    $procs = @(Get-ScanAgentE2eDesktopAgentProcesses -SessionId $sessionId)
    $procSummary = if ($procs.Length -gt 0) {
        (@($procs | ForEach-Object { "pid=$($_.Id) path=$($_.Path)" })) -join '; '
    }
    else {
        'no Resec.Agent.ScanAgent in this session'
    }

    throw @"
Scan Agent debug pipe still unavailable after auto-start (session $sessionId, waited ${StartupTimeoutSec}s).
Agent exe: $agentFull
Processes: $procSummary
Last ping: $($ping.Detail)
Disable auto-start with SCANAGENT_E2E_NO_AUTOSTART=1.
"@
}

function Format-ScanAgentDebugInvokeFailure {
    param(
        [Parameter(Mandatory)]
        [int] $ExitCode,
        [Parameter(Mandatory)]
        [string] $CommandLine,
        [string] $Detail
    )

    $detailText = if ([string]::IsNullOrWhiteSpace($Detail)) { '(no output)' } else { $Detail.Trim() }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("ScanAgentDebug failed (exit $ExitCode): $CommandLine")
    $lines.Add($detailText)

    $pipeUnreachable = ($ExitCode -eq 4) -or ($detailText -match 'debug pipe|Timed out connecting to (the agent debug pipe|pipe)')
    if ($pipeUnreachable) {
        $lines.Add('')
        $lines.Add('The agent debug named pipe did not respond (enable DebugInterface in appsettings; not an IDE debugger).')
        $lines.Add('E2E scripts auto-start/restart the desktop agent and use ScanAgentDebug --from-agent unless SCANAGENT_E2E_NO_AUTOSTART=1.')
        $lines.Add('Checklist:')
        $lines.Add('  1) Desktop Scan Agent is running in this Windows session (not only the Windows service).')
        $lines.Add('  2) appsettings.json: DebugInterface.Enabled = true (repo default is false).')
        $lines.Add('  3) Restart the agent after changing DebugInterface (pipe starts at startup).')
        $lines.Add('  4) Agent log should include: [AgentDebugPipeServer] Debug interface enabled on pipe ...')
        $lines.Add('  5) Verify manually: ScanAgentDebug --from-agent ping  ->  JSON containing pong.')
    }
    elseif (($ExitCode -eq 3) -or ($detailText -match 'No running process found')) {
        $lines.Add('')
        $lines.Add('No Scan Agent process was found for ScanAgentDebug to attach to.')
        $lines.Add('Start Resec.Agent.ScanAgent (desktop) before running this E2E script.')
    }

    return ($lines -join [Environment]::NewLine)
}

function Format-ScanAgentDebugCommandLine {
    param([string[]] $Arguments)

    $parts = @()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            continue
        }
        $text = [string] $arg
        if ($text -match '[\s"]') {
            $parts += '"' + ($text.Replace('"', '\"')) + '"'
        }
        else {
            $parts += $text
        }
    }
    return ($parts -join ' ')
}

function Invoke-ScanAgentDebug {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    if ([string]::IsNullOrWhiteSpace($Exe)) {
        throw 'Invoke-ScanAgentDebug requires -Exe.'
    }

    $debugFull = [System.IO.Path]::GetFullPath($Exe)
    Ensure-ScanAgentE2eDebugPipeReady -DebugExe $debugFull
    $Arguments = Add-ScanAgentE2eFromAgentSwitch -Arguments $Arguments

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(& $debugFull @Arguments 2>&1)
        foreach ($line in $lines) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $msg = $line.Exception.Message
                if ([string]::IsNullOrWhiteSpace($msg)) {
                    $msg = $line.ToString()
                }
                if ($msg.StartsWith('Wait:', [StringComparison]::Ordinal)) {
                    Write-Host $msg -ForegroundColor DarkCyan
                }
                else {
                    $stdoutLines.Add($msg)
                }
            }
            elseif ($line -is [string] -and $line.StartsWith('Wait:', [StringComparison]::Ordinal)) {
                Write-Host $line -ForegroundColor DarkCyan
            }
            else {
                $stdoutLines.Add([string] $line)
            }
        }
    }
    catch {
        $stdoutLines.Add($_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $savedEap
    }

    $exitCode = 0
    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }

    $stdout = ($stdoutLines -join [Environment]::NewLine).TrimEnd()

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
        StdErr   = ''
    }
}

function Invoke-ScanAgentDebugJson {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments $Arguments
    $commandLine = Format-ScanAgentDebugCommandLine -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdOut) { $result.StdOut } else { $result.StdErr }
        throw (Format-ScanAgentDebugInvokeFailure -ExitCode $result.ExitCode -CommandLine $commandLine -Detail $detail)
    }

    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        $firstArg = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
        if ($firstArg -eq 'waitReady') {
            return [pscustomobject]@{ ok = $true; op = 'waitReady' }
        }

        throw "ScanAgentDebug returned no stdout: $commandLine"
    }

    $stdoutText = $result.StdOut.Trim()
    try {
        return ($stdoutText | ConvertFrom-Json)
    }
    catch {
        $jsonLine = $null
        foreach ($line in ($stdoutText -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('{')) {
                $jsonLine = $trimmed
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "ScanAgentDebug returned no JSON: $commandLine`n$stdoutText"
        }

        try {
            return $jsonLine | ConvertFrom-Json
        }
        catch {
            throw "ScanAgentDebug output was not JSON: $commandLine`n$stdoutText"
        }
    }
}

function Register-ScanAgentE2eOriginalPolicyName {
    <#
      Records the agent header policy name for finally-block restore (policy.select after poppolicystate).
      Waits for gateway connected first so policy.current returns JSON with a selected policy (same pattern as SA-08).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [int] $GatewayWaitSec = 120,
        [string] $GatewayWaitContext = 'before recording OriginalPolicyName'
    )

    if (Get-Command -Name Wait-ScanAgentGatewayConnected -ErrorAction SilentlyContinue) {
        $null = Wait-ScanAgentGatewayConnected -Exe $Exe -TimeoutSec $GatewayWaitSec -Context $GatewayWaitContext -NudgeReconnect
    }

    $policyCurrent = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.current')
    if (-not $policyCurrent.ok) {
        $err = if ($policyCurrent.error) { $policyCurrent.error } else { 'unknown error' }
        throw "policy.current failed ($GatewayWaitContext): $err"
    }

    if (-not $policyCurrent.policy -or [string]::IsNullOrWhiteSpace($policyCurrent.policy.name)) {
        throw "policy.current returned no policy name ($GatewayWaitContext). Select a policy in the agent header before E2E setup."
    }

    $name = [string]$policyCurrent.policy.name
    if (Get-Command -Name Write-TestStep -ErrorAction SilentlyContinue) {
        Write-TestStep "Original policy to restore: $name"
    }

    return $name
}
