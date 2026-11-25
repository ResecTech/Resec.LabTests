#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-LabRuntimeToolsWinX64Directory {
    if (-not (Get-Command Get-LabTestsRoot -ErrorAction SilentlyContinue)) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        . (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-LabTestsRoot) 'Tools\runtime\win-x64'))
}

function Get-LabRuntimeToolExePath {
    param(
        [Parameter(Mandatory)]
        [string] $ExecutableFileName
    )

    $fullPath = Join-Path (Get-LabRuntimeToolsWinX64Directory) $ExecutableFileName
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($fullPath)
    }

    return $null
}