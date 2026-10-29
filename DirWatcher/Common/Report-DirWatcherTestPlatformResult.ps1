#Requires -Version 5.1
Set-StrictMode -Version Latest

$coreReport = Join-Path (Split-Path $PSScriptRoot -Parent) '..\Core\Common\Report-CoreE2eTestPlatformResult.ps1'
if (-not (Test-Path -LiteralPath $coreReport)) {
    throw "Core test platform report script not found: $coreReport"
}
. $coreReport
