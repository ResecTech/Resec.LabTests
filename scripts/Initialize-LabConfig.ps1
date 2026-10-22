#Requires -Version 5.1
<#
.SYNOPSIS
  Creates config\lab.local.json from the example template when missing.
#>
[CmdletBinding()]
param(
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$example = Join-Path $root 'config\lab.local.json.example'
$target = Join-Path $root 'config\lab.local.json'

if (-not (Test-Path -LiteralPath $example)) {
    throw "Example config not found: $example"
}

if ((Test-Path -LiteralPath $target) -and -not $Force) {
    Write-Host "Config already exists: $target"
    return $target
}

Copy-Item -LiteralPath $example -Destination $target -Force
Write-Host "Created $target — edit product repoRoot paths for this machine."
return $target
