#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7384: REST API service token and WMC Rest_Api_Keys optional expiration (E2E).

.DESCRIPTION
  Part A — WMC table keys (Rest_Api_Keys via Core importsystemproperties):
    - expired key (yesterday) -> 401 with 'expired'
    - active key (tomorrow) -> 200 IsConnected true
    - no-expiration key -> 200
    - unknown key -> 401

  Part B — appsettings AuthorizationToken via process environment override:
    - AuthorizationTokenExpiration yesterday -> 401 expired
    - AuthorizationTokenExpiration tomorrow -> 200

  Prerequisites: Core debug hook, REST API build with NCP-7384 expiration support, and existing REST API → Core
  binding (install/HKLM config). This script does not modify registry (see RA-01 for NCP-7372).

.PARAMETER SkipCorePolicySetup
  Skip RA-01 lab policy install when Core already assigns rest_api.

.EXAMPLE
  .\RA-7384-RestApiTokenExpiration.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed. Test Platform outcome follows $script:ScenarioPassed after reporting.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $RestApiExe = '',
    [string] $RestApiBaseUrl = '',
    [int] $CoreReadyTimeoutSec = 120,
    [int] $ListenTimeoutSec = 45,
    [int] $IsConnectedTimeoutSec = 45,
    [int] $IsConnectedPollMs = 400,
    [switch] $SkipAutoStartCore,
    [switch] $SkipCorePolicySetup,
    [switch] $LeaveRestApiRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:RaE2eCommonRoot 'RestApiE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

$script:TestId = 'RA-7384'
$script:TestTitle = 'REST API token expiration (NCP-7384)'
$script:RaE2eReportScript = Join-Path $script:RaE2eCommonRoot 'Report-RestApiTestPlatformResult.ps1'
$env:TESTPLATFORM_COMPONENT_NAME = 'RestApi'

$hookUrl = $null
$script:PolicyStackPushed = $false
$script:SystemPropertiesStackPushed = $false

Initialize-CoreE2eScenarioState -TestId $script:TestId

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

try {
    $exe = Resolve-RestApiE2eExePath -Override $RestApiExe -PreferRepoBuild:([string]::IsNullOrWhiteSpace($RestApiExe))
    Write-TestStep "REST API launch: $exe"
    $baseUrl = if ([string]::IsNullOrWhiteSpace($RestApiBaseUrl)) { $script:RestApiE2eDefaultHttpsBase } else { $RestApiBaseUrl.Trim() }

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-TestStep "Waiting for Core ready: $hookUrl"
    $null = Wait-CoreE2eReady -HookUrl $hookUrl -LogMarkStep $script:TestId -SkipAutoStartCore:$SkipAutoStartCore `
        -TimeoutSec $CoreReadyTimeoutSec

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: RA-01 lab policy (rest_api)'
        Install-Ra01RestApiLabCorePolicy -HookUrl $hookUrl
        $script:PolicyStackPushed = $true
    }

    Write-TestStep 'Core: pushsystempropertystate'
    Push-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
    $script:SystemPropertiesStackPushed = $true

    $yesterdayUtc = Get-RestApiE2eUtcDateString -DayOffset -1
    $tomorrowUtc = Get-RestApiE2eUtcDateString -DayOffset 1
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $expiredKey = "NCP7384-EXPIRED-$suffix"
    $activeKey = "NCP7384-ACTIVE-$suffix"
    $noExpKey = "NCP7384-NOEXP-$suffix"
    $localToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("NCP7384-LOCAL-$suffix"))
    $disabledLocalToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("NCP7384-DISABLED-LOCAL-$suffix"))

    Write-TestStep "Core: Rest_Api_Keys (expired=$yesterdayUtc active=$tomorrowUtc)"
    Set-CoreE2eRestApiKeysTable -HookUrl $hookUrl -Rows @(
        @{ Name = 'lab-expired'; Value = $expiredKey; Expiration = $yesterdayUtc }
        @{ Name = 'lab-active'; Value = $activeKey; Expiration = $tomorrowUtc }
        @{ Name = 'lab-no-exp'; Value = $noExpKey; Expiration = '' }
    ) | Out-Null

    Write-TestStep 'Start REST API (disable appsettings AuthorizationToken)'
    $null = Start-RestApiE2eForAuthProbe -ExePath $exe -ProcessEnvironment @{
        AuthorizationToken = $disabledLocalToken
    } -BaseUrl $baseUrl -ListenTimeoutSec $ListenTimeoutSec

    Write-TestStep 'Preflight: appsettings token expiration enforced'
    $null = Start-RestApiE2eForAuthProbe -ExePath $exe -ProcessEnvironment @{
        AuthorizationToken           = $localToken
        AuthorizationTokenExpiration = $yesterdayUtc
    } -BaseUrl $baseUrl -ListenTimeoutSec $ListenTimeoutSec
    Assert-RestApiE2eTokenExpirationBuild -BaseUrl $baseUrl -LocalToken $localToken -ExpiredOnUtcDate $yesterdayUtc

    $null = Start-RestApiE2eForAuthProbe -ExePath $exe -ProcessEnvironment @{
        AuthorizationToken = $disabledLocalToken
    } -BaseUrl $baseUrl -ListenTimeoutSec $ListenTimeoutSec

    Write-TestStep 'Wait for IsConnected with active WMC key'
    $null = Wait-RestApiE2eIsConnected -BaseUrl $baseUrl -AuthorizationToken $activeKey `
        -TimeoutSec $IsConnectedTimeoutSec -PollIntervalMs $IsConnectedPollMs

    Write-TestStep 'Assert WMC expired API key rejected'
    Assert-RestApiE2eIsConnectedAuth -Expect UnauthorizedExpired -BaseUrl $baseUrl `
        -AuthorizationToken $expiredKey -Context 'WMC expired key'

    Write-TestStep 'Assert WMC active API key accepted'
    Assert-RestApiE2eIsConnectedAuth -Expect Allow -BaseUrl $baseUrl -AuthorizationToken $activeKey `
        -Context 'WMC active key'

    Write-TestStep 'Assert WMC key without expiration accepted'
    Assert-RestApiE2eIsConnectedAuth -Expect Allow -BaseUrl $baseUrl -AuthorizationToken $noExpKey `
        -Context 'WMC no-expiration key'

    Write-TestStep 'Assert unknown API key rejected'
    Assert-RestApiE2eIsConnectedAuth -Expect Unauthorized -BaseUrl $baseUrl `
        -AuthorizationToken "NCP7384-UNKNOWN-$suffix" -Context 'unknown key'

    Write-TestStep 'Part B: clear WMC keys; test appsettings AuthorizationTokenExpiration'
    Clear-CoreE2eRestApiKeysTable -HookUrl $hookUrl | Out-Null

    Write-TestStep 'Start REST API with expired local AuthorizationToken'
    $null = Start-RestApiE2eForAuthProbe -ExePath $exe -ProcessEnvironment @{
        AuthorizationToken           = $localToken
        AuthorizationTokenExpiration = $yesterdayUtc
    } -BaseUrl $baseUrl -ListenTimeoutSec $ListenTimeoutSec

    Assert-RestApiE2eIsConnectedAuth -Expect UnauthorizedExpired -BaseUrl $baseUrl `
        -AuthorizationToken $localToken -Context 'appsettings expired local token'

    Write-TestStep 'Restart REST API with active local AuthorizationToken expiration'
    $null = Start-RestApiE2eForAuthProbe -ExePath $exe -ProcessEnvironment @{
        AuthorizationToken           = $localToken
        AuthorizationTokenExpiration = $tomorrowUtc
    } -BaseUrl $baseUrl -ListenTimeoutSec $ListenTimeoutSec

    $null = Wait-RestApiE2eIsConnected -BaseUrl $baseUrl -AuthorizationToken $localToken `
        -TimeoutSec $IsConnectedTimeoutSec -PollIntervalMs $IsConnectedPollMs

    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Host "[FAIL] $($_.Exception.Message)"
}
finally {
    if (-not $LeaveRestApiRunning) {
        try {
            Stop-RestApiE2eProcesses
        }
        catch {
            Write-Warning "Failed to stop REST API: $($_.Exception.Message)"
        }
    }

    if ($script:SystemPropertiesStackPushed -and $hookUrl) {
        try {
            Write-TestStep 'Core: popsystempropertystate'
            Pop-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "popsystempropertystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:PolicyStackPushed -and $hookUrl) {
        try {
            Write-TestStep 'Core: poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }
}

$evidence = @()
if (-not $script:ScenarioPassed -and $script:E2eRunLogPath -and (Test-Path -LiteralPath $script:E2eRunLogPath)) {
    $evidence += $script:E2eRunLogPath
}

Complete-CoreE2eScenario -ReportScriptPath $script:RaE2eReportScript `
    -TestId $script:TestId -TestTitle $script:TestTitle -EvidencePathsOnFailure $evidence

Exit-CoreE2eScenario