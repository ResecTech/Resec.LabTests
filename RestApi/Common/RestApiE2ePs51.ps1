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

function Resolve-RestApiE2eExePath {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return (Resolve-RestApiE2eLaunchPath -CandidatePath $Override)
    }

    $fromEnv = Get-ResecLabExePathFromEnvironment -EnvironmentVariableNames @(
        'RESEC_RESTAPI_EXE_LOCATION',
        'LAB_RESTAPI_EXE'
    )
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return (Resolve-RestApiE2eLaunchPath -CandidatePath $fromEnv)
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
    foreach ($name in @('Resec.Agent.RestAPI.exe', 'Resec.Agent.RestAPI')) {
        Get-Process -Name ($name -replace '\.exe$', '') -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "[RestApiE2e] Stopping PID $($_.Id) ($name)"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }

    Start-Sleep -Seconds 2
}

function Start-RestApiE2eProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $launchPath = Resolve-RestApiE2eLaunchPath -CandidatePath $ExePath
    $workDir = Split-Path -Parent $launchPath
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
        throw "REST API working directory not found: $workDir"
    }

    Write-Host "[RestApiE2e] Starting: $launchPath"
    return Start-Process -FilePath $launchPath -WorkingDirectory $workDir -PassThru
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
        [int] $TimeoutSec = 60
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $uri = ($BaseUrl.TrimEnd('/')) + '/api/v2/IsConnected'
    $portDeadline = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Min(30, $TimeoutSec))
    $tlsPort = 8443
    if ($BaseUrl -match ':(\d+)') {
        $tlsPort = [int]$Matches[1]
    }

    while ([DateTimeOffset]::UtcNow -lt $portDeadline) {
        if (Get-NetTCPConnection -LocalPort $tlsPort -State Listen -ErrorAction SilentlyContinue) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $irmParams = @{
                Uri               = $uri
                Method            = 'Get'
                Headers           = @{ AuthorizationToken = $AuthorizationToken }
                TimeoutSec        = 10
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

        Start-Sleep -Seconds 1
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