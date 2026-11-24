#Requires -Version 5.1
<#
.SYNOPSIS
  Helpers for NCP-7384 REST API token expiration E2E (WMC Rest_Api_Keys + appsettings).
#>
Set-StrictMode -Version Latest

function Get-RestApiE2eUtcDateString {
    param([int] $DayOffset = 0)

    return [DateTime]::UtcNow.Date.AddDays($DayOffset).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-RestApiE2eRestApiKeysTableJson {
    param(
        [Parameter(Mandatory)]
        [array] $Rows
    )

    $jsonRows = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $jsonRows.Add([ordered]@{
                index = $index
                Item1 = [string]$row.Name
                Item2 = [string]$row.Value
                Item3 = if ($null -ne $row.Expiration) { [string]$row.Expiration } else { '' }
            })
        $index++
    }

    if ($jsonRows.Count -eq 0) {
        return '[]'
    }

    return ($jsonRows.ToArray() | ConvertTo-Json -Compress)
}

function Set-CoreE2eRestApiKeysTable {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [array] $Rows = @()
    )

    $tableJson = if (@($Rows).Count -eq 0) { '[]' } else { New-RestApiE2eRestApiKeysTableJson -Rows $Rows }
    return Import-CoreE2eSystemProperties -HookUrl $HookUrl -SystemProperties @(
        @{ name = 'Rest_Api_Keys'; propValue = $tableJson }
    )
}

function Clear-CoreE2eRestApiKeysTable {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    return Import-CoreE2eSystemProperties -HookUrl $HookUrl -SystemProperties @(
        @{ name = 'Rest_Api_Keys'; propValue = '[]' }
    )
}

function Wait-RestApiE2eRestApiPipeReady {
    param(
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [int] $TimeoutSec = 25,
        [int] $PollIntervalMs = 250
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $probe = Invoke-RestApiE2eIsConnectedProbe -BaseUrl $BaseUrl -AuthorizationToken 'e2e-pipe-ready' -TimeoutSec 5
            if ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 600) {
                return
            }
        }
        catch {
            # TLS/socket not ready yet
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }

    throw "REST API did not accept HTTPS requests within ${TimeoutSec}s."
}

function Assert-RestApiE2eTokenExpirationBuild {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $LocalToken,
        [Parameter(Mandatory)]
        [string] $ExpiredOnUtcDate
    )

    $probe = Invoke-RestApiE2eIsConnectedProbe -BaseUrl $BaseUrl -AuthorizationToken $LocalToken -TimeoutSec 5
    if ($probe.StatusCode -eq 401) {
        return
    }

    if ($probe.StatusCode -eq 200) {
        throw @"
REST API build does not enforce AuthorizationTokenExpiration (got HTTP 200 for expired token).
Point -RestApiExe or RESEC_RESTAPI_EXE_LOCATION at a build that includes NCP-7384, e.g.:
  dotnet build Resec.Agent.REST_API.csproj -c Debug -p:Platform=x64 -p:UseAppHost=true
"@
    }

    throw "expiration build preflight: expected HTTP 401 for expired local token; got $($probe.StatusCode). Body: $($probe.Body)"
}

function Start-RestApiE2eForAuthProbe {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath,
        [hashtable] $ProcessEnvironment = @{},
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [int] $ListenTimeoutSec = 45,
        [int] $StopSettleMilliseconds = 800,
        [switch] $SkipPipeReadyWait
    )

    Stop-RestApiE2eProcesses -SettleMilliseconds $StopSettleMilliseconds
    $proc = Start-RestApiE2eProcess -ExePath $ExePath -ProcessEnvironment $ProcessEnvironment
    Wait-RestApiE2eHttpsListening -BaseUrl $BaseUrl -TimeoutSec $ListenTimeoutSec
    if (-not $SkipPipeReadyWait) {
        $pipeReadySec = [Math]::Min(25, [Math]::Max(10, $ListenTimeoutSec / 2))
        Wait-RestApiE2eRestApiPipeReady -BaseUrl $BaseUrl -TimeoutSec $pipeReadySec
    }

    return $proc
}