#Requires -Version 5.1
<#
  Shared helpers for lab deploy scripts: read/write .lab-deploy.json under TargetFolder.
  Dot-source from scripts in this folder: . (Join-Path $PSScriptRoot '_DeployState.ps1')
#>
Set-StrictMode -Version Latest

function Get-LabDeployStateFilePath {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder
    )

    $root = [System.IO.Path]::GetFullPath($TargetFolder)
    Join-Path $root '.lab-deploy.json'
}

function Get-LabDeployState {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder
    )

    $path = Get-LabDeployStateFilePath -TargetFolder $TargetFolder
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-LabDeployInstalled {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder,
        [string] $ProductName,
        [string] $BranchName,
        [string] $VersionName
    )

    $state = Get-LabDeployState -TargetFolder $TargetFolder
    if ($null -eq $state) {
        return $false
    }

    if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetFullPath($TargetFolder)) -PathType Container)) {
        return $false
    }

    $files = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetFullPath($TargetFolder)) -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.lab-deploy.json' })
    if ($files.Count -eq 0) {
        return $false
    }

    foreach ($pair in @(
            @{ Expected = $ProductName; Actual = [string]$state.product },
            @{ Expected = $BranchName; Actual = [string]$state.branch },
            @{ Expected = $VersionName; Actual = [string]$state.version })) {
        if ([string]::IsNullOrWhiteSpace($pair.Expected)) {
            continue
        }

        if (-not [string]::Equals($pair.Expected.Trim(), $pair.Actual.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    return $true
}

function Set-LabDeployState {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder,
        [Parameter(Mandatory)] [string] $ProductName,
        [Parameter(Mandatory)] [string] $BranchName,
        [Parameter(Mandatory)] [string] $VersionName
    )

    $targetPath = [System.IO.Path]::GetFullPath($TargetFolder)
    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }

    $payload = [ordered]@{
        product     = $ProductName
        branch      = $BranchName
        version     = $VersionName
        deployedUtc = [DateTime]::UtcNow.ToString('o')
    }

    $json = ($payload | ConvertTo-Json -Compress)
    $path = Get-LabDeployStateFilePath -TargetFolder $targetPath
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -Force -ErrorAction Stop
}

function Remove-LabDeployState {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder
    )

    $path = Get-LabDeployStateFilePath -TargetFolder $TargetFolder
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}
