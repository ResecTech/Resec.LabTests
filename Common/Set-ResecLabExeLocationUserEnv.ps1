#Requires -Version 5.1
<#
.SYNOPSIS
  Sets user-level (and current-process) environment variables to a product executable path for lab E2E.

.DESCRIPTION
  Used by product post-build targets and lab deploy scripts. Also emits RESEC_LAB_DEPLOY_EXE_ENV for Lab Test Runner.
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

$full = [System.IO.Path]::GetFullPath($ExePath.Trim())
if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    Write-Error "Executable not found: $full"
    exit 1
}

$names = @(
    $EnvironmentVariableNames |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

if ($names.Count -eq 0) {
    Write-Error 'At least one environment variable name is required.'
    exit 1
}

$markerPayload = [ordered]@{ }
foreach ($name in $names) {
    [Environment]::SetEnvironmentVariable($name, $full, 'User')
    Set-Item -Path "Env:$name" -Value $full -ErrorAction SilentlyContinue
    $markerPayload[$name] = $full
    if (-not $Quiet) {
        Write-Host "Set user env ${name}=$full"
    }
}

Write-Output ("RESEC_LAB_DEPLOY_EXE_ENV=" + ($markerPayload | ConvertTo-Json -Compress))
