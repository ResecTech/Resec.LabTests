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

function Test-LabDeployStateMatchesBuild {
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

    if (-not (Test-LabDeployFieldMatches -Expected $ProductName -Actual ([string]$state.product))) {
        return $false
    }

    if (-not (Test-LabDeployFieldMatches -Expected $BranchName -Actual ([string]$state.branch))) {
        return $false
    }

    if (-not (Test-LabDeployFieldMatches -Expected $VersionName -Actual ([string]$state.version) -Version)) {
        return $false
    }

    return $true
}

function Test-LabDeployHasPayloadFiles {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder
    )

    $root = [System.IO.Path]::GetFullPath($TargetFolder)
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue) {
        if ($file.Name -ne '.lab-deploy.json') {
            return $true
        }
    }

    return $false
}

function Test-LabDeployPlaceholderScriptId {
    param(
        [Parameter(Mandatory)] [string] $DeployScriptId
    )

    $id = $DeployScriptId.Trim()
    return [string]::Equals($id, 'ScanAgent', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($id, 'Mail', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($id, 'Core', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-LabDeployIsBuildDeployed {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder,
        [string] $DeployScriptId,
        [string] $ProductName,
        [string] $BranchName,
        [string] $VersionName
    )

    if (-not (Test-LabDeployStateMatchesBuild -TargetFolder $TargetFolder -ProductName $ProductName -BranchName $BranchName -VersionName $VersionName)) {
        return $false
    }

    if (Test-LabDeployHasPayloadFiles -TargetFolder $TargetFolder) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($DeployScriptId) -and (Test-LabDeployPlaceholderScriptId -DeployScriptId $DeployScriptId)) {
        return $true
    }

    return $false
}

function Test-LabDeployInstalled {
    param(
        [Parameter(Mandatory)] [string] $TargetFolder,
        [string] $ProductName,
        [string] $BranchName,
        [string] $VersionName
    )

    if (-not (Test-LabDeployStateMatchesBuild -TargetFolder $TargetFolder -ProductName $ProductName -BranchName $BranchName -VersionName $VersionName)) {
        return $false
    }

    return Test-LabDeployHasPayloadFiles -TargetFolder $TargetFolder
}

function Test-LabDeployVersionTokenEquivalent {
    param(
        [string] $Expected,
        [string] $Actual
    )

    $left = $Expected.Trim()
    $right = $Actual.Trim()
    if ([string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ($left.Length -gt 1 -and ($left[0] -eq 'V' -or $left[0] -eq 'v')) {
        $left = $left.Substring(1)
    }

    if ($right.Length -gt 1 -and ($right[0] -eq 'V' -or $right[0] -eq 'v')) {
        $right = $right.Substring(1)
    }

    return [string]::Equals($left, $right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-LabDeployFieldMatches {
    param(
        [string] $Expected,
        [string] $Actual,
        [switch] $Version
    )

    if ([string]::IsNullOrWhiteSpace($Expected)) {
        return $true
    }

    if ($Version) {
        return Test-LabDeployVersionTokenEquivalent -Expected $Expected -Actual $Actual
    }

    return [string]::Equals($Expected.Trim(), $Actual.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
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
