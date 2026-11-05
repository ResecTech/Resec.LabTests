#Requires -Version 5.1
<#
.SYNOPSIS
  Sets user-level (and current-process) environment variables to a product executable path for lab E2E.

.DESCRIPTION
  Used by product post-build targets and lab deploy scripts. Also emits RESEC_LAB_DEPLOY_EXE_ENV for Lab Test Runner.
  Dot-source Set-ResecLabExeLocationUserEnv.Function.ps1 when you only need the function.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ExePath,

    [Parameter(Mandatory)]
    [string[]] $EnvironmentVariableNames,

    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Set-ResecLabExeLocationUserEnv.Function.ps1')

Set-ResecLabExeLocationUserEnv -ExePath $ExePath -EnvironmentVariableNames $EnvironmentVariableNames -Quiet:$Quiet
