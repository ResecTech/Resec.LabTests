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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common\LabTestDeployFixtures.ps1')

$product = if ([string]::IsNullOrWhiteSpace($ProductName)) { 'Mail' } else { $ProductName.Trim() }
$deployScriptId = 'Mail'
$targetPath = [System.IO.Path]::GetFullPath($TargetFolder)

switch ($Action) {
    'is_deployed' {
        $deployed = Test-LabDeployIsBuildDeployed -TargetFolder $targetPath -DeployScriptId $deployScriptId -ProductName $product -BranchName $BranchName -VersionName $VersionName
        Write-LabDeployRequirementFixtureJson -ComponentName $deployScriptId -Deployed $deployed
        if ($deployed) { exit 0 }
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
