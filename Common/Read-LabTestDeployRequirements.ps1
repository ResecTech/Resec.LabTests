#Requires -Version 5.1
<#
  Reads Get-LabTestDeployRequirements from a test script without executing the test body.
  Used by Lab Test Runner (stdout: JSON array of { deployScriptId, requiresRunning }).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TestScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LabTestDeploySuiteDefaults.ps1')

function ConvertTo-DeployRequirementDtos {
    param([object] $Raw)

    if ($null -eq $Raw) {
        return @()
    }

    $items = @($Raw)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $results.Add([ordered]@{ deployScriptId = $item.Trim(); requiresRunning = $false })
            }

            continue
        }

        $id = $null
        if ($item.PSObject.Properties.Name -contains 'DeployScriptId') {
            $id = [string]$item.DeployScriptId
        }
        elseif ($item.PSObject.Properties.Name -contains 'deployScriptId') {
            $id = [string]$item.deployScriptId
        }

        if ([string]::IsNullOrWhiteSpace($id)) {
            continue
        }

        $requiresRunning = $false
        if ($item.PSObject.Properties.Name -contains 'RequiresRunning') {
            $requiresRunning = [bool]$item.RequiresRunning
        }
        elseif ($item.PSObject.Properties.Name -contains 'requiresRunning') {
            $requiresRunning = [bool]$item.requiresRunning
        }

        $results.Add([ordered]@{
            deployScriptId  = $id.Trim()
            requiresRunning = $requiresRunning
        })
    }

    return @($results.ToArray())
}

$resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestScriptPath)
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    Write-Output '[]'
    exit 0
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Output '[]'
    exit 0
}

$funcAst = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-LabTestDeployRequirements'
    }, $true))[0]

if ($null -eq $funcAst) {
    Write-Output '[]'
    exit 0
}

$testDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
$escapedDir = $testDir.Replace("'", "''")
$funcBody = $funcAst.Extent.Text
# Tests pass -ScriptRoot $PSScriptRoot; under Invoke-Expression $PSScriptRoot is not the test folder.
$funcBody = [regex]::Replace($funcBody, '\$PSScriptRoot', "'$escapedDir'")
$defineAndInvoke = @"
$funcBody
Get-LabTestDeployRequirements
"@

try {
    $raw = Invoke-Expression $defineAndInvoke
    $dtos = ConvertTo-DeployRequirementDtos -Raw $raw
    $dtos | ConvertTo-Json -Compress -Depth 4
}
catch {
    Write-Output '[]'
}
