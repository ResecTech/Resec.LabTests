#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  RA-01 / NCP-7372: REST API uses HKLM Resec registry for Core endpoint (not localhost default).

.DESCRIPTION
  Single-machine regression for NCP-7372:
    - Set HKLM\SOFTWARE\Resec Technologies\ServerAddress to the local computer name (not "localhost").
    - Start REST API and assert Gateway logs Communicator::Connect with that server address.
    - Assert GET api/v2/IsConnected returns true against the running Core on 11073.

  Prerequisites:
    - Core running and debug-ready (EnableDebugInterface); port 11073 accepting agent connections.
    - REST API build with registry/configurator fix (GatewayServerEndpointConfigurator).
    - Administrator (HKLM registry write).
    - RESEC_RESTAPI_EXE_LOCATION or installed REST API under Program Files.

.PARAMETER SkipAutoStartCore
  Do not start Core if the debug hook is unreachable (default: auto-start when possible).

.PARAMETER SkipCorePolicySetup
  Skip pushpolicystate / importpolicies / agentcomm nudge (default: install RA-01 rest_api lab policy).

.PARAMETER ServerAddress
  Override registry ServerAddress (default: COMPUTERNAME).

.PARAMETER CoreReadyTimeoutSec
  Max wait for Core debug hook command=ready (default 120; use 180 for cold auto-start).

.PARAMETER ConnectLogTimeoutSec
  Max wait for Gateway connect log after REST API start (default 45).

.PARAMETER IsConnectedTimeoutSec
  Max wait for api/v2/IsConnected (default 45).

.EXAMPLE
  .\RA-01-NCP7372-RegistryCoreEndpoint.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $RestApiExe = '',
    [string] $ServerAddress = '',
    [string] $RestApiBaseUrl = '',
    [string] $AuthorizationToken = '',
    [int] $CoreReadyTimeoutSec = 120,
    [int] $ConnectLogTimeoutSec = 45,
    [int] $IsConnectedTimeoutSec = 90,
    [switch] $SkipAutoStartCore,
    [switch] $SkipCorePolicySetup,
    [switch] $LeaveRestApiRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    $req = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-CoreDeployRequirements) + @(Get-RestApiDeployRequirements)) {
        $req.Add($item)
    }
    return $req.ToArray()
}

$script:RaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:RaE2eCommonRoot 'RestApiE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:TestId = 'RA-01'
$script:TestTitle = 'REST API registry Core endpoint (NCP-7372)'
$script:RaE2eReportScript = Join-Path $script:RaE2eCommonRoot 'Report-RestApiTestPlatformResult.ps1'
$env:TESTPLATFORM_COMPONENT_NAME = 'RestApi'

$hookUrl = $null
$restProc = $null
$registryBackup = $null
$expectedServer = $null
$connectEvidence = $null
$script:PolicyStackPushed = $false

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

try {
    if (-not (Test-RestApiE2eAdminForRegistry)) {
        throw 'This test must run elevated (#Requires -RunAsAdministrator) to set HKLM\SOFTWARE\Resec Technologies.'
    }

    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $exe = Resolve-RestApiE2eExePath -Override $RestApiExe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "REST API executable not found: $exe (set RESEC_RESTAPI_EXE_LOCATION)."
    }

    $expectedServer = Get-RestApiE2eExpectedServerAddress -Override $ServerAddress
    if ($expectedServer -match '^(?i)localhost$') {
        throw "ServerAddress must not be localhost for this test (got '$expectedServer')."
    }

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-TestStep "Waiting for Core ready: $hookUrl"
    $null = Wait-CoreE2eReady -HookUrl $hookUrl -LogMarkStep $script:TestId -SkipAutoStartCore:$SkipAutoStartCore `
        -TimeoutSec $CoreReadyTimeoutSec

    $ver = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version' -TimeoutSec 15
    if ($ver.version) {
        $env:CORE_COMPONENT_VERSION = [string]$ver.version
    }

    if (-not $SkipCorePolicySetup) {
        Write-TestStep "Core: install lab policy ($($script:Ra01LabPolicyName) -> agent_type rest_api)"
        Install-Ra01RestApiLabCorePolicy -HookUrl $hookUrl
        $script:PolicyStackPushed = $true
    }

    Write-TestStep "Backing up registry and setting ServerAddress=$expectedServer"
    $registryBackup = Get-RestApiE2eRegistryBackup
    Set-RestApiE2eRegistryCoreEndpoint -ServerAddress $expectedServer

    Write-TestStep 'Stopping any running REST API processes'
    Stop-RestApiE2eProcesses

    $startUtc = [DateTimeOffset]::UtcNow.UtcDateTime
    $restProc = Start-RestApiE2eProcess -ExePath $exe

    Write-TestStep "Waiting for Communicator::Connect log (expected serverAddresses contains '$expectedServer')"
    $connectEvidence = Wait-RestApiE2eGatewayConnectLine -ExpectedServerAddress $expectedServer `
        -StartedAfterUtc $startUtc -TimeoutSec $ConnectLogTimeoutSec
    Write-TestStep "Connect log OK: $($connectEvidence.LogLine)"

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: agentcomm nudge after REST API connect (reload policy on reconnect)'
        Invoke-Ra01RestApiAgentCommNudge -HookUrl $hookUrl
        Start-Sleep -Seconds 3
    }

    $baseUrl = if ([string]::IsNullOrWhiteSpace($RestApiBaseUrl)) { $script:RestApiE2eDefaultHttpsBase } else { $RestApiBaseUrl.Trim() }
    $authToken = if ([string]::IsNullOrWhiteSpace($AuthorizationToken)) { $script:RestApiE2eDefaultAuthToken } else { $AuthorizationToken.Trim() }

    Write-TestStep "Waiting for GET $baseUrl/api/v2/IsConnected"
    $null = Wait-RestApiE2eIsConnected -BaseUrl $baseUrl -AuthorizationToken $authToken -TimeoutSec $IsConnectedTimeoutSec
    Write-TestStep 'IsConnected returned true'

    $script:ScenarioPassed = $true
    Write-Host 'Scenario passed.'
    exit 0
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Host "[FAIL] $($_.Exception.Message)"
    Write-Error $_
    exit 1
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

    if ($null -ne $registryBackup) {
        try {
            if ($registryBackup.Count -gt 0) {
                Write-TestStep 'Restoring registry backup'
                Restore-RestApiE2eRegistryBackup -Backup $registryBackup
            }
            else {
                Write-TestStep 'Removing test registry values (no prior backup)'
                Remove-RestApiE2eRegistryCoreEndpointValues
            }
        }
        catch {
            Write-Warning "Registry restore failed: $($_.Exception.Message)"
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

    $evidence = @()
    if ($connectEvidence -and $connectEvidence.LogFile) {
        $evidence += $connectEvidence.LogFile
    }
    if ($script:E2eRunLogPath -and (Test-Path -LiteralPath $script:E2eRunLogPath)) {
        $evidence += $script:E2eRunLogPath
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:RaE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidence
}