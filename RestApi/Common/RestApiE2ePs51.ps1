#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:RestApiE2eDefaultLogRoot = 'C:\Resec\Logs\RestApi'
$script:RestApiE2eDefaultAuthToken = 'SWFtOlRva2Vu'
$script:RestApiE2eDefaultHttpsBase = 'https://127.0.0.1:8443'

function Get-RestApiE2eInstalledExeDefaultPath {
    return 'C:\Program Files\Resec Technologies\Resec Rest API\Resec.Agent.RestAPI.exe'
}

function Resolve-RestApiE2eLaunchPath {
    param(
        [Parameter(Mandatory)]
        [string] $CandidatePath
    )

    $full = [System.IO.Path]::GetFullPath($CandidatePath.Trim())
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "REST API executable not found: $full"
    }

    $extension = [System.IO.Path]::GetExtension($full)
    if ($extension -eq '.exe') {
        return $full
    }

    if ($extension -eq '.dll') {
        $exeBesideDll = [System.IO.Path]::ChangeExtension($full, '.exe')
        if (Test-Path -LiteralPath $exeBesideDll -PathType Leaf) {
            Write-Warning "REST API env pointed at '$full'; using apphost '$exeBesideDll' (rebuild REST API to fix RESEC_RESTAPI_EXE_LOCATION)."
            return $exeBesideDll
        }

        throw @"
REST API path is a .dll ($full); Windows cannot start it as a process (may open dotPeek/decompiler).
Use Resec.Agent.RestAPI.exe in the same folder, set RESEC_RESTAPI_EXE_LOCATION to the .exe, or rebuild Resec.Agent.RestAPI (post-build sets user env).
"@
    }

    throw "REST API launch path must be a .exe or .dll with a sibling apphost: $full"
}

function Get-RestApiE2eNewestRepoBuildExe {
    param([string] $RepoRoot = '')

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\Resec.Agent.REST_API'))
    }
    else {
        $repoRoot = [System.IO.Path]::GetFullPath($RepoRoot.Trim())
    }

    $binRoot = Join-Path $repoRoot 'src\Resec.Agent.RestAPI\bin'
    if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
        return $null
    }

    $candidates = @(Get-ChildItem -LiteralPath $binRoot -Recurse -Filter 'Resec.Agent.RestAPI.exe' -File -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        return $null
    }

  return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
}

function Resolve-RestApiE2eExePath {
    param(
        [string] $Override = '',
        [switch] $PreferRepoBuild
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return (Resolve-RestApiE2eLaunchPath -CandidatePath $Override)
    }

    if ($PreferRepoBuild) {
        $repoBuild = Get-RestApiE2eNewestRepoBuildExe
        if (-not [string]::IsNullOrWhiteSpace($repoBuild)) {
            return (Resolve-RestApiE2eLaunchPath -CandidatePath $repoBuild)
        }
    }

    $fromEnv = Get-ResecLabExePathFromEnvironment -EnvironmentVariableNames @(
        'RESEC_RESTAPI_EXE_LOCATION',
        'LAB_RESTAPI_EXE'
    )
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $resolvedEnv = Resolve-RestApiE2eLaunchPath -CandidatePath $fromEnv
        $repoBuild = Get-RestApiE2eNewestRepoBuildExe
        if (-not [string]::IsNullOrWhiteSpace($repoBuild)) {
            $envWrite = (Get-Item -LiteralPath $resolvedEnv).LastWriteTimeUtc
            $repoWrite = (Get-Item -LiteralPath $repoBuild).LastWriteTimeUtc
            if ($repoWrite -gt $envWrite) {
                Write-Warning "RESEC_RESTAPI_EXE_LOCATION is older than repo build; using '$repoBuild' (set -RestApiExe to pin)."
                return (Resolve-RestApiE2eLaunchPath -CandidatePath $repoBuild)
            }
        }

        return $resolvedEnv
    }

    $repoBuild = Get-RestApiE2eNewestRepoBuildExe
    if (-not [string]::IsNullOrWhiteSpace($repoBuild)) {
        return (Resolve-RestApiE2eLaunchPath -CandidatePath $repoBuild)
    }

    return (Resolve-RestApiE2eLaunchPath -CandidatePath (Get-RestApiE2eInstalledExeDefaultPath))
}

function Enable-RestApiE2eTlsBypass {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return
    }

    if (-not ('RestApiE2eTrustAllCerts' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class RestApiE2eTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ReferencedAssemblies 'System.Net.Requests'
    }

    [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object RestApiE2eTrustAllCerts
}

function Stop-RestApiE2eProcesses {
    param([int] $SettleMilliseconds = 2000)

    foreach ($name in @('Resec.Agent.RestAPI.exe', 'Resec.Agent.RestAPI')) {
        Get-Process -Name ($name -replace '\.exe$', '') -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "[RestApiE2e] Stopping PID $($_.Id) ($name)"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }

    if ($SettleMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $SettleMilliseconds
    }
}

function Set-RestApiE2eProcessEnvironment {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Values
    )

    $script:RestApiE2eSavedProcessEnvironment = @{}
    foreach ($key in $Values.Keys) {
        $script:RestApiE2eSavedProcessEnvironment[$key] = [Environment]::GetEnvironmentVariable([string]$key, 'Process')
        $newValue = $Values[$key]
        if ($null -eq $newValue) {
            [Environment]::SetEnvironmentVariable([string]$key, $null, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable([string]$key, [string]$newValue, 'Process')
        }
    }
}

function Restore-RestApiE2eProcessEnvironment {
    if (-not $script:RestApiE2eSavedProcessEnvironment) {
        return
    }

    foreach ($key in $script:RestApiE2eSavedProcessEnvironment.Keys) {
        $prior = $script:RestApiE2eSavedProcessEnvironment[$key]
        if ($null -eq $prior) {
            [Environment]::SetEnvironmentVariable([string]$key, $null, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable([string]$key, [string]$prior, 'Process')
        }
    }

    $script:RestApiE2eSavedProcessEnvironment = $null
}

function Wait-RestApiE2eHttpsListening {
    param(
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [int] $TimeoutSec = 60
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $tlsPort = 8443
    if ($BaseUrl -match ':(\d+)') {
        $tlsPort = [int]$Matches[1]
    }

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (Get-NetTCPConnection -LocalPort $tlsPort -State Listen -ErrorAction SilentlyContinue) {
            return
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Timed out waiting for REST API to listen on port $tlsPort (${TimeoutSec}s)."
}

function Get-RestApiE2eProbeFromWebCmdletError {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $body = ''
    if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
        $body = [string]$ErrorRecord.ErrorDetails.Message
    }

    $resp = $ErrorRecord.Exception.Response
    if ($null -eq $resp) {
        return $null
    }

    $status = 0
    if ($resp -is [System.Net.Http.HttpResponseMessage]) {
        $status = [int]$resp.StatusCode
        if ([string]::IsNullOrWhiteSpace($body)) {
            try {
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($body)) {
                    $body = $ErrorRecord.Exception.Message
                }
            }
        }
    }
    else {
        $status = [int]$resp.StatusCode
        if ([string]::IsNullOrWhiteSpace($body)) {
            try {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try {
                        $body = [string]$reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($body)) {
                    $body = $ErrorRecord.Exception.Message
                }
            }
        }
    }

    return [PSCustomObject]@{
        StatusCode = $status
        Body       = $body
    }
}

function Invoke-RestApiE2eIsConnectedProbe {
    param(
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [string] $AuthorizationToken = '',
        [int] $TimeoutSec = 8
    )

    $uri = ($BaseUrl.TrimEnd('/')) + '/api/v2/IsConnected'
    $headers = @{}
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $headers['User-Agent'] = 'Resec.LabTests.RestApiE2e'
    }

    if ($null -ne $AuthorizationToken) {
        $headers['AuthorizationToken'] = $AuthorizationToken
    }

    $iwrParams = @{
        Uri         = $uri
        Method      = 'Get'
        Headers     = $headers
        TimeoutSec  = $TimeoutSec
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $iwrParams.SkipCertificateCheck = $true
        $iwrParams.UseBasicParsing = $true
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Enable-RestApiE2eTlsBypass
        $iwrParams.UseBasicParsing = $true
    }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $response = Invoke-WebRequest @iwrParams -SkipHttpErrorCheck
        return [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            Body       = [string]$response.Content
        }
    }

    try {
        $response = Invoke-WebRequest @iwrParams
        return [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            Body       = [string]$response.Content
        }
    }
    catch {
        $parsed = Get-RestApiE2eProbeFromWebCmdletError -ErrorRecord $_
        if ($parsed) {
            return $parsed
        }

        throw
    }
}

function Assert-RestApiE2eIsConnectedAuth {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Allow', 'Unauthorized', 'UnauthorizedExpired')]
        [string] $Expect,
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [string] $AuthorizationToken = '',
        [string] $Context = ''
    )

    $probe = Invoke-RestApiE2eIsConnectedProbe -BaseUrl $BaseUrl -AuthorizationToken $AuthorizationToken
    $label = if ([string]::IsNullOrWhiteSpace($Context)) { 'IsConnected probe' } else { $Context }

    switch ($Expect) {
        'Allow' {
            if ($probe.StatusCode -ne 200) {
                throw "$label expected HTTP 200; got $($probe.StatusCode). Body: $($probe.Body)"
            }

            if ($probe.Body -notmatch '(?i)true') {
                throw "$label expected body 'true'; got: $($probe.Body)"
            }
        }
        'Unauthorized' {
            if ($probe.StatusCode -ne 401) {
                throw "$label expected HTTP 401; got $($probe.StatusCode). Body: $($probe.Body)"
            }
        }
        'UnauthorizedExpired' {
            if ($probe.StatusCode -ne 401) {
                throw "$label expected HTTP 401 (expired); got $($probe.StatusCode). Body: $($probe.Body)"
            }

            if ($probe.Body -notmatch '(?i)expired') {
                throw "$label expected 'expired' in response body; got: $($probe.Body)"
            }
        }
    }
}

function Start-RestApiE2eProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath,
        [hashtable] $ProcessEnvironment = @{}
    )

    if ($ProcessEnvironment.Count -gt 0) {
        Set-RestApiE2eProcessEnvironment -Values $ProcessEnvironment
    }

    $launchPath = Resolve-RestApiE2eLaunchPath -CandidatePath $ExePath
    $workDir = Split-Path -Parent $launchPath
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
        throw "REST API working directory not found: $workDir"
    }

    Write-Host "[RestApiE2e] Starting: $launchPath"
    try {
        return Start-Process -FilePath $launchPath -WorkingDirectory $workDir -PassThru
    }
    finally {
        if ($ProcessEnvironment.Count -gt 0) {
            Restore-RestApiE2eProcessEnvironment
        }
    }
}

function Get-RestApiE2eLogFiles {
    param(
        [string] $LogRoot = $script:RestApiE2eDefaultLogRoot,
        $NotOlderThanUtc = $null
    )

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'log-*.log' -File -ErrorAction SilentlyContinue)
    if ($NotOlderThanUtc) {
        $cutoffUtc = if ($NotOlderThanUtc -is [DateTimeOffset]) {
            $NotOlderThanUtc.UtcDateTime
        } else {
            [DateTime]::SpecifyKind([DateTime]$NotOlderThanUtc, [DateTimeKind]::Utc)
        }
        $files = @($files | Where-Object { $_.LastWriteTimeUtc -ge $cutoffUtc })
    }

    return @($files | Sort-Object LastWriteTimeUtc -Descending)
}

function ConvertFrom-RestApiE2eLogLineTimestamp {
    param([string] $Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    if ($Line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2})') {
        try {
            return ([DateTimeOffset]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
        }
        catch {
            return $null
        }
    }

    return $null
}

function Test-RestApiE2eLogLineAfterUtc {
    param(
        [string] $Line,
        [datetime] $StartedAfterUtc
    )

    $lineUtc = ConvertFrom-RestApiE2eLogLineTimestamp -Line $Line
    if (-not $lineUtc) {
        return $false
    }

    $cutoffUtc = [DateTime]::SpecifyKind($StartedAfterUtc, [DateTimeKind]::Utc)
    return $lineUtc -ge $cutoffUtc
}

function Wait-RestApiE2eGatewayConnectLine {
    param(
        [Parameter(Mandatory)]
        [string] $ExpectedServerAddress,
        [datetime] $StartedAfterUtc,
        [int] $TimeoutSec = 60,
        [string] $LogRoot = $script:RestApiE2eDefaultLogRoot
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $pattern = 'Communicator::Connect:.*serverAddresses\s*=\s*(.+)'
    $expected = $ExpectedServerAddress.Trim()

    $regressionEarliestUtc = [DateTimeOffset]::UtcNow.AddSeconds(8)

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $newestHit = $null
        $newestLineUtc = [DateTime]::MinValue

        foreach ($logFile in (Get-RestApiE2eLogFiles -LogRoot $LogRoot)) {
            $tail = @(Get-Content -LiteralPath $logFile.FullName -Tail 800 -ErrorAction SilentlyContinue)

            foreach ($line in $tail) {
                if ($line -notmatch $pattern) {
                    continue
                }
                if (-not (Test-RestApiE2eLogLineAfterUtc -Line $line -StartedAfterUtc $StartedAfterUtc)) {
                    continue
                }

                $lineUtc = ConvertFrom-RestApiE2eLogLineTimestamp -Line $line
                if (-not $lineUtc) {
                    continue
                }

                $addresses = $Matches[1].Trim()
                if ($lineUtc -ge $newestLineUtc) {
                    $newestLineUtc = $lineUtc
                    $newestHit = [PSCustomObject]@{
                        LogFile   = $logFile.FullName
                        LogLine   = $line.Trim()
                        Addresses = $addresses
                        LineUtc   = $lineUtc
                    }
                }
            }
        }

        if ($newestHit) {
            if ($newestHit.Addresses -match [regex]::Escape($expected)) {
                return $newestHit
            }

            if ([DateTimeOffset]::UtcNow -ge $regressionEarliestUtc -and
                $newestHit.Addresses -match '(?i)\blocalhost\b' -and
                $newestHit.Addresses -notmatch [regex]::Escape($expected)) {
                throw "REST API connected using localhost instead of registry/config. Log line: $($newestHit.LogLine)"
            }
        }

        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for REST API Communicator::Connect log with serverAddresses containing '$expected' (timeout ${TimeoutSec}s)."
}

function Wait-RestApiE2eIsConnected {
    param(
        [string] $BaseUrl = $script:RestApiE2eDefaultHttpsBase,
        [string] $AuthorizationToken = $script:RestApiE2eDefaultAuthToken,
        [int] $TimeoutSec = 60,
        [int] $PollIntervalMs = 1000,
        [int] $RequestTimeoutSec = 8
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $uri = ($BaseUrl.TrimEnd('/')) + '/api/v2/IsConnected'
    $portDeadline = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Min(20, $TimeoutSec))
    $tlsPort = 8443
    if ($BaseUrl -match ':(\d+)') {
        $tlsPort = [int]$Matches[1]
    }

    while ([DateTimeOffset]::UtcNow -lt $portDeadline) {
        if (Get-NetTCPConnection -LocalPort $tlsPort -State Listen -ErrorAction SilentlyContinue) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $irmParams = @{
                Uri               = $uri
                Method            = 'Get'
                Headers           = @{ AuthorizationToken = $AuthorizationToken }
                TimeoutSec        = $RequestTimeoutSec
                UseBasicParsing   = $true
            }

            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $irmParams.SkipCertificateCheck = $true
            }
            else {
                Enable-RestApiE2eTlsBypass
            }

            $body = Invoke-RestMethod @irmParams
            if ([string]$body -eq 'true' -or $body -eq $true) {
                return $true
            }
        }
        catch {
            # wait for Kestrel + Gateway init
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }

    throw "Timed out waiting for GET $uri to return true (${TimeoutSec}s)."
}

function Set-RestApiE2eRegistryCoreEndpoint {
    param(
        [Parameter(Mandatory)]
        [string] $ServerAddress,
        [string] $ServerPort = '11073',
        [string] $CheckServerCertificate = 'False'
    )

    $regPath = 'HKLM:\SOFTWARE\Resec Technologies'
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    Set-ItemProperty -LiteralPath $regPath -Name ServerAddress -Value $ServerAddress
    Set-ItemProperty -LiteralPath $regPath -Name ServerPort -Value $ServerPort
    Set-ItemProperty -LiteralPath $regPath -Name CheckServerCertificate -Value $CheckServerCertificate
}

function Get-RestApiE2eRegistryBackup {
    param([string] $RegPath = 'HKLM:\SOFTWARE\Resec Technologies')

    $backup = @{}
    if (-not (Test-Path -LiteralPath $RegPath)) {
        return $backup
    }

    foreach ($name in @('ServerAddress', 'ServerPort', 'CheckServerCertificate')) {
        $item = Get-ItemProperty -LiteralPath $RegPath -Name $name -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains $name)) {
            $backup[$name] = $item.$name
        }
    }

    return $backup
}

function Restore-RestApiE2eRegistryBackup {
    param(
        [hashtable] $Backup,
        [string] $RegPath = 'HKLM:\SOFTWARE\Resec Technologies'
    )

    if ($Backup.Count -eq 0) {
        return
    }

    if (-not (Test-Path -LiteralPath $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    foreach ($entry in $Backup.GetEnumerator()) {
        Set-ItemProperty -LiteralPath $RegPath -Name $entry.Key -Value $entry.Value
    }
}

function Remove-RestApiE2eRegistryCoreEndpointValues {
    param([string] $RegPath = 'HKLM:\SOFTWARE\Resec Technologies')

    if (-not (Test-Path -LiteralPath $RegPath)) {
        return
    }

    foreach ($name in @('ServerAddress', 'ServerPort', 'CheckServerCertificate')) {
        Remove-ItemProperty -LiteralPath $RegPath -Name $name -ErrorAction SilentlyContinue
    }
}

function Get-RestApiE2eExpectedServerAddress {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:RESTAPI_E2E_SERVER_ADDRESS)) {
        return $env:RESTAPI_E2E_SERVER_ADDRESS.Trim()
    }

    $name = [string]$env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'COMPUTERNAME is empty; pass -ServerAddress explicitly.'
    }

    return $name
}

function Test-RestApiE2eAdminForRegistry {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}