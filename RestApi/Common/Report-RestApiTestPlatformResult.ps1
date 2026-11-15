#Requires -Version 5.1
Set-StrictMode -Version Latest

$coreReport = Join-Path (Split-Path $PSScriptRoot -Parent) '..\Core\Common\Report-CoreE2eTestPlatformResult.ps1'
if (-not (Test-Path -LiteralPath $coreReport)) {
    throw "Core test platform report script not found: $coreReport"
}
. $coreReport

function Get-RestApiE2eReportExePath {
    if (Get-Command -Name 'Resolve-RestApiE2eExePath' -ErrorAction SilentlyContinue) {
        $exe = Resolve-RestApiE2eExePath
        if ((Test-Path -LiteralPath $exe -PathType Leaf)) {
            return $exe
        }
    }

    foreach ($name in @('RESEC_RESTAPI_EXE_LOCATION', 'LAB_RESTAPI_EXE')) {
        $raw = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $raw = [Environment]::GetEnvironmentVariable($name, 'User')
        }
        if (-not [string]::IsNullOrWhiteSpace($raw) -and (Test-Path -LiteralPath $raw.Trim() -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($raw.Trim())
        }
    }

    $default = 'C:\Program Files\Resec Technologies\Resec Rest API\Resec.Agent.RestAPI.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf) {
        return $default
    }

    return $null
}

function Ensure-RestApiE2eComponentVersionRegistered {
    if (-not [string]::IsNullOrWhiteSpace($env:TESTPLATFORM_COMPONENT_VERSION)) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RESTAPI_COMPONENT_VERSION)) {
        $env:TESTPLATFORM_COMPONENT_VERSION = $env:RESTAPI_COMPONENT_VERSION.Trim()
        return $true
    }

    $exe = Get-RestApiE2eReportExePath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        return $false
    }

    try {
        $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($ver)) {
            return $false
        }

        $env:RESTAPI_COMPONENT_VERSION = $ver
        $env:TESTPLATFORM_COMPONENT_VERSION = $ver
        return $true
    }
    catch {
        return $false
    }
}