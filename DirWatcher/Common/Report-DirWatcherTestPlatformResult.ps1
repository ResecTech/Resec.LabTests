#Requires -Version 5.1
Set-StrictMode -Version Latest

$coreReport = Join-Path (Split-Path $PSScriptRoot -Parent) '..\Core\Common\Report-CoreE2eTestPlatformResult.ps1'
if (-not (Test-Path -LiteralPath $coreReport)) {
    throw "Core test platform report script not found: $coreReport"
}
. $coreReport

function Get-DirWatcherE2eReportExePath {
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_DIRWATCHER_EXE)) {
        $fromEnv = [System.IO.Path]::GetFullPath($env:LAB_DIRWATCHER_EXE.Trim())
        if (Test-Path -LiteralPath $fromEnv -PathType Leaf) {
            return $fromEnv
        }
    }

    foreach ($procName in @('DirWatcher.exe', 'Resec.Agent.DirWatcher.exe')) {
        $proc = Get-CimInstance Win32_Process -Filter "Name='$procName'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $proc -or [string]::IsNullOrWhiteSpace($proc.ExecutablePath)) {
            continue
        }

        $exe = [System.IO.Path]::GetFullPath($proc.ExecutablePath.Trim())
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            return $exe
        }
    }

    foreach ($candidate in @(
            'C:\Program Files\Resec Technologies\Resec Directory Watcher\DirWatcher.exe',
            'C:\Program Files\Resec Technologies\Resec Directory Watcher\Resec.Agent.DirWatcher.exe'
        )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Ensure-DirWatcherE2eComponentVersionRegistered {
    if (-not [string]::IsNullOrWhiteSpace($env:TESTPLATFORM_COMPONENT_VERSION)) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DIRWATCHER_COMPONENT_VERSION)) {
        $env:TESTPLATFORM_COMPONENT_VERSION = $env:DIRWATCHER_COMPONENT_VERSION.Trim()
        return $true
    }

    $exe = Get-DirWatcherE2eReportExePath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        return $false
    }

    try {
        $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        if ([string]::IsNullOrWhiteSpace($ver)) {
            return $false
        }

        $env:DIRWATCHER_COMPONENT_VERSION = $ver
        $env:TESTPLATFORM_COMPONENT_VERSION = $ver
        return $true
    }
    catch {
        return $false
    }
}
