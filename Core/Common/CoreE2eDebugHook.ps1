#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook helpers for repo-based E2E (ready, policy stack, sanitize).
.NOTES
  Requires AppSettings EnableDebugInterface = True on Core.
  Default hook URL: env CORE_E2E_DEBUG_HOOK_URL, else https://localhost:4504/debug/hook
#>
Set-StrictMode -Version Latest

$script:CoreE2eDebugTlsBypassEnabled = $false

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
        [int] $TimeoutSec = 300
    )

    if ($BodyObject) {
        $payload = $BodyObject.Clone()
        $payload['command'] = $Command
        $json = $payload | ConvertTo-Json -Depth 80 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-CoreE2eRestMethod -Uri $HookUrl -Method Post -Body $bytes `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
    }

    $separator = if ($HookUrl.Contains('?')) { '&' } else { '?' }
    $uri = '{0}{1}command={2}' -f $HookUrl, $separator, [uri]::EscapeDataString($Command)
    return Invoke-CoreE2eRestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec
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

function Wait-CoreE2eReady {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [int] $TimeoutSec = 300
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $r = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'ready'
        Assert-CoreE2eDebugHookResponse -Response $r -Step 'ready'
        if ($r.coreInitialized -eq $true) {
            return $r
        }
        Start-Sleep -Seconds 1
    }

    throw "Core did not report coreInitialized within ${TimeoutSec}s (command=ready)."
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
