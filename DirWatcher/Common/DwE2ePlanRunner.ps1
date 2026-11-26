#Requires -Version 5.1
<#
.SYNOPSIS
  Helpers for plan-level scripts (DW-01 … DW-04) that run ticket scripts in a child PowerShell process.
#>

function Invoke-DwE2eChildScript {
    param(
        [Parameter(Mandatory)]
        [string] $PlanPhaseLabel,

        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [string[]] $ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "DW plan child script not found: $ScriptPath"
    }

    Write-Host ''
    Write-Host "========== $PlanPhaseLabel =========="
    Write-Host "Running: $ScriptPath $($ArgumentList -join ' ')"
    Write-Host ''

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "${PlanPhaseLabel} failed (exit code $LASTEXITCODE)."
    }
}

function Write-DwManualPlanPhase {
    param(
        [Parameter(Mandatory)]
        [string] $PhaseId,

        [Parameter(Mandatory)]
        [string[]] $DoLines,

        [Parameter(Mandatory)]
        [string[]] $ExpectLines
    )

    Write-Host ''
    Write-Host "========== $PhaseId (manual) =========="
    Write-Host 'Do:'
    foreach ($line in $DoLines) {
        Write-Host "  - $line"
    }
    Write-Host 'Expect:'
    foreach ($line in $ExpectLines) {
        Write-Host "  - $line"
    }
    Write-Host ''
}