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
        [string] $BaseUrl = ''
    )

    $root = Get-MailAgentDebugBaseUrl -Override $BaseUrl
    $uri = '{0}/debug/hook?command={1}' -f $root, [Uri]::EscapeDataString($Command)

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in @('rest', 'curl')) {
        try {
            if ($attempt -eq 'rest') {
                return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing
            }

            $curlJson = Invoke-MailAgentDebugHookViaCurl -Uri $uri
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

function Invoke-MailAgentDebugHookViaCurl {
    param([Parameter(Mandatory)][string] $Uri)

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        return $null
    }

    $args = @('-sS', '--max-time', '10', $Uri)
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
