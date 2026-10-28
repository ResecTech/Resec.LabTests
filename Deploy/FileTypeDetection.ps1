#Requires -Version 5.1
<#
.SYNOPSIS
  Deploy FileTypeDetection build artifacts from the FTP download folder into TargetFolder.

.DESCRIPTION
  Actions: deploy, is_deployed, un_deploy.
  deploy — finds FileTypeDetection.<version>.zip under SourceFolder, extracts to TargetFolder, writes .lab-deploy.json.
  is_deployed — exit 0 when state matches Product/Branch/Version and payload exists; else exit 1.
  un_deploy — removes deployed files and .lab-deploy.json under TargetFolder.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceFolder,
    [Parameter(Mandatory)] [string] $TargetFolder,
    [string] $ProductName,
    [string] $BranchName,
    [string] $VersionName,
    [ValidateSet('deploy', 'is_deployed', 'un_deploy')]
    [string] $Action = 'deploy'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateScript = Join-Path $PSScriptRoot '_DeployState.ps1'
if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
    throw "Missing deploy state helper: $stateScript"
}

. $stateScript
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common\LabTestDeployFixtures.ps1')

function Resolve-FtdPackageZipPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string] $RunnerVersion,
        [string] $SelectedVersionName
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "SourceFolder does not exist: $rootFull"
    }

    $candidateNames = [System.Collections.Generic.List[string]]::new()
    foreach ($ver in @($RunnerVersion, $SelectedVersionName)) {
        if ([string]::IsNullOrWhiteSpace($ver)) {
            continue
        }

        $trimmed = $ver.Trim()
        if ($candidateNames -notcontains $trimmed) {
            $candidateNames.Add($trimmed)
        }
    }

    foreach ($ver in $candidateNames) {
        $path = Join-Path $rootFull "FileTypeDetection.$ver.zip"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($path)
        }
    }

    $ftdZips = @(Get-ChildItem -LiteralPath $rootFull -Filter 'FileTypeDetection*.zip' -File -ErrorAction Stop)
    if ($ftdZips.Count -eq 1) {
        return $ftdZips[0].FullName
    }

    if ($ftdZips.Count -gt 1) {
        $listed = ($ftdZips | ForEach-Object { $_.Name }) -join ', '
        throw "Multiple FileTypeDetection*.zip files in '$rootFull' ($listed). Use a folder with one build zip."
    }

    $anyZip = @(Get-ChildItem -LiteralPath $rootFull -Filter '*.zip' -File -ErrorAction Stop)
    if ($anyZip.Count -eq 1) {
        return $anyZip[0].FullName
    }

    if ($anyZip.Count -gt 1) {
        throw "No FileTypeDetection*.zip in '$rootFull' and multiple other .zip files present."
    }

    throw "No .zip package found in SourceFolder: $rootFull"
}

function Clear-FolderContents {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $KeepStateFile
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    $statePath = Get-LabDeployStateFilePath -TargetFolder $Path
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if ($KeepStateFile -and $item.FullName -eq $statePath) {
            continue
        }

        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
}

$sourcePath = [System.IO.Path]::GetFullPath($SourceFolder)
$targetPath = [System.IO.Path]::GetFullPath($TargetFolder)
$runnerVersion = ''
if (Test-Path -Path 'Variable:\version') {
    $runnerVersion = [string]$version
}

$product = if ([string]::IsNullOrWhiteSpace($ProductName)) { 'FileTypeDetection' } else { $ProductName.Trim() }
$deployScriptId = 'FileTypeDetection'

switch ($Action) {
    'is_deployed' {
        $deployed = Test-LabDeployIsBuildDeployed -TargetFolder $targetPath -DeployScriptId $deployScriptId -ProductName $product -BranchName $BranchName -VersionName $VersionName
        Write-LabDeployRequirementFixtureJson -ComponentName $deployScriptId -Deployed $deployed
        if ($deployed) { exit 0 }
        exit 1
    }

    'un_deploy' {
        Write-Host "Removing FileTypeDetection deploy under $targetPath ..."
        Clear-FolderContents -Path $targetPath
        Remove-LabDeployState -TargetFolder $targetPath
        Write-Host 'Un-deploy complete.'
        exit 0
    }

    default {
        Write-Host "Deploy FileTypeDetection ($BranchName / $VersionName)"
        Write-Host "SourceFolder: $sourcePath"
        Write-Host "TargetFolder: $targetPath"

        $zipPath = Resolve-FtdPackageZipPath -Root $sourcePath -RunnerVersion $runnerVersion -SelectedVersionName $VersionName
        Write-Host "Package: $zipPath"

        Clear-FolderContents -Path $targetPath
        Write-Host "Extracting to $targetPath ..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $targetPath -Force

        Set-LabDeployState -TargetFolder $targetPath -ProductName $product -BranchName $BranchName -VersionName $VersionName

        $fileCount = @(Get-ChildItem -LiteralPath $targetPath -Recurse -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -ne '.lab-deploy.json' }).Count
        Write-Host "Done. $fileCount file(s) under TargetFolder."
        exit 0
    }
}
