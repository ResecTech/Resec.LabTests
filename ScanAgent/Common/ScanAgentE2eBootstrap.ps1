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

# Bump when shared Scan Agent E2E Common behavior changes (Core policy import, bootstrap, debug helpers).
$script:ScanAgentE2eLabBundleVersion = '2026.10.28.1'

function Get-ScanAgentE2eLabBundleGitRevision {
    param(
        [Parameter(Mandatory)]
        [string] $LabTestsRoot
    )

    if (-not (Test-Path -LiteralPath (Join-Path $LabTestsRoot '.git'))) {
        return $null
    }

    try {
        $sha = & git -C $LabTestsRoot rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) {
            return $null
        }
        return $sha.Trim()
    }
    catch {
        return $null
    }
}

function Get-ScanAgentE2eCallingTestScriptName {
    foreach ($frame in @(Get-PSCallStack)) {
        if ($null -eq $frame) {
            continue
        }

        $path = $null
        if ($frame.PSObject.Properties.Name -contains 'ScriptName') {
            $path = [string]$frame.ScriptName
        }

        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if ($path -match '[\\/]ScanAgent[\\/]P\d+[\\/]' -and $path -like '*.ps1') {
            return [System.IO.Path]::GetFileNameWithoutExtension($path)
        }
    }

    return $null
}

function Write-ScanAgentE2eLabBundleVersion {
    param(
        [string] $TestId = '',
        [Parameter(Mandatory)]
        [string] $LabTestsRoot
    )

    $git = Get-ScanAgentE2eLabBundleGitRevision -LabTestsRoot $LabTestsRoot
    $gitSuffix = if ($git) { " git=$git" } else { '' }
    $testSuffix = if ([string]::IsNullOrWhiteSpace($TestId)) { '' } else { " test=$TestId" }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] Resec.LabTests Scan Agent E2E bundle version $($script:ScanAgentE2eLabBundleVersion) (root='$LabTestsRoot'$gitSuffix$testSuffix)"
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

$testScriptName = Get-ScanAgentE2eCallingTestScriptName
Write-ScanAgentE2eLabBundleVersion -TestId $testScriptName -LabTestsRoot $labTestsRoot
