#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:MailAgentE2eTlsBypassInitialized = $false

function Initialize-MailAgentE2eTlsBypass {
    if ($script:MailAgentE2eTlsBypassInitialized) {
        return
    }

    $script:MailAgentE2eTlsBypassInitialized = $true
    # PS 5.1 + Core self-signed mgmt cert (lab only).
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-MailAgentCoreDebugBaseUrl {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_CORE_DEBUG_BASE_URL)) {
        return $env:MAIL_E2E_CORE_DEBUG_BASE_URL.TrimEnd('/')
    }

    return 'https://localhost:4504'
}

function Invoke-MailAgentCoreDebugHook {
    param(
        [Parameter(Mandatory)]
        [string] $Command,
        [string] $BaseUrl = ''
    )

    Initialize-MailAgentE2eTlsBypass
    $root = Get-MailAgentCoreDebugBaseUrl -Override $BaseUrl
    if ([string]::IsNullOrWhiteSpace($BaseUrl) -and $root -like 'https://*') {
        $candidates = @($root)
        $httpRoot = 'http://' + $root.Substring('https://'.Length)
        $candidates += $httpRoot
    }
    else {
        $candidates = @($root)
    }

    $lastError = $null
    foreach ($candidate in $candidates) {
        $uri = '{0}/debug/hook?command={1}' -f $candidate.TrimEnd('/'), [Uri]::EscapeDataString($Command)
        try {
            $curlJson = Invoke-MailAgentCoreDebugHookViaCurl -Uri $uri
            if ($null -ne $curlJson) {
                return $curlJson
            }

            return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing
        }
        catch {
            $lastError = $_
        }
    }

    throw $lastError
}

function Invoke-MailAgentCoreDebugHookViaCurl {
    param([Parameter(Mandatory)][string] $Uri)

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        return $null
    }

    $args = @('-sS', '--max-time', '10')
    if ($Uri -like 'https://*') {
        $args += '-k'
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

function Wait-MailAgentCoreReady {
    param(
        [string] $BaseUrl = '',
        [int] $TimeoutSec = 120,
        [int] $PollSec = 1
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $r = Invoke-MailAgentCoreDebugHook -Command 'ready' -BaseUrl $BaseUrl
            if ($r.coreInitialized -eq $true) {
                return $r
            }
        }
        catch {
        }
        Start-Sleep -Seconds $PollSec
    }

    throw "Core did not report coreInitialized=true within ${TimeoutSec}s (command=ready)."
}

function Set-MailAgentCoreAgentCommDown {
    param([string] $BaseUrl = '')
    return Invoke-MailAgentCoreDebugHook -Command 'commdown' -BaseUrl $BaseUrl
}

function Set-MailAgentCoreAgentCommUp {
    param([string] $BaseUrl = '')
    return Invoke-MailAgentCoreDebugHook -Command 'commup' -BaseUrl $BaseUrl
}
