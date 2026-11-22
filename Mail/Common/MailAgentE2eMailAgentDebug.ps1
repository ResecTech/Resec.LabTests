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

function Ensure-MailAgentE2eCoreDebugHookLoaded {
    if (Get-Command -Name 'Invoke-CoreE2eDebugHook' -ErrorAction SilentlyContinue) {
        return
    }

    $coreHook = Join-Path (Join-Path (Get-LabTestsRoot) 'Core\Common') 'CoreE2eDebugHook.ps1'
    if (-not (Test-Path -LiteralPath $coreHook)) {
        throw "Core E2E debug hook script not found: $coreHook"
    }

    . $coreHook
}

function Write-MailAgentE2eCorrelationLogMark {
    <#
    .SYNOPSIS
      Writes the same searchable line to Core and mail agent Serilog (DEBUG: E2E logmark: …).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $TestId,
        [Parameter(Mandatory)]
        [string] $Mark,
        [string] $CoreDebugHookUrl = '',
        [string] $MailAgentDebugUrl = ''
    )

    $text = "$TestId | $Mark"
    if (-not [string]::IsNullOrWhiteSpace($CoreDebugHookUrl)) {
        try {
            Ensure-MailAgentE2eCoreDebugHookLoaded
            $null = Invoke-CoreE2eDebugHook -HookUrl $CoreDebugHookUrl.Trim() -Command 'logmark' -Message $text
        }
        catch {
            Write-Host "[WARN] Core logmark skipped: $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($MailAgentDebugUrl)) {
        try {
            $null = Add-MailAgentE2eLogMark -Message $text -BaseUrl $MailAgentDebugUrl
        }
        catch {
            Write-Host "[WARN] Mail agent logmark skipped: $($_.Exception.Message)"
        }
    }
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
    $inputCount = '?'
    $outCount = '?'
    if ($null -ne $counts) {
        if ($counts.PSObject.Properties['SanitizationInput']) {
            $inputCount = [string]$counts.SanitizationInput
        }
        if ($counts.PSObject.Properties['SanitizationOutput']) {
            $outCount = [string]$counts.SanitizationOutput
        }
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

    $openInbound = $null
    if ($null -ne $Status.PSObject.Properties['openInboundSmtpSessions']) {
        $openInbound = $Status.openInboundSmtpSessions
    }

    $inboundSan = $null
    if ($null -ne $Status.PSObject.Properties['inboundSanitizationsInProgress']) {
        $inboundSan = $Status.inboundSanitizationsInProgress
    }

    $spoolBacklog = $null
    if ($null -ne $Status.PSObject.Properties['inboundSpoolBacklog']) {
        $spoolBacklog = $Status.inboundSpoolBacklog
    }

    return ("core={0} connecting={1} phase={2} inboundListening={3} ports={4} openInboundSmtpSessions={5} inboundSanitizationsInProgress={6} SanitizationInput={7} outboundQueue={8} sanitizationOutputFiles={9} inboundSpoolBacklog={10} temp={11}" -f `
        $conn, $connecting, $phase, $Status.inboundSmtpListening, $portText, $openInbound, $inboundSan, `
        $inputCount, $Status.outboundQueueDepth, $outCount, $spoolBacklog, $Status.tempFolderRoot)
}

function Assert-MailAgentE2eLabRelayEnvironment {
    param(
        [string] $RelayName = 'mail',
        [switch] $FailOnScanAgent
    )

    $relay = if ([string]::IsNullOrWhiteSpace($RelayName)) { 'mail' } else { $RelayName.Trim() }
    $scanNames = @('Resec.Agent.ScanAgent', 'ReZoneScanAgent')
    $running = @()
    foreach ($name in $scanNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            $running += $name
        }
    }

    if ($running.Count -gt 0) {
        $msg = "Scan Agent process(es) running ($($running -join ', ')). Scan Agent cannot handle mail PutFile; stop it during mail E2E or ensure relay '$relay' is registered only on the mail agent."
        if ($FailOnScanAgent) {
            throw $msg
        }
        Write-Host "[WARN] $msg"
    }
}

function Test-MailAgentE2eRelayPutFileStall {
    param($Status)

    if ($null -eq $Status) {
        return $false
    }

    $counts = $Status.tempFolderFileCounts
    $inputCount = 0
    if ($null -ne $counts -and $counts.PSObject.Properties['SanitizationInput']) {
        $inputCount = [int]$counts.SanitizationInput
    }

    $openInbound = 0
    if ($null -ne $Status.PSObject.Properties['openInboundSmtpSessions']) {
        $openInbound = [int]$Status.openInboundSmtpSessions
    }

    $inboundSan = 0
    if ($null -ne $Status.PSObject.Properties['inboundSanitizationsInProgress']) {
        $inboundSan = [int]$Status.inboundSanitizationsInProgress
    }

    $outQueue = 0
    if ($null -ne $Status.PSObject.Properties['outboundQueueDepth']) {
        $outQueue = [int]$Status.outboundQueueDepth
    }

    if ($openInbound -gt 2 -or $inputCount -gt 3) {
        return $false
    }

    return ($openInbound -gt 0 -or $inboundSan -gt 0) -and $inputCount -gt 0 -and $outQueue -eq 0
}

function Clear-MailAgentE2eInboundTempFolders {
    param(
        [Parameter(Mandatory)]
        [string] $TempRoot
    )

    $root = $TempRoot.Trim().TrimEnd('\', '/')
    foreach ($name in @('SanitizationInput', 'SmtpInboundSpool', 'SanitizationOutput', 'SmtpFailed')) {
        $dir = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }

        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Prepare-MailAgentE2eFreshInboundLab {
    param(
        [string] $BaseUrl = '',
        [string] $TempFolderOverride = '',
        [string] $CoreDebugHookUrl = '',
        [string] $TestId = 'MA-01'
    )

    $tempRoot = Get-MailAgentE2eDefaultLabTempFolder -Override $TempFolderOverride
    if (Test-MailAgentDebugHookAvailable -BaseUrl $BaseUrl) {
        try {
            $st = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
            if (-not [string]::IsNullOrWhiteSpace([string]$st.tempFolderRoot)) {
                $tempRoot = [string]$st.tempFolderRoot
            }
        }
        catch {
        }
    }

    $counts = $null
    if (Test-MailAgentDebugHookAvailable -BaseUrl $BaseUrl) {
        try {
            $st = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
            $counts = $st.tempFolderFileCounts
        }
        catch {
        }
    }

    $needClean = $true
    if ($null -ne $counts) {
        $total = 0
        foreach ($name in @('SanitizationInput', 'SmtpInboundSpool', 'SanitizationOutput', 'SmtpFailed')) {
            if ($counts.PSObject.Properties[$name]) {
                $total += [int]$counts.$name
            }
        }
        $needClean = ($total -gt 0)
    }

    if (-not $needClean) {
        return
    }

    Write-Host "[INFO] Mail E2E: stopping mail agent and clearing inbound temp backlog under $tempRoot."
    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark "prepare | stop agent + clear temp backlog ($tempRoot)" `
        -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $BaseUrl
    Stop-MailAgentE2eDesktopAgents
    Start-Sleep -Seconds 2
    Clear-MailAgentE2eInboundTempFolders -TempRoot $tempRoot
    $script:MailAgentE2eProcessEnsureAttempted = $false
}

function Test-MailAgentLogTailShowsLabPolicyApplied {
    param(
        [string[]] $TailLines
    )

    if ($null -eq $TailLines -or $TailLines.Count -eq 0) {
        return $false
    }

    $blob = ($TailLines -join [Environment]::NewLine)
    return ($blob -match '(?i)Email agent configuration applied from Resec Core policy') -or `
        ($blob -match '(?i)ReturnImmediateResponse\)\s+is\s+disabled')
}

function Test-MailAgentLogTailShowsPolicyApplyStalled {
    <#
      True when the agent reached session default but never finished FlowManager policy apply
      (typical when agentcomm nudge disconnects during the first connect handshake).
    #>
    param(
        [string[]] $TailLines
    )

    if ($null -eq $TailLines -or $TailLines.Count -lt 2) {
        return $false
    }

    $blob = ($TailLines -join [Environment]::NewLine)
    if (Test-MailAgentLogTailShowsLabPolicyApplied -TailLines $TailLines) {
        return $false
    }

    $sessionDefault = $blob -match '(?i)Current policy set to \d+ \(session default\)'
    $pastSyslog = $blob -match '(?i)cannot enable syslog: syslogHost is empty'
    $readySignals = ($blob -match '(?i)\*\*\* CONNECTED to Resec Core Server') -or `
        ($blob -match '(?i)Policy logger created') -or `
        ($blob -match '(?i)SMTP timeouts:')
    return ($sessionDefault -and $pastSyslog -and -not $readySignals)
}

function Wait-MailAgentE2ePolicyAppliedInLog {
    param(
        [string] $BaseUrl = '',
        [int] $TimeoutSec = 90,
        [int] $TailLineCount = 400,
        [int] $ProgressIntervalSec = 5,
        [string] $CoreDebugHookUrl = '',
        [string] $TestId = 'MA-01'
    )

    $BaseUrl = Get-MailAgentDebugBaseUrl -Override $BaseUrl

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $nextProgress = [DateTimeOffset]::UtcNow
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $BaseUrl
        if (-not [string]::IsNullOrWhiteSpace($log) -and (Test-Path -LiteralPath $log)) {
            $tail = @(Get-Content -LiteralPath $log -Tail $TailLineCount -ErrorAction SilentlyContinue)
            if (Test-MailAgentLogTailShowsLabPolicyApplied -TailLines $tail) {
                Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark 'policy | mail agent log shows lab policy apply' `
                    -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $BaseUrl
                return
            }

            if ([DateTimeOffset]::UtcNow -ge $nextProgress) {
                $stall = Test-MailAgentLogTailShowsPolicyApplyStalled -TailLines $tail
                $hint = if ($stall) { 'stall after session default (defer agentcomm nudge until apply completes)' } else { 'waiting' }
                Write-MailAgentE2eCorrelationLogMark -TestId $TestId `
                    -Mark "policy | wait ${ProgressIntervalSec}s | $hint | tailLines=$($tail.Count)" `
                    -CoreDebugHookUrl $CoreDebugHookUrl -MailAgentDebugUrl $BaseUrl
                $nextProgress = [DateTimeOffset]::UtcNow.AddSeconds($ProgressIntervalSec)
            }
        }
        Start-Sleep -Seconds 2
    }

    throw "Mail agent did not log lab policy apply within ${TimeoutSec}s (tail $TailLineCount lines). Confirm assignment rule mail_agent and Relay Settings facet; avoid agentcomm nudge during first policy apply."
}

function Ensure-MailAgentE2eLabPolicyOnAgent {
    param(
        [string] $BaseUrl = '',
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $TestId = 'MA-01',
        [int] $InitialWaitSec = 20,
        [int] $AfterNudgeWaitSec = 90
    )

    $BaseUrl = Get-MailAgentDebugBaseUrl -Override $BaseUrl

    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark 'policy | wait for first connect apply (no nudge yet)' `
        -CoreDebugHookUrl $HookUrl -MailAgentDebugUrl $BaseUrl

    try {
        Wait-MailAgentE2ePolicyAppliedInLog -BaseUrl $BaseUrl -CoreDebugHookUrl $HookUrl -TestId $TestId `
            -TimeoutSec $InitialWaitSec -ProgressIntervalSec 5
        return
    }
    catch {
        Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark "policy | first connect apply timeout; agentcomm nudge | $($_.Exception.Message)" `
            -CoreDebugHookUrl $HookUrl -MailAgentDebugUrl $BaseUrl
    }

    Invoke-MailAgentE2eAgentCommNudge -HookUrl $HookUrl
    $null = Wait-MailAgentDebugReady -BaseUrl $BaseUrl
    Write-MailAgentE2eCorrelationLogMark -TestId $TestId -Mark 'policy | post-nudge wait for apply' `
        -CoreDebugHookUrl $HookUrl -MailAgentDebugUrl $BaseUrl
    Wait-MailAgentE2ePolicyAppliedInLog -BaseUrl $BaseUrl -CoreDebugHookUrl $HookUrl -TestId $TestId `
        -TimeoutSec $AfterNudgeWaitSec -ProgressIntervalSec 5
}

function Assert-MailAgentE2ePolicyFromAgentLog {
    param(
        [string] $BaseUrl = '',
        [string] $NextHopHost = '127.0.0.1',
        [int] $NextHopPort = 26,
        [int] $TailLineCount = 400
    )

    $BaseUrl = Get-MailAgentDebugBaseUrl -Override $BaseUrl

    $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $BaseUrl
    if ([string]::IsNullOrWhiteSpace($log) -or -not (Test-Path -LiteralPath $log)) {
        throw 'Mail agent debug logpath unavailable; cannot confirm Send Immediate Response off / next hop from policy apply.'
    }

    $tail = @(Get-Content -LiteralPath $log -Tail $TailLineCount -ErrorAction Stop)
    $blob = ($tail -join [Environment]::NewLine)

  # SmtpListener logs: "... (ReturnImmediateResponse) is disabled." — parentheses break naive "is disabled" patterns.
    $sirOffPatterns = @(
        '(?i)ReturnImmediateResponse\)\s+is\s+disabled'
        '(?i)Send Immediate Response is off'
        '(?i)Waiting for email to finish processing before SMTP reply \(Send Immediate Response is off\)'
    )
    $sirOff = $false
    foreach ($pattern in $sirOffPatterns) {
        if ($blob -match $pattern) {
            $sirOff = $true
            break
        }
    }
    if (-not $sirOff) {
        if ($blob -match '(?i)ReturnImmediateResponse\)\s+is\s+enabled') {
            throw 'Mail agent log shows Send Immediate Response on (ReturnImmediateResponse enabled). Lab policy was not applied — check policy import, relay name, and agentcomm nudge.'
        }
        throw 'Mail agent log does not show Send Immediate Response off (expected listener line with ReturnImmediateResponse) is disabled. Lab policy may not be applied — check relay name and agentcomm nudge.'
    }

    $hopPattern = [regex]::Escape($NextHopHost)
    $hopOk = $blob -match $hopPattern
    if (-not $hopOk -and $NextHopPort -gt 0) {
        $hopOk = $blob -match "(?i)Addresses:\s*${hopPattern}:${NextHopPort}"
    }
    if (-not $hopOk) {
        throw "Mail agent log does not reference next hop '$NextHopHost' (port $NextHopPort). Verify lab policy import and FlowManager next-hop logging after policy apply."
    }
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

function Get-MailAgentE2eWindowsServiceName {
    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_MAIL_AGENT_SERVICE_NAME)) {
        return $env:MAIL_E2E_MAIL_AGENT_SERVICE_NAME.Trim()
    }

    foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '(?i)mail' -and $_.DisplayName -match '(?i)resec'
        })) {
        return [string]$svc.Name
    }

    return $null
}

function Restart-MailAgentE2eWindowsServiceOrProcess {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $MailAgentDebugUrl = '',
        [string] $MailAgentExePath = '',
        [int] $ExpectedInboundPort = 0,
        [int] $StartupTimeoutSec = 90
    )

    $serviceName = Get-MailAgentE2eWindowsServiceName
    if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
        Write-MailAgentE2eAutostartStep "Restarting mail agent Windows service '$serviceName' (MA-02 B)."
        Restart-Service -Name $serviceName -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        $null = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugUrl -ExpectedInboundPort $ExpectedInboundPort `
            -TimeoutSec $StartupTimeoutSec
        return
    }

    Write-Host '[WARN] Mail agent Windows service not found; restarting desktop Resec.Agent.Mail process (set MAIL_E2E_MAIL_AGENT_SERVICE_NAME for service-based labs).'
    Stop-MailAgentE2eDesktopAgents -AgentExePath $MailAgentExePath
    Start-Sleep -Seconds 2
    $ensure = Ensure-MailAgentE2eProcessRunning -CallingScriptRoot $CallingScriptRoot -BaseUrl $MailAgentDebugUrl `
        -MailAgentExePath $MailAgentExePath -ExpectedInboundPort $ExpectedInboundPort `
        -StartupTimeoutSec $StartupTimeoutSec
    if (-not $ensure.Process) {
        throw 'MA-02 B: could not restart mail agent after process stop.'
    }
}

function Invoke-MailAgentE2eListenPortSoak {
    param(
        [string] $ComputerName = '127.0.0.1',
        [Parameter(Mandatory)]
        [int] $Port,
        [string] $BaseUrl = '',
        [int] $TotalMinutes = 15,
        [int] $IntervalMinutes = 5,
        [string] $Context = 'MA-02 E',
        [string] $CoreDebugHookUrl = ''
    )

    if ($IntervalMinutes -le 0) {
        $IntervalMinutes = 5
    }

    $checks = [Math]::Max(1, [int][Math]::Floor($TotalMinutes / $IntervalMinutes) + 1)
    for ($i = 0; $i -lt $checks; $i++) {
        if ($i -gt 0) {
            Start-Sleep -Seconds ($IntervalMinutes * 60)
        }
        Write-MailAgentE2eAutostartStep "$Context listen check $($i + 1)/$checks (${ComputerName}:$Port)."
        Assert-MailAgentE2eInboundSmtpPortListening -ComputerName $ComputerName -Port $Port -BaseUrl $BaseUrl `
            -Context "$Context check $($i + 1)"
        if (-not [string]::IsNullOrWhiteSpace($CoreDebugHookUrl)) {
            Assert-CoreE2eDatabaseSimulationActive -HookUrl $CoreDebugHookUrl -Context "$Context check $($i + 1) dbsimulate"
        }
    }
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

function Repair-MailAgentE2eOrphanInboundTempWhenIdle {
    param(
        [string] $BaseUrl = '',
        [string] $Context = 'orphan inbound temp cleanup'
    )

    $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
    if ([int]$status.openInboundSmtpSessions -gt 0 -or [int]$status.inboundSanitizationsInProgress -gt 0) {
        Write-Host "[INFO] $Context - skip temp repair (open sessions or active sanitizations)."
        return $false
    }

    $tempRoot = [string]$status.tempFolderRoot
    if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        return $false
    }

    $counts = $status.tempFolderFileCounts
    $hadBacklog = $false
    foreach ($name in @('SanitizationInput', 'SmtpInboundSpool')) {
        $reported = 0
        if ($null -ne $counts -and $null -ne $counts.PSObject.Properties[$name]) {
            $reported = [int]$counts.PSObject.Properties[$name].Value
        }
        $onDisk = Get-MailAgentE2eOnDiskTempFileCount -FolderPath (Join-Path $tempRoot $name)
        if ($reported -gt 0 -or $onDisk -gt 0) {
            $hadBacklog = $true
        }
    }

    if (-not $hadBacklog) {
        return $false
    }

    Write-Host "[INFO] $Context - clearing orphan files under SanitizationInput and SmtpInboundSpool."
    Clear-MailAgentE2eInboundTempFolders -TempRoot $tempRoot
    Start-Sleep -Seconds 2
    return $true
}

function Wait-MailAgentE2eIdleTempFolders {
    param(
        [string] $BaseUrl = '',
        [int] $TimeoutSec = 60,
        [string] $Context = 'temp folders must be idle'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            return Assert-MailAgentE2eIdleTempFolders -BaseUrl $BaseUrl -Context $Context
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 400
        }
    }

    throw "Timed out after ${TimeoutSec}s waiting for idle temp folders ($Context). Last: $lastError"
}

function Get-MailAgentE2eOnDiskTempFileCount {
    param(
        [Parameter(Mandatory)][string] $FolderPath
    )

    if (-not [System.IO.Directory]::Exists($FolderPath)) {
        return 0
    }

    return @(
        Get-ChildItem -LiteralPath $FolderPath -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.EndsWith('.tmp', [System.StringComparison]::OrdinalIgnoreCase) }
    ).Count
}

function Test-MailAgentE2eStatusShowsInFlightSanitization {
    param($Status)

    if ($null -eq $Status) {
        return $false
    }

    if ($null -ne $Status.PSObject.Properties['inboundSanitizationsInProgress']) {
        if ([int]$Status.inboundSanitizationsInProgress -gt 0) {
            return $true
        }
    }

    if ($null -ne $Status.PSObject.Properties['openInboundSmtpSessions']) {
        if ([int]$Status.openInboundSmtpSessions -gt 0) {
            return $true
        }
    }

    $counts = $Status.tempFolderFileCounts
    if ($null -ne $counts) {
        foreach ($name in @('SanitizationInput', 'SanitizationOutput', 'SmtpInboundSpool')) {
            $prop = $counts.PSObject.Properties[$name]
            if ($null -ne $prop -and [int]$prop.Value -gt 0) {
                return $true
            }
        }
    }

    return $false
}

function Wait-MailAgentE2eBurstInFlight {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [int] $TimeoutSec = 90,
        [int] $PollSec = 2,
        [string] $Context = 'MA-02 B'
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
        if (Test-MailAgentE2eStatusShowsInFlightSanitization -Status $status) {
            Write-Host "[INFO] $Context - in-flight work observed: $(Format-MailAgentDebugStatusSummary -Status $status)"
            return $status
        }
        Start-Sleep -Seconds $PollSec
    }

    throw "$Context - no in-flight sanitization observed within ${TimeoutSec}s (agent debug status); cannot time agent restart on active load."
}

function Assert-MailAgentE2eInboundSmtpPortListening {
    param(
        [string] $ComputerName = '127.0.0.1',
        [Parameter(Mandatory)]
        [int] $Port,
        [string] $BaseUrl = '',
        [string] $Context = 'inbound SMTP listen port check'
    )

    $tn = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
    if (-not $tn.TcpTestSucceeded) {
        throw "$Context - Test-NetConnection to ${ComputerName}:${Port} failed."
    }

    $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
    if ($status.inboundSmtpListening -ne $true) {
        throw "$Context - debug status inboundSmtpListening=false. $(Format-MailAgentDebugStatusSummary -Status $status)"
    }
}

function Assert-MailAgentE2eIdleTempFolders {
    param(
        [string] $BaseUrl = '',
        [string] $Context = 'temp folders must be idle'
    )

    $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $BaseUrl
    $counts = $status.tempFolderFileCounts
    if ($null -eq $counts) {
        throw "$Context - status did not include tempFolderFileCounts."
    }

    $tempRoot = $null
    $tempProp = $status.PSObject.Properties['tempFolderRoot']
    if ($null -ne $tempProp -and -not [string]::IsNullOrWhiteSpace([string]$tempProp.Value)) {
        $tempRoot = [string]$tempProp.Value
    }

    foreach ($name in @('SanitizationInput', 'SanitizationOutput', 'SmtpInboundSpool', 'SmtpFailed')) {
        $prop = $counts.PSObject.Properties[$name]
        if ($null -eq $prop) {
            continue
        }
        $value = [int]$prop.Value
        $onDisk = $null
        if (-not [string]::IsNullOrWhiteSpace($tempRoot)) {
            $onDisk = Get-MailAgentE2eOnDiskTempFileCount -FolderPath (Join-Path $tempRoot $name)
        }

        if ($value -ne 0 -and $null -ne $onDisk -and $onDisk -eq 0) {
            Write-Host "[INFO] $Context - $name debug count=$value but on-disk=$onDisk; treating as idle."
            continue
        }

        if ($value -ne 0 -or ($null -ne $onDisk -and $onDisk -ne 0)) {
            $diskNote = if ($null -eq $onDisk) { '' } else { " onDisk=$onDisk" }
            throw "$Context - $name count=$value (expected 0)$diskNote. $(Format-MailAgentDebugStatusSummary -Status $status)"
        }
    }

    return $status
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
