#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source from REST API E2E scripts to load Common helpers (PS 5.1).

.EXAMPLE
  . (Join-Path $script:RaE2eCommonRoot 'RestApiE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
#>
param(
    [Parameter(Mandatory)]
    [string] $CallingScriptRoot
)

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabDeployExeLocation.ps1')

$coreCommonRoot = Join-Path $labTestsRoot 'Core\Common'
foreach ($name in @('CoreE2eDebugHook.ps1', 'Report-CoreE2eTestPlatformResult.ps1')) {
    $path = Join-Path $coreCommonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Core E2E script not found: $path"
    }
    . $path
}

$commonRoot = Join-Path (Split-Path $CallingScriptRoot -Parent) 'Common'
foreach ($name in @(
        'RestApiE2ePs51.ps1',
        'RestApiE2eCorePolicy.ps1',
        'RestApiE2eAuthExpiration.ps1',
        'RestApiE2eTestLifecycle.ps1',
        'Report-RestApiTestPlatformResult.ps1'
    )) {
    $path = Join-Path $commonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "REST API E2E common script not found: $path"
    }
    . $path
}