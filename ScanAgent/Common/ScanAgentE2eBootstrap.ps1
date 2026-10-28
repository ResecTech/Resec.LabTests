#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source from an E2E script to load Common helpers into the script scope (PS 5.1).

.EXAMPLE
  . (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
#>
param(
    [Parameter(Mandatory)]
    [string] $CallingScriptRoot,
    [string] $ScanAgentDebug = '',
    [string] $ScanAgentExe = ''
)

$script:SaE2eCallingScriptRoot = $CallingScriptRoot
$script:SaE2eScanAgentDebug = $ScanAgentDebug
$script:SaE2eScanAgentExe = $ScanAgentExe
if ([string]::IsNullOrWhiteSpace($script:SaE2eScanAgentExe)) {
    $script:SaE2eScanAgentExe = 'C:\Program Files\Resec Technologies\Resec Scan Agent\Resec.Agent.ScanAgent.exe'
}

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')

$commonRoot = Join-Path (Split-Path $CallingScriptRoot -Parent) 'Common'
foreach ($name in @(
        'ScanAgentE2eFixtures.ps1',
        'ScanAgentE2eEmbeddedPolicyBase.ps1',
        'ScanAgentE2ePs51.ps1',
        'ScanAgentE2eDestination.ps1',
        'Report-ScanAgentTestPlatformResult.ps1',
        'ScanAgentE2eDebug.ps1',
        'ScanAgentE2eNavigation.ps1',
        'ScanAgentE2eCorePolicy.ps1'
    )) {
    $path = Join-Path $commonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "E2E common script not found: $path"
    }
    . $path
}

Initialize-ScanAgentE2eTestPlatformFromLabConfig
