#Requires -Version 5.1
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

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '_DeployState.ps1')

$product = if ([string]::IsNullOrWhiteSpace($ProductName)) { 'ScanAgent' } else { $ProductName.Trim() }
$targetPath = [System.IO.Path]::GetFullPath($TargetFolder)

switch ($Action) {
    'is_deployed' {
        if (Test-LabDeployInstalled -TargetFolder $targetPath -ProductName $product -BranchName $BranchName -VersionName $VersionName) {
            Write-Host "$product is deployed ($BranchName / $VersionName)"
            exit 0
        }

        Write-Host "$product is not deployed for ($BranchName / $VersionName)"
        exit 1
    }

    'un_deploy' {
        if (Test-Path -LiteralPath $targetPath -PathType Container) {
            Get-ChildItem -LiteralPath $targetPath -Force -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
        }

        Remove-LabDeployState -TargetFolder $targetPath
        Write-Host "Un-deploy placeholder for $product"
        exit 0
    }

    default {
        Write-Host "Deploy placeholder for $product ($BranchName / $VersionName)"
        Write-Host "SourceFolder: $SourceFolder"
        Write-Host "TargetFolder: $TargetFolder"
        Write-Host "version variable: $version"
        Set-LabDeployState -TargetFolder $targetPath -ProductName $product -BranchName $BranchName -VersionName $VersionName
        exit 0
    }
}
