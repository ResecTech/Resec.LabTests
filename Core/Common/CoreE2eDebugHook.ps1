#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook helpers for repo-based E2E (ready, policy stack, sanitize).
.NOTES
  Requires AppSettings EnableDebugInterface = True on Core.
  Default hook URL: env CORE_E2E_DEBUG_HOOK_URL, else https://localhost:4504/debug/hook
#>
Set-StrictMode -Version Latest

$script:CoreE2eStartedByScenario = $false
$script:CoreE2eAutoStartLogPath = $null
$script:CoreE2eAutoStartErrLogPath = $null
$script:CoreE2eDebugTlsBypassEnabled = $false
$script:CoreE2eDebugHookReadyPollTimeoutSec = 5
$script:CoreE2eDebugHookReadyWaitPollTimeoutSec = 120

function Enable-CoreE2eDebugTlsBypass {
    if ($script:CoreE2eDebugTlsBypassEnabled) {
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not ('CoreE2eDebugTrustAllCerts' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class CoreE2eDebugTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ReferencedAssemblies 'System.Net.Requests'
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object CoreE2eDebugTrustAllCerts
    $script:CoreE2eDebugTlsBypassEnabled = $true
}

function Get-CoreE2eDebugHookUrl {
    param([string] $Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_DEBUG_HOOK_URL)) {
        return $env:CORE_E2E_DEBUG_HOOK_URL.Trim()
    }

    return 'https://localhost:4504/debug/hook'
}

function Invoke-CoreE2eRestMethod {
    param(
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [string] $Method,
        [byte[]] $Body,
        [string] $ContentType,
        [int] $TimeoutSec = 300
    )

    $irmParams = @{
        Uri         = $Uri
        Method      = $Method
        TimeoutSec  = $TimeoutSec
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $irmParams.SkipCertificateCheck = $true
    }
    else {
        Enable-CoreE2eDebugTlsBypass
    }

    if ($Body) {
        $irmParams.Body = $Body
        $irmParams.ContentType = $ContentType
    }

    return Invoke-RestMethod @irmParams
}

function Invoke-CoreE2eDebugHook {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Command,
        [hashtable] $BodyObject,
        [string] $Message,
        [int] $TimeoutSec = 300
    )

    if ($BodyObject) {
        $payload = $BodyObject.Clone()
        $payload['command'] = $Command
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $payload['message'] = $Message
        }
        $json = $payload | ConvertTo-Json -Depth 80 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-CoreE2eRestMethod -Uri $HookUrl -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
    }

    $separator = if ($HookUrl.Contains('?')) { '&' } else { '?' }
    $queryParts = @('command=' + [uri]::EscapeDataString($Command))
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $queryParts += 'message=' + [uri]::EscapeDataString($Message)
    }

    $uri = '{0}{1}{2}' -f $HookUrl, $separator, ($queryParts -join '&')
    return Invoke-CoreE2eRestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec
}

function Write-CoreE2eDebugLogMark {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Mark,
        [string] $Step,
        [switch] $PassThru
    )

    $text = if ([string]::IsNullOrWhiteSpace($Step)) { $Mark } else { "$Step | $Mark" }
    $response = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'logmark' -Message $text
    Assert-CoreE2eDebugHookResponse -Response $response -Step "logmark ($text)"

    if ($PassThru) {
        return $response
    }
}

function Assert-CoreE2eDebugHookResponse {
    param(
        [Parameter(Mandatory)]
        $Response,
        [Parameter(Mandatory)]
        [string] $Step
    )

    if ($null -eq $Response) {
        throw "Core debug hook $Step returned no response."
    }

    if ($Response.PSObject.Properties.Name -contains 'error' -and -not [string]::IsNullOrWhiteSpace([string]$Response.error)) {
        throw "Core debug hook $Step failed: $($Response.error)"
    }
}

function Test-CoreE2eCoreInstallDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $dir = [System.IO.Path]::GetDirectoryName($ExePath)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return $false
    }

    foreach ($configName in @(
            'appsettings.json'
            'AppSettings.json'
            'appsettings.windows.json'
            'appsettings.linux.json'
            'AppSettings.example.json'
        )) {
        $configPath = Join-Path $dir $configName
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            return $true
        }
    }

    return $false
}

function Ensure-CoreE2eCoreAppSettingsBesideExe {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $dir = [System.IO.Path]::GetDirectoryName($ExePath)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return
    }

    $target = Join-Path $dir 'appsettings.json'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        return
    }

    foreach ($templateName in @('AppSettings.example.json', 'appsettings.windows.json')) {
        $template = Join-Path $dir $templateName
        if (Test-Path -LiteralPath $template -PathType Leaf) {
            Copy-Item -LiteralPath $template -Destination $target -Force
            Write-CoreE2eStep "Created appsettings.json from $templateName for lab auto-start"
            return
        }
    }
}

function Get-CoreE2eLabCoreExePathFromEnvironment {
    foreach ($name in @('RESEC_CORE_EXE_LOCATION', 'LAB_CORE_EXE', 'CORE_E2E_CORE_EXE')) {
        foreach ($scope in @('User', 'Process', 'Machine')) {
            $raw = [Environment]::GetEnvironmentVariable($name, $scope)
            if ([string]::IsNullOrWhiteSpace($raw)) {
                continue
            }

            try {
                $full = [System.IO.Path]::GetFullPath($raw.Trim())
            }
            catch {
                continue
            }

            if (Test-Path -LiteralPath $full -PathType Leaf) {
                return $full
            }
        }
    }

    return $null
}

function Test-CoreE2eCoreExePathUsable {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath,
        [switch] $RequireAppSettings
    )

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        return $false
    }

    if ($RequireAppSettings -and -not (Test-CoreE2eCoreInstallDirectory -ExePath $ExePath)) {
        return $false
    }

    if ($ExePath -match '\\artifacts\\') {
        return $false
    }

    return $true
}

function Resolve-CoreE2eCoreExePath {
    param([string] $Override = '')

    $attempts = New-Object System.Collections.Generic.List[string]

    $ordered = @(
        $(if (-not [string]::IsNullOrWhiteSpace($Override)) { [System.IO.Path]::GetFullPath($Override.Trim()) })
        $(Get-CoreE2eLabCoreExePathFromEnvironment)
    )

    $labDeployPath = Join-Path $PSScriptRoot '..\..\Common\LabDeployExeLocation.ps1'
    if (-not (Get-Command Find-ResecLabDeployExecutable -ErrorAction SilentlyContinue)) {
        . ([System.IO.Path]::GetFullPath($labDeployPath))
    }

    $fromProduction = Resolve-CoreE2eCoreExePathFromLabProductionRoot
    if (-not [string]::IsNullOrWhiteSpace($fromProduction)) {
        $ordered += $fromProduction
    }

    $searchRoots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_CORE_REPO_ROOT)) {
        $null = $searchRoots.Add([System.IO.Path]::GetFullPath($env:LAB_CORE_REPO_ROOT.Trim()))
    }

    if (Get-Command Get-LabProductRepoRoot -ErrorAction SilentlyContinue) {
        try {
            $null = $searchRoots.Add([System.IO.Path]::GetFullPath((Get-LabProductRepoRoot -Product Core)))
        }
        catch {
        }
    }

    if ($searchRoots.Count -eq 0) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $siblingCore = [System.IO.Path]::GetFullPath((Join-Path $labTestsRoot '..\Resec.Core.Server'))
        if (Test-Path -LiteralPath $siblingCore -PathType Container) {
            $null = $searchRoots.Add($siblingCore)
        }
    }

    foreach ($repoRoot in @($searchRoots.ToArray())) {
        $fromRepo = Find-ResecLabDeployExecutable -SearchRoots @($repoRoot) `
            -ExecutableFileNames @('Resec.Core.exe')
        if (-not [string]::IsNullOrWhiteSpace($fromRepo)) {
            $ordered += $fromRepo
        }
    }

    foreach ($candidate in @($ordered | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $null = $attempts.Add($candidate)
        if (Test-CoreE2eCoreExePathUsable -ExePath $candidate -RequireAppSettings) {
            return $candidate
        }
    }

    $listed = ($attempts.ToArray() | Select-Object -Unique) -join '; '
    throw @"
No runnable Core install found (Resec.Core.exe directory must contain appsettings.json; artifacts\ builds are ignored).
Checked, in order: RESEC_CORE_EXE_LOCATION / LAB_CORE_EXE / CORE_E2E_CORE_EXE (User, then Process), lab deploy under LAB_PRODUCTION_ROOT, then repo search.
Paths tried: $listed
Set RESEC_CORE_EXE_LOCATION to your bin output (e.g. ...\bin\26.2\Debug\Resec.Core.exe) and ensure appsettings.json exists beside the exe.
"@
}

function Resolve-CoreE2eCoreExePathFromLabProductionRoot {
    if ([string]::IsNullOrWhiteSpace($env:LAB_PRODUCTION_ROOT)) {
        return $null
    }

    $fixturesPath = Join-Path $PSScriptRoot '..\..\Common\LabTestDeployFixtures.ps1'
    $fixturesFull = [System.IO.Path]::GetFullPath($fixturesPath)
    if (-not (Get-Command Get-LabDeployLocalBuilds -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path -LiteralPath $fixturesFull)) {
            return $null
        }

        . $fixturesFull
    }

    if (-not (Get-Command Find-ResecLabDeployExecutable -ErrorAction SilentlyContinue)) {
        $labDeployPath = Join-Path $PSScriptRoot '..\..\Common\LabDeployExeLocation.ps1'
        . ([System.IO.Path]::GetFullPath($labDeployPath))
    }

    $builds = Get-LabDeployLocalBuilds -ProductionDownloadRoot $env:LAB_PRODUCTION_ROOT -DeployScriptId 'Core'
    foreach ($build in $builds) {
        $deployFolder = Get-LabDeployTargetFolder -BuildFolderPath $build.FolderPath
        $fromDeploy = Find-ResecLabDeployExecutable -SearchRoots @($deployFolder) `
            -ExecutableFileNames @('Resec.Core.exe')
        if (-not [string]::IsNullOrWhiteSpace($fromDeploy)) {
            if (Test-CoreE2eCoreExePathUsable -ExePath $fromDeploy -RequireAppSettings) {
                return $fromDeploy
            }
        }
    }

    return $null
}

function Test-CoreE2eProcessRunning {
    return $null -ne (Get-Process -Name 'Resec.Core' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Write-CoreE2eStep {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Test-CoreE2eDebugHookRetryableFailure {
    param([Parameter(Mandatory)] [string] $Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    if ($Message -match 'actively refused|No connection could be made|Unable to connect|connection attempt failed|Unable to connect to the remote server|No such host is known|The operation has timed out|timed out|HttpClient\.Timeout|canceled due to the configured|The request was canceled') {
        return $true
    }

    return $false
}

function Test-CoreE2eDebugHookConnectionFailure {
    param([Parameter(Mandatory)] [string] $Message)

    return (Test-CoreE2eDebugHookRetryableFailure -Message $Message)
}

function Test-CoreE2eDebugHookReachable {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $TimeoutSec = $script:CoreE2eDebugHookReadyPollTimeoutSec
    )

    try {
        $response = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'ready' -TimeoutSec $TimeoutSec
        Assert-CoreE2eDebugHookResponse -Response $response -Step 'ready'
        return @{
            Reachable       = $true
            CoreInitialized = ($response.coreInitialized -eq $true)
            Response        = $response
        }
    }
    catch {
        $msg = $_.Exception.Message
        $inner = $_.Exception.InnerException
        while ($null -ne $inner) {
            $msg = "$msg $($inner.Message)"
            $inner = $inner.InnerException
        }

        if (Test-CoreE2eDebugHookConnectionFailure -Message $msg) {
            return @{
                Reachable       = $false
                CoreInitialized = $false
                Response        = $null
            }
        }

        throw
    }
}

function Ensure-CoreE2eServerRunning {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $CoreExe = ''
    )

    Write-CoreE2eStep 'Probing Core debug hook (command=ready)'
    $state = Test-CoreE2eDebugHookReachable -HookUrl $HookUrl
    if ($state.CoreInitialized) {
        Write-CoreE2eStep 'Core debug hook reports coreInitialized=true'
        return $state.Response
    }

    if ($state.Reachable) {
        Write-CoreE2eStep 'Core debug hook reachable; waiting for coreInitialized'
        return $null
    }

    if (Test-CoreE2eProcessRunning) {
        Write-CoreE2eStep 'Resec.Core process is already running; waiting for debug hook'
        return $null
    }

    $coreExePath = Resolve-CoreE2eCoreExePath -Override $CoreExe
    Ensure-CoreE2eCoreAppSettingsBesideExe -ExePath $coreExePath
    Write-CoreE2eStep "Starting Core: $coreExePath"
    Start-CoreE2eServerProcess -ExePath $coreExePath
    return $null
}

function Get-CoreE2eAutoStartProcessLogPath {
    return $script:CoreE2eAutoStartLogPath
}

function Get-CoreE2eAutoStartProcessLogPaths {
    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace($script:CoreE2eAutoStartLogPath)) {
        $paths += $script:CoreE2eAutoStartLogPath
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CoreE2eAutoStartErrLogPath)) {
        $paths += $script:CoreE2eAutoStartErrLogPath
    }
    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Start-CoreE2eServerProcess {
    param(
        [Parameter(Mandatory)]
        [string] $ExePath
    )

    $full = Resolve-CoreE2eCoreExePath -Override $ExePath
    $workDir = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($workDir)) {
        throw "Cannot determine working directory for Core exe: $full"
    }

    $baseName = "CoreE2e-autostart-{0}" -f [Guid]::NewGuid().ToString('N')
    $script:CoreE2eAutoStartLogPath = Join-Path $env:TEMP ("{0}.stdout.log" -f $baseName)
    $script:CoreE2eAutoStartErrLogPath = Join-Path $env:TEMP ("{0}.stderr.log" -f $baseName)
    Write-CoreE2eStep "Core process stdout log: $script:CoreE2eAutoStartLogPath"
    Write-CoreE2eStep "Core process stderr log: $script:CoreE2eAutoStartErrLogPath"

    $startParams = @{
        FilePath               = $full
        WorkingDirectory       = $workDir
        WindowStyle            = 'Hidden'
        PassThru               = $true
        RedirectStandardOutput = $script:CoreE2eAutoStartLogPath
        RedirectStandardError  = $script:CoreE2eAutoStartErrLogPath
    }

    $null = Start-Process @startParams
    $script:CoreE2eStartedByScenario = $true
}

function Wait-CoreE2eReady {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $TimeoutSec = 600,
        [string] $LogMarkStep,
        [bool] $AutoStartCore = $true,
        [switch] $SkipAutoStartCore,
        [switch] $SkipInitialAutoStart,
        [string] $CoreExe = ''
    )

    if ($SkipAutoStartCore) {
        $AutoStartCore = $false
    }

    $autoStartEnabled = $AutoStartCore

    if ($autoStartEnabled -and -not $SkipInitialAutoStart) {
        Ensure-CoreE2eServerRunning -HookUrl $HookUrl -CoreExe $CoreExe | Out-Null
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $hookReachableMarked = $false
    $autoStartRetried = $false
    $readyPollSec = $script:CoreE2eDebugHookReadyWaitPollTimeoutSec
    $lastWaitLogUtc = [DateTimeOffset]::UtcNow
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $r = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'ready' -TimeoutSec $readyPollSec
            Assert-CoreE2eDebugHookResponse -Response $r -Step 'ready'

            if (-not $hookReachableMarked -and -not [string]::IsNullOrWhiteSpace($LogMarkStep)) {
                Write-CoreE2eDebugLogMark -HookUrl $HookUrl -Step $LogMarkStep `
                    -Mark 'debug hook reachable, waiting for coreInitialized'
                $hookReachableMarked = $true
            }

            if ($r.coreInitialized -eq $true) {
                if (-not [string]::IsNullOrWhiteSpace($LogMarkStep)) {
                    Write-CoreE2eDebugLogMark -HookUrl $HookUrl -Step $LogMarkStep `
                        -Mark 'core startup complete (coreInitialized=true)'
                }

                return $r
            }

            if (([DateTimeOffset]::UtcNow - $lastWaitLogUtc).TotalSeconds -ge 30) {
                Write-CoreE2eStep 'Core debug hook reachable; still waiting for coreInitialized (startup can take several minutes)'
                $lastWaitLogUtc = [DateTimeOffset]::UtcNow
            }
        }
        catch {
            $msg = $_.Exception.Message
            $inner = $_.Exception.InnerException
            while ($null -ne $inner) {
                $msg = "$msg $($inner.Message)"
                $inner = $inner.InnerException
            }

            if (-not (Test-CoreE2eDebugHookRetryableFailure -Message $msg)) {
                throw
            }

            if ($autoStartEnabled -and -not $autoStartRetried) {
                $autoStartRetried = $true
                Ensure-CoreE2eServerRunning -HookUrl $HookUrl -CoreExe $CoreExe | Out-Null
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "Core did not report coreInitialized within ${TimeoutSec}s (command=ready). Check Core Serilog log or auto-start log from this run."
}

function Push-CoreE2ePolicyState {
    param([Parameter(Mandatory)][string] $HookUrl)

    $push = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'pushpolicystate'
    Assert-CoreE2eDebugHookResponse -Response $push -Step 'pushpolicystate'
    return $push
}

function Pop-CoreE2ePolicyState {
    param([Parameter(Mandatory)][string] $HookUrl)

    $pop = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'poppolicystate'
    Assert-CoreE2eDebugHookResponse -Response $pop -Step 'poppolicystate'
    return $pop
}

function Push-CoreE2eSystemPropertiesState {
    param([Parameter(Mandatory)][string] $HookUrl)

    $push = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'pushsystempropertystate'
    Assert-CoreE2eDebugHookResponse -Response $push -Step 'pushsystempropertystate'
    return $push
}

function Pop-CoreE2eSystemPropertiesState {
    param([Parameter(Mandatory)][string] $HookUrl)

    $pop = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'popsystempropertystate'
    Assert-CoreE2eDebugHookResponse -Response $pop -Step 'popsystempropertystate'
    return $pop
}

function Import-CoreE2eSystemProperties {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [array] $SystemProperties
    )

    $entries = @()
    foreach ($prop in @($SystemProperties)) {
        if ($null -eq $prop) { continue }
        $entries += @{
            name      = [string]$prop.name
            propValue = [string]$prop.propValue
        }
    }

    $import = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'importsystemproperties' -BodyObject @{
        systemProperties = $entries
    }
    Assert-CoreE2eDebugHookResponse -Response $import -Step 'importsystemproperties'
    return $import
}

function Set-CoreE2eLabAlertEmailSmtpSystemProperties {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [string] $SmtpServer = '127.0.0.1',
        [int] $SmtpPort = 2525,
        [string] $SenderAccount = 'core-lab-sender@127.0.0.1',
        [string] $SenderPassword = ''
    )

    return Import-CoreE2eSystemProperties -HookUrl $HookUrl -SystemProperties @(
        @{ name = 'AlertEmailSmtpServer'; propValue = $SmtpServer }
        @{ name = 'AlertEmailSmtpPort'; propValue = [string]$SmtpPort }
        @{ name = 'AlertEmailAccount'; propValue = $SenderAccount }
        @{ name = 'AlertEmailAccountPassword'; propValue = $SenderPassword }
    )
}

function Import-CoreE2ePolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [hashtable] $ImportBody
    )

    $import = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $ImportBody
    Assert-CoreE2eDebugHookResponse -Response $import -Step 'importpolicies'
    return $import
}

function Get-CoreE2eExportedPolicies {
    param([Parameter(Mandatory)][string] $HookUrl)

    $export = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'exportpolicystate'
    Assert-CoreE2eDebugHookResponse -Response $export -Step 'exportpolicystate'
    return @($export.policies)
}

function Resolve-CoreE2ePolicyIdByName {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $PolicyName
    )

    $policies = Get-CoreE2eExportedPolicies -HookUrl $HookUrl
    $match = @($policies | Where-Object { [string]$_.name -eq $PolicyName } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        $names = ($policies | ForEach-Object { [string]$_.name }) -join ', '
        throw "Policy '$PolicyName' not found after import. Policies: $names"
    }

    return [int]$match[0].id
}

function Invoke-CoreE2eSanitizeFile {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [int] $PolicyId,
        [string] $OutputPath = '',
        [int] $TimeoutSeconds = 300,
        [int] $DeploymentId = 0
    )

    $fullPath = [System.IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Sanitize input not found: $fullPath"
    }

    $body = [ordered]@{
        command        = 'sanitize'
        filePath       = $fullPath
        policyId       = $PolicyId
        timeoutSeconds = $TimeoutSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $body.outputPath = [System.IO.Path]::GetFullPath($OutputPath)
    }

    if ($DeploymentId -gt 0) {
        $body.deploymentId = $DeploymentId
    }

    $response = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'sanitize' -BodyObject $body -TimeoutSec ($TimeoutSeconds + 60)
    Assert-CoreE2eDebugHookResponse -Response $response -Step "sanitize ($([System.IO.Path]::GetFileName($fullPath)))"
    return $response
}

function Get-CoreE2eDebugLogPathEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    try {
        $response = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'logpath'
        $path = [string]$response.currentLogFilePath
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $path
        }
    }
    catch {
    }

    return $null
}

function New-CoreE2eFailureEvidenceZip {
    param(
        [Parameter(Mandatory)]
        [string[]] $Paths,
        [string] $Label = 'CoreE2e-evidence'
    )

    $existing = @($Paths | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_)
        })
    if (@($existing).Count -eq 0) {
        return $null
    }

    $zipPath = Join-Path $env:TEMP ("{0}-{1}.zip" -f $Label, [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $staging = Join-Path $env:TEMP ("{0}-stage-{1}" -f $Label, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        foreach ($raw in $existing) {
            $full = [System.IO.Path]::GetFullPath($raw)
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $destName = [System.IO.Path]::GetFileName($full)
                $counter = 0
                while (Test-Path -LiteralPath (Join-Path $staging $destName)) {
                    $counter++
                    $destName = '{0}-{1}{2}' -f [System.IO.Path]::GetFileNameWithoutExtension($full), $counter, [System.IO.Path]::GetExtension($full)
                }
                Copy-Item -LiteralPath $full -Destination (Join-Path $staging $destName) -Force
                continue
            }

            $folderName = [System.IO.Path]::GetFileName($full.TrimEnd('\', '/'))
            if ([string]::IsNullOrWhiteSpace($folderName)) {
                $folderName = 'evidence'
            }
            $destFolder = Join-Path $staging $folderName
            New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
            & robocopy.exe $full $destFolder /E /R:0 /W:0 /XF .ResecLock.loc /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "robocopy failed copying evidence folder '$full' (exit $LASTEXITCODE)."
            }
        }

        $archiveItems = @(Get-ChildItem -LiteralPath $staging -Force -ErrorAction SilentlyContinue)
        if ($archiveItems.Count -eq 0) {
            return $null
        }

        Compress-Archive -Path ($archiveItems | ForEach-Object { $_.FullName }) -DestinationPath $zipPath -Force
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $zipPath) {
        return $zipPath
    }

    return $null
}

function Resolve-CoreE2eFixtureRoot {
    param(
        [string] $Override,
        [Parameter(Mandatory)]
        [string] $CallingScriptDirectory,
        [string] $RelativeFromFixturesRoot = 'QR\NCP-7330'
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $full = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Fixture root not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_FIXTURE_ROOT)) {
        $full = [System.IO.Path]::GetFullPath($env:CORE_E2E_FIXTURE_ROOT.Trim())
        if (-not (Test-Path -LiteralPath $full)) {
            throw "CORE_E2E_FIXTURE_ROOT not found: $full"
        }
        return $full
    }

    if (-not (Get-Command Get-LabFixturesRoot -ErrorAction SilentlyContinue)) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        . (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
        . (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')
    }

    $full = Join-Path (Get-LabFixturesRoot) $RelativeFromFixturesRoot
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Fixture root not found: $full. Run Tools\GenerateQrTestFixtures or set CORE_E2E_FIXTURE_ROOT."
    }

    return [System.IO.Path]::GetFullPath($full)
}
