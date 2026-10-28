#Requires -Version 5.1
<#
  Evaluates Get-LabTestDeployRequirements for a test script against the production download root.
  Stdout: JSON array of { componentName, requiresRunning, state: { deployed, running } }.
  Exit 0 when all requirements are satisfied; exit 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TestScriptPath,
    [string] $ProductionDownloadRoot = $env:LAB_PRODUCTION_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $labTestsRoot 'Deploy\_DeployState.ps1')
. (Join-Path $PSScriptRoot 'LabTestDeployFixtures.ps1')

function ConvertTo-LabDeployFixtureReportJson {
    param(
        [object[]] $Fixtures
    )

    $items = @($Fixtures)
    if ($items.Count -eq 0) {
        return '[]'
    }

    $json = $items | ConvertTo-Json -Compress -Depth 5
    if ($items.Count -eq 1) {
        return "[$json]"
    }

    return $json
}

$readerScript = Join-Path $PSScriptRoot 'Read-LabTestDeployRequirements.ps1'
$reqJson = & $readerScript -TestScriptPath $TestScriptPath
if ([string]::IsNullOrWhiteSpace($reqJson)) {
    Write-Output '[]'
    exit 0
}

$requirements = @($reqJson | ConvertFrom-Json)
if ($requirements.Count -eq 0) {
    Write-Output '[]'
    exit 0
}

function New-FixtureReportForRequirements {
    param(
        [bool] $Deployed,
        [bool] $Running
    )

    $fixtures = New-Object System.Collections.Generic.List[object]
    foreach ($req in $requirements) {
        $componentName = [string]$req.deployScriptId
        if ([string]::IsNullOrWhiteSpace($componentName)) {
            continue
        }

        $requiresRunning = $false
        if ($req.PSObject.Properties.Name -contains 'requiresRunning') {
            $requiresRunning = [bool]$req.requiresRunning
        }

        $null = $fixtures.Add((New-LabDeployRequirementFixtureDto -ComponentName $componentName -RequiresRunning $requiresRunning -Deployed $Deployed -Running $Running))
    }

    return @($fixtures.ToArray())
}

if ([string]::IsNullOrWhiteSpace($ProductionDownloadRoot)) {
    Write-Output (ConvertTo-LabDeployFixtureReportJson -Fixtures (New-FixtureReportForRequirements -Deployed $false -Running $false))
    exit 1
}

$root = [System.IO.Path]::GetFullPath($ProductionDownloadRoot.Trim())
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Output (ConvertTo-LabDeployFixtureReportJson -Fixtures (New-FixtureReportForRequirements -Deployed $false -Running $false))
    exit 1
}

$report = New-Object System.Collections.Generic.List[object]
$satisfied = $true
foreach ($req in $requirements) {
    $componentName = [string]$req.deployScriptId
    if ([string]::IsNullOrWhiteSpace($componentName)) {
        continue
    }

    $requiresRunning = $false
    if ($req.PSObject.Properties.Name -contains 'requiresRunning') {
        $requiresRunning = [bool]$req.requiresRunning
    }

    $check = Test-LabDeployRequirementFixtureSatisfied -ProductionDownloadRoot $root -DeployScriptId $componentName -RequiresRunning $requiresRunning
    if (-not $check.Satisfied) {
        $satisfied = $false
    }

    $null = $report.Add((New-LabDeployRequirementFixtureDto -ComponentName $componentName -RequiresRunning $requiresRunning -Deployed $check.Deployed -Running $check.Running))
}

Write-Output (ConvertTo-LabDeployFixtureReportJson -Fixtures $report.ToArray())
if ($satisfied) {
    exit 0
}

exit 1
