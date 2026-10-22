#Requires -Version 5.1
<#
.SYNOPSIS
  Shared ScanAgentDebug helpers for Scan Agent E2E scripts under Resec.LabTests\ScanAgent.
#>
Set-StrictMode -Version Latest

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

    $candidates.Add((Join-Path $testTreeRoot 'ScanAgentDebug.exe'))
    $candidates.Add((Join-Path $CallingScriptRoot '..\ScanAgentDebug.exe'))
    foreach ($configuration in @('Debug', 'Release')) {
        $candidates.Add((Join-Path $agentBin "$configuration\net10.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $agentBin "x64\$configuration\net10.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $debugClientBin "$configuration\net10.0-windows\ScanAgentDebug.exe"))
        $candidates.Add((Join-Path $debugClientBin "x64\$configuration\net10.0-windows\ScanAgentDebug.exe"))
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

    throw 'ScanAgentDebug not found. Build Resec.Agent.ScanAgent.DebugClient, set optional.scanAgentDebugExe in config\lab.local.json, set LAB_SCANAGENT_DEBUG_EXE, copy ScanAgentDebug.exe under Resec.LabTests\ScanAgent\, or pass -ScanAgentDebug.'
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
    & $add $env:SCANAGENT_EXE
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
        $lines.Add('Checklist:')
        $lines.Add('  1) Desktop Scan Agent is running in this Windows session (not only the Windows service).')
        $lines.Add('  2) appsettings.json: DebugInterface.Enabled = true (repo default is false).')
        $lines.Add('  3) Restart the agent after changing DebugInterface (pipe starts at startup).')
        $lines.Add('  4) Agent log should include: [AgentDebugPipeServer] Debug interface enabled on pipe ...')
        $lines.Add('  5) Verify manually: ScanAgentDebug ping  ->  JSON containing pong.')
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

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(& $Exe @Arguments 2>&1)
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
