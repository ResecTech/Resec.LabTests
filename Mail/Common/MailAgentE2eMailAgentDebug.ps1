#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-MailAgentDebugBaseUrl {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_MAIL_AGENT_DEBUG_BASE_URL)) {
        return $env:MAIL_E2E_MAIL_AGENT_DEBUG_BASE_URL.TrimEnd('/')
    }

    return 'http://127.0.0.1:4505'
}

function Invoke-MailAgentDebugHook {
    param(
        [Parameter(Mandatory)]
        [string] $Command,
        [string] $BaseUrl = '',
        [string] $Message = '',
        [string] $Mode = '',
        [int] $MaxMessages = -1,
        [hashtable] $BodyObject = $null,
        [ValidateSet('Get', 'Post')]
        [string] $Method = ''
    )

    $root = Get-MailAgentDebugBaseUrl -Override $BaseUrl
    $usePost = $Method -eq 'Post'
    if ([string]::IsNullOrWhiteSpace($Method)) {
        $usePost = ($null -ne $BodyObject) -or (-not [string]::IsNullOrWhiteSpace($Message)) -or `
            (-not [string]::IsNullOrWhiteSpace($Mode)) -or ($MaxMessages -ge 0)
    }

    $queryParts = @('command=' + [Uri]::EscapeDataString($Command))
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $queryParts += 'message=' + [Uri]::EscapeDataString($Message)
    }
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        $queryParts += 'mode=' + [Uri]::EscapeDataString($Mode)
    }
    if ($MaxMessages -ge 0) {
        $queryParts += 'maxMessages=' + [Uri]::EscapeDataString([string]$MaxMessages)
    }

    $uri = if ($usePost) { '{0}/debug/hook' -f $root } else { '{0}/debug/hook?{1}' -f $root, ($queryParts -join '&') }
    $body = $null
    if ($usePost) {
        if ($null -ne $BodyObject) {
            $body = $BodyObject | ConvertTo-Json -Compress
        }
        else {
            $payload = @{ command = $Command }
            if (-not [string]::IsNullOrWhiteSpace($Message)) { $payload.message = $Message }
            if (-not [string]::IsNullOrWhiteSpace($Mode)) { $payload.mode = $Mode }
            if ($MaxMessages -ge 0) { $payload.maxMessages = $MaxMessages }
            $body = $payload | ConvertTo-Json -Compress
        }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in @('rest', 'curl')) {
        try {
            if ($attempt -eq 'rest') {
                if ($usePost) {
                    return Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing
                }
                return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing
            }

            $curlJson = if ($usePost) {
                Invoke-MailAgentDebugHookViaCurl -Uri $uri -Method Post -Body $body
            }
            else {
                Invoke-MailAgentDebugHookViaCurl -Uri $uri
            }
            if ($null -ne $curlJson) {
                return $curlJson
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }

    $hint = 'Ensure the mail agent runs with EnableDebugInterface=true (appsettings) and Kestrel DebugHttp on port 4505.'
    throw "Mail agent debug hook failed (command=$Command, url=$root): $($errors -join '; '). $hint"
}

function Add-MailAgentE2eLogMark {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $BaseUrl = ''
    )

    return Invoke-MailAgentDebugHook -Command 'logmark' -Message $Message -BaseUrl $BaseUrl
}

function Set-MailAgentDebugOverload {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('off', 'spoolfull', 'spoolcap', 'sessions', 'processing')]
        [string] $Mode,
        [string] $BaseUrl = '',
        [int] $MaxMessages = -1
    )

    $params = @{
        Command  = 'overload'
        Mode     = $Mode
        BaseUrl  = $BaseUrl
    }
    if ($Mode -eq 'spoolcap' -and $MaxMessages -ge 0) {
        $params.MaxMessages = $MaxMessages
    }

    return Invoke-MailAgentDebugHook @params
}

function Invoke-MailAgentDebugHookViaCurl {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('Get', 'Post')]
        [string] $Method = 'Get',
        [string] $Body = ''
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        return $null
    }

    $args = @('-sS', '--max-time', '10')
    if ($Method -eq 'Post') {
        $args += @('-X', 'POST', '-H', 'Content-Type: application/json', '--data', $Body)
    }
    $args += $Uri
    $output = & curl.exe @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed (exit $LASTEXITCODE): $output"
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'curl.exe returned empty response.'
    }

    return $text | ConvertFrom-Json
}

function Test-MailAgentDebugOperationalReady {
    param(
        $Status,
        [int] $ExpectedInboundPort = 0
    )

    if ($null -eq $Status) {
        return $false
    }

    if ($Status.coreConnected -ne $true) {
        return $false
    }

    $connProp = $Status.PSObject.Properties['coreConnectionStatus']
    if ($null -ne $connProp) {
        $conn = [string]$connProp.Value
        if (-not [string]::IsNullOrWhiteSpace($conn) -and $conn -ne 'Authenticated') {
            return $false
        }
    }

    $connectingProp = $Status.PSObject.Properties['coreConnecting']
    if ($null -ne $connectingProp -and $connectingProp.Value -eq $true) {
        return $false
    }

    $phaseProp = $Status.PSObject.Properties['coreSessionPhase']
    if ($null -ne $phaseProp) {
        $phase = [string]$phaseProp.Value
        if ($phase -eq 'Reconnecting' -or $phase -eq 'SessionLost') {
            return $false
        }
    }

    if ($Status.inboundSmtpListening -ne $true) {
        return $false
    }

    if ($ExpectedInboundPort -gt 0) {
        $ports = @($Status.inboundListenPorts)
        if ($ports -notcontains $ExpectedInboundPort) {
            return $false
        }
    }

    return $true
}

function Wait-MailAgentDebugReady {
    param(
        [string] $BaseUrl = '',
        [int] $ExpectedInboundPort = 0,
        [int] $TimeoutSec = 90,
        [int] $PollSec = 1
    )

    return Wait-MailAgentDebugOperationalReady -BaseUrl $BaseUrl -ExpectedInboundPort $ExpectedInboundPort `
        -TimeoutSec $TimeoutSec -PollSec $PollSec -FailureContext 'initial readiness'
}

function Wait-MailAgentDebugReconnect {
    param(
        [string] $BaseUrl = '',
        [int] $ExpectedInboundPort = 0,
        [int] $TimeoutSec = 60,
        [int] $PollSec = 1
    )

    return Wait-MailAgentDebugOperationalReady -BaseUrl $BaseUrl -ExpectedInboundPort $ExpectedInboundPort `
        -TimeoutSec $TimeoutSec -PollSec $PollSec -FailureContext 'reconnect after Core commup'
}

function Wait-MailAgentDebugOperationalReady {
    param(
        [string] $BaseUrl = '',
        [int] $ExpectedInboundPort = 0,
        [int] $TimeoutSec = 90,
        [int] $PollSec = 1,
        [string] $FailureContext = 'operational readiness'
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $lastStatus = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $lastStatus = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
            if (Test-MailAgentDebugOperationalReady -Status $lastStatus -ExpectedInboundPort $ExpectedInboundPort) {
                return $lastStatus
            }
        }
        catch {
            $lastStatus = $null
        }

        Start-Sleep -Seconds $PollSec
    }

    $detail = 'status hook unreachable or agent not ready.'
    if ($null -ne $lastStatus) {
        $detail = Format-MailAgentDebugStatusSummary -Status $lastStatus
    }

    $message = 'Mail agent did not reach operational ready ({0}) within {1}s. Expect coreConnectionStatus=Authenticated, coreConnecting=false, coreSessionPhase=Ready, inboundSmtpListening=true. Last: {2}'
    throw ($message -f $FailureContext, $TimeoutSec, $detail)
}

function Format-MailAgentDebugStatusSummary {
    param($Status)

    if ($null -eq $Status) {
        return '(no status)'
    }

    $ports = @($Status.inboundListenPorts)
    $portText = if ($ports.Count -gt 0) { ($ports -join ',') } else { 'none' }
    $counts = $Status.tempFolderFileCounts
    $outCount = if ($null -ne $counts -and $counts.PSObject.Properties['SanitizationOutput']) {
        [string]$counts.SanitizationOutput
    }
    else {
        '?'
    }

    $connProp = $Status.PSObject.Properties['coreConnectionStatus']
    if ($null -ne $connProp -and -not [string]::IsNullOrWhiteSpace([string]$connProp.Value)) {
        $conn = [string]$connProp.Value
    }
    else {
        $conn = if ($Status.coreConnected -eq $true) { 'Authenticated' } else { 'Disconnected' }
    }

    $connecting = $null
    $connectingProp = $Status.PSObject.Properties['coreConnecting']
    if ($null -ne $connectingProp) { $connecting = $connectingProp.Value }

    $phase = $null
    $phaseProp = $Status.PSObject.Properties['coreSessionPhase']
    if ($null -ne $phaseProp) { $phase = $phaseProp.Value }

    return ("core={0} connecting={1} phase={2} inboundListening={3} ports={4} outboundQueue={5} sanitizationOutputFiles={6} temp={7}" -f `
        $conn, $connecting, $phase, $Status.inboundSmtpListening, $portText, `
        $Status.outboundQueueDepth, $outCount, $Status.tempFolderRoot)
}

function Get-MailAgentDebugTempFolderRoot {
    param([string] $BaseUrl = '')

    $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
    $root = [string]$status.tempFolderRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Mail agent debug status did not include tempFolderRoot; set -MailTempFolder or MAIL_E2E_TEMP_FOLDER.'
    }

    return [System.IO.Path]::GetFullPath($root)
}

function Get-MailAgentDebugSanitizationOutputFileCount {
    param($Status)

    if ($null -eq $Status) {
        return $null
    }

    $counts = $Status.tempFolderFileCounts
    if ($null -eq $counts) {
        return $null
    }

    $prop = $counts.PSObject.Properties['SanitizationOutput']
    if ($null -eq $prop) {
        return $null
    }

    return [int]$prop.Value
}

function Wait-MailAgentDebugSanitizationOutputEmpty {
    param(
        [string] $BaseUrl = '',
        [int] $TimeoutSec = 20,
        [string] $Context = 'SanitizationOutput must be empty after outbound delivery'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastStatus = $null
    $lastCount = $null
    $lastFolder = $null

    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
        $lastCount = Get-MailAgentDebugSanitizationOutputFileCount -Status $lastStatus
        $folderProp = $lastStatus.PSObject.Properties['sanitizationOutputFolder']
        if ($null -ne $folderProp -and -not [string]::IsNullOrWhiteSpace([string]$folderProp.Value)) {
            $lastFolder = [string]$folderProp.Value
        }

        if ($null -ne $lastCount -and $lastCount -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($lastFolder) -and [System.IO.Directory]::Exists($lastFolder)) {
                $onDisk = @(Get-ChildItem -LiteralPath $lastFolder -File -Force -ErrorAction SilentlyContinue).Count
                if ($onDisk -eq 0) {
                    return $lastStatus
                }
            }
            else {
                return $lastStatus
            }
        }

        Start-Sleep -Milliseconds 400
    }

    $folderText = if ([string]::IsNullOrWhiteSpace($lastFolder)) { '(unknown)' } else { $lastFolder }
    $countText = if ($null -eq $lastCount) { '?' } else { [string]$lastCount }
    throw ("{0}. sanitizationOutputFolder={1} tempFolderFileCounts.SanitizationOutput={2} (waited {3}s). {4}" -f `
        $Context, $folderText, $countText, $TimeoutSec, (Format-MailAgentDebugStatusSummary -Status $lastStatus))
}

function Get-MailAgentDebugLogPathEvidence {
    param([string] $BaseUrl = '')

    try {
        $r = Invoke-MailAgentDebugHook -Command 'logpath' -BaseUrl $BaseUrl
        $path = [string]$r.currentLogFilePath
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    catch {
    }

    return $null
}

$script:MailAgentE2eProcessEnsureAttempted = $false

function Test-MailAgentDebugHookAvailable {
    param([string] $BaseUrl = '')

    try {
        $null = Invoke-MailAgentDebugHook -Command 'version' -BaseUrl $BaseUrl
        return $true
    }
    catch {
        return $false
    }
}

function Write-MailAgentE2eAutostartStep {
    param([string] $Message)
    Write-Host ("[{0}] [STEP] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Set-MailAgentE2eDebugInterfaceEnabled {
    param(
        [Parameter(Mandatory)]
        [string] $AgentExePath,
        [switch] $Quiet
    )

    $agentFull = [System.IO.Path]::GetFullPath($AgentExePath)
    $settingsPath = Join-Path ([System.IO.Path]::GetDirectoryName($agentFull)) 'appsettings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "appsettings.json not found next to mail agent exe: $settingsPath"
    }

    $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    $changed = $false
    if ($json.PSObject.Properties.Name -contains 'EnableDebugInterface') {
        if ($json.EnableDebugInterface -ne $true) {
            $json.EnableDebugInterface = $true
            $changed = $true
        }
    }
    else {
        $json | Add-Member -NotePropertyName 'EnableDebugInterface' -NotePropertyValue $true
        $changed = $true
    }

    if ($changed) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($settingsPath, ($json | ConvertTo-Json -Depth 32) + [Environment]::NewLine, $utf8)
        if (-not $Quiet) {
            Write-MailAgentE2eAutostartStep "Enabled EnableDebugInterface in $settingsPath"
        }
    }

    return [pscustomobject]@{ SettingsPath = $settingsPath; Changed = $changed }
}

function Get-MailAgentE2eDesktopAgentProcesses {
    param(
        [string] $AgentExePath = ''
    )

    $targetFull = $null
    if (-not [string]::IsNullOrWhiteSpace($AgentExePath)) {
        $targetFull = [System.IO.Path]::GetFullPath($AgentExePath)
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-Process -Name 'Resec.Agent.Mail' -ErrorAction SilentlyContinue)) {
        $path = $null
        try {
            $path = $proc.Path
        }
        catch {
            continue
        }

        if ($null -ne $targetFull -and -not [string]::IsNullOrWhiteSpace($path)) {
            if ([System.IO.Path]::GetFullPath($path) -ne $targetFull) {
                continue
            }
        }

        [void]$result.Add($proc)
    }

    if ($result.Count -eq 0) {
        return @()
    }

    return $result.ToArray()
}

function Stop-MailAgentE2eDesktopAgents {
    param(
        [string] $AgentExePath = ''
    )

    foreach ($proc in @(Get-MailAgentE2eDesktopAgentProcesses -AgentExePath $AgentExePath)) {
        try {
            Write-MailAgentE2eAutostartStep "Stopping mail agent pid=$($proc.Id)"
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Host "[WARN] Could not stop mail agent pid=$($proc.Id): $($_.Exception.Message)"
        }
    }
}

function Ensure-MailAgentE2eProcessRunning {
    <#
    .SYNOPSIS
      Starts Resec.Agent.Mail when the debug hook on port 4505 is down (unless skipped or MAILAGENT_E2E_NO_AUTOSTART=1).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $BaseUrl = '',
        [string] $MailAgentExePath = '',
        [int] $ExpectedInboundPort = 0,
        [int] $StartupTimeoutSec = 90,
        [switch] $SkipStart
    )

    $startedByScript = $false
    $startedProcess = $null

    if ($SkipStart) {
        return [pscustomobject]@{ StartedByScript = $false; Process = $null }
    }

    if ($env:MAILAGENT_E2E_NO_AUTOSTART -eq '1') {
        return [pscustomobject]@{ StartedByScript = $false; Process = $null }
    }

    if (Test-MailAgentDebugHookAvailable -BaseUrl $BaseUrl) {
        try {
            $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
            if (Test-MailAgentDebugOperationalReady -Status $status -ExpectedInboundPort $ExpectedInboundPort) {
                Write-MailAgentE2eAutostartStep 'Mail agent debug hook already operational'
                return [pscustomobject]@{ StartedByScript = $false; Process = $null }
            }
        }
        catch {
        }
    }

    if ($script:MailAgentE2eProcessEnsureAttempted) {
        return [pscustomobject]@{ StartedByScript = $false; Process = $null }
    }

    $script:MailAgentE2eProcessEnsureAttempted = $true
    $agentExe = Resolve-MailAgentE2eAgentExePath -CallingScriptRoot $CallingScriptRoot -Path $MailAgentExePath
    $agentFull = [System.IO.Path]::GetFullPath($agentExe)
    $workDir = [System.IO.Path]::GetDirectoryName($agentFull)

    $null = Set-MailAgentE2eDebugInterfaceEnabled -AgentExePath $agentFull

    $running = @(Get-MailAgentE2eDesktopAgentProcesses)
    if ($running.Length -gt 0) {
        $paths = @($running | ForEach-Object { $_.Path }) -join ', '
        Write-MailAgentE2eAutostartStep "Mail agent process(es) running without usable debug hook ($paths); restarting for E2E"
        Stop-MailAgentE2eDesktopAgents
        Start-Sleep -Seconds 2
    }

    Write-MailAgentE2eAutostartStep "Starting mail agent: $agentFull"
    $startedProcess = Start-Process -FilePath $agentFull -WorkingDirectory $workDir -PassThru -WindowStyle Normal
    $startedByScript = $true

    try {
        $null = Wait-MailAgentDebugReady -BaseUrl $BaseUrl -ExpectedInboundPort $ExpectedInboundPort -TimeoutSec $StartupTimeoutSec
    }
    catch {
        $procs = @(Get-MailAgentE2eDesktopAgentProcesses -AgentExePath $agentFull)
        $procSummary = if ($procs.Length -gt 0) {
            (@($procs | ForEach-Object { "pid=$($_.Id)" })) -join '; '
        }
        else {
            'no Resec.Agent.Mail process'
        }

        throw @"
Mail agent debug hook still unavailable after auto-start (waited ${StartupTimeoutSec}s).
Agent exe: $agentFull
Processes: $procSummary
$($_.Exception.Message)
Disable auto-start with MAILAGENT_E2E_NO_AUTOSTART=1 or pass -SkipStartMailAgent.
"@
    }

    return [pscustomobject]@{
        StartedByScript = $startedByScript
        Process         = $startedProcess
        AgentExePath    = $agentFull
    }
}

function Initialize-MailAgentE2eComponentVersionFromDebug {
    param([string] $BaseUrl = '')

    if (-not [string]::IsNullOrWhiteSpace($env:MailAgent_COMPONENT_VERSION)) {
        return
    }

    try {
        $v = Invoke-MailAgentDebugHook -Command 'version' -BaseUrl $BaseUrl
        $text = [string]$v.version
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $env:MailAgent_COMPONENT_VERSION = $text
        }
    }
    catch {
    }
}
