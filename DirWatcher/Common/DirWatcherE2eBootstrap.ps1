#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source from DirWatcher E2E scripts to load Common helpers (PS 5.1).

.EXAMPLE
  . (Join-Path $script:DwE2eCommonRoot 'DirWatcherE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
#>
param(
    [Parameter(Mandatory)]
    [string] $CallingScriptRoot
)

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')

$commonRoot = Join-Path (Split-Path $CallingScriptRoot -Parent) 'Common'
foreach ($name in @(
        'DirWatcherE2ePs51.ps1',
        'DirWatcherE2eCorePolicy.ps1',
        'Report-DirWatcherTestPlatformResult.ps1'
    )) {
    $path = Join-Path $commonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "E2E common script not found: $path"
    }
    . $path
}

$coreCommonRoot = Join-Path $labTestsRoot 'Core\Common'
foreach ($name in @('CoreE2eDebugHook.ps1')) {
    $path = Join-Path $coreCommonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Core E2E script not found: $path"
    }
    . $path
}

$scanAgentCommonRoot = Join-Path $labTestsRoot 'ScanAgent\Common'
foreach ($name in @('ScanAgentE2eCorePolicy.ps1')) {
    $path = Join-Path $scanAgentCommonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Scan Agent policy helper not found: $path"
    }
    . $path
}

$corePolicyHelper = Join-Path $coreCommonRoot 'CoreE2eNcp7344Policy.ps1'
if (-not (Test-Path -LiteralPath $corePolicyHelper)) {
    throw "Core policy helper not found: $corePolicyHelper"
}
. $corePolicyHelper
