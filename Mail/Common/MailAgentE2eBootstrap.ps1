#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source from a Mail Agent E2E script to load Common helpers into script scope (PS 5.1).

.EXAMPLE
  . (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
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
        'MailAgentE2ePs51.ps1',
        'Report-MailAgentTestPlatformResult.ps1',
        'MailAgentE2eCoreDebug.ps1',
        'MailAgentE2eMailAgentDebug.ps1',
        'MailAgentE2eTestFiles.ps1',
        'MailAgentE2ePaths.ps1',
        'MailAgentE2eSimpleMailServer.ps1'
    )) {
    $path = Join-Path $commonRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "E2E common script not found: $path"
    }
    . $path
}
