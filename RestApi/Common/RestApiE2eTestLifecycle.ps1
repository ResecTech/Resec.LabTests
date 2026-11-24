#Requires -Version 5.1
<#
.SYNOPSIS
  Shared scenario state, Test Platform reporting, and exit code for REST API E2E scripts.
#>
Set-StrictMode -Version Latest

$coreLifecycle = Join-Path (Split-Path $PSScriptRoot -Parent) '..\Core\Common\CoreE2eTestLifecycle.ps1'
if (-not (Test-Path -LiteralPath $coreLifecycle)) {
    throw "Core E2E lifecycle script not found: $coreLifecycle"
}

. $coreLifecycle