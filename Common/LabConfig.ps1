#Requires -Version 5.1
<#
.SYNOPSIS
  Resec.LabTests path configuration for E2E scripts and fixtures.

.DESCRIPTION
  Loads config\lab.local.json (copy from lab.local.json.example) and exposes product repo roots.
  Override any path with environment variables (see README).

  Dot-source from product bootstrap scripts:
    . (Join-Path (Get-LabTestsRoot) 'Common\LabConfig.ps1')
#>
Set-StrictMode -Version Latest

$script:LabConfigLoaded = $false
$script:LabConfigData = $null

function Get-LabTestsRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_TESTS_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:LAB_TESTS_ROOT.Trim())
    }

    # This file lives in <LabTests>\Common\LabConfig.ps1
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-LabConfigFilePath {
    $override = $env:LAB_TESTS_CONFIG
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath($override.Trim())
    }

    return Join-Path (Get-LabTestsRoot) 'config\lab.local.json'
}

function Import-LabConfig {
    if ($script:LabConfigLoaded) {
        return $script:LabConfigData
    }

    $path = Get-LabConfigFilePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw @"
Lab config not found: $path
Copy config\lab.local.json.example to config\lab.local.json and set product repo roots.
Or set LAB_TESTS_CONFIG to your config file path.
"@
    }

    $json = [System.IO.File]::ReadAllText($path)
    $script:LabConfigData = $json | ConvertFrom-Json
    $script:LabConfigLoaded = $true
    return $script:LabConfigData
}

function Get-LabProductRepoRoot {
    <#
    .PARAMETER Product
      ScanAgent | Core | Mail | FileTypeDetection | DirWatcher
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ScanAgent', 'Core', 'Mail', 'FileTypeDetection', 'DirWatcher')]
        [string] $Product
    )

    $envMap = @{
        ScanAgent         = 'LAB_SCANAGENT_REPO_ROOT'
        Core              = 'LAB_CORE_REPO_ROOT'
        Mail              = 'LAB_MAIL_REPO_ROOT'
        FileTypeDetection = 'LAB_FTD_REPO_ROOT'
        DirWatcher        = 'LAB_DIRWATCHER_REPO_ROOT'
    }

    $envName = $envMap[$Product]
    $fromEnv = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $full = [System.IO.Path]::GetFullPath($fromEnv.Trim())
        if (-not (Test-Path -LiteralPath $full)) {
            throw "$envName points to a missing path: $full"
        }
        return $full
    }

    $cfg = Import-LabConfig
    $prop = $Product
    if (-not ($cfg.products.PSObject.Properties.Name -contains $prop)) {
        throw "lab.local.json is missing products.$Product"
    }

    $repoRoot = [string]$cfg.products.$prop.repoRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw "lab.local.json products.$Product.repoRoot is empty."
    }

    $full = [System.IO.Path]::GetFullPath($repoRoot)
    if (-not (Test-Path -LiteralPath $full)) {
        throw "products.$Product.repoRoot not found: $full"
    }

    return $full
}

function Get-LabOptionalPath {
    param(
        [Parameter(Mandatory)]
        [string] $SettingName,
        [string] $EnvironmentVariable = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
            return [System.IO.Path]::GetFullPath($fromEnv.Trim())
        }
    }

    $cfg = Import-LabConfig
    if ($null -eq $cfg.optional) {
        return $null
    }

    if (-not ($cfg.optional.PSObject.Properties.Name -contains $SettingName)) {
        return $null
    }

    $value = [string]$cfg.optional.$SettingName
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($value.Trim())
}

function Get-LabOptionalString {
    <#
    .SYNOPSIS
      Optional string from lab.local.json optional.* (not a path). Env override when -EnvironmentVariable is set.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $SettingName,
        [string] $EnvironmentVariable = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
            return $fromEnv.Trim()
        }
    }

    try {
        $cfg = Import-LabConfig
    }
    catch {
        return $null
    }

    if ($null -eq $cfg.optional) {
        return $null
    }

    if (-not ($cfg.optional.PSObject.Properties.Name -contains $SettingName)) {
        return $null
    }

    $value = [string]$cfg.optional.$SettingName
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function Get-LabScanAgentProductRoot {
    $repoRoot = Get-LabProductRepoRoot -Product ScanAgent
    return Join-Path $repoRoot 'src'
}

function Get-LabScanAgentTestTreeRoot {
    return Join-Path (Get-LabTestsRoot) 'ScanAgent'
}

function Get-LabMailProductRoot {
    $repoRoot = Get-LabProductRepoRoot -Product Mail
    return Join-Path $repoRoot 'src'
}

function Get-LabMailTestTreeRoot {
    return Join-Path (Get-LabTestsRoot) 'Mail'
}

function Get-LabCoreTestTreeRoot {
    return Join-Path (Get-LabTestsRoot) 'Core'
}

function Get-LabFileTypeDetectionProductRoot {
    return Get-LabProductRepoRoot -Product FileTypeDetection
}

function Get-LabSystemVariables {
    <#
    .SYNOPSIS
      Lab-wide variables from config\lab.local.json → systemVariables (used by fixture scripts as $name).
    #>
    $result = [ordered]@{}

    try {
        $cfg = Import-LabConfig
    }
    catch {
        return $result
    }

    if ($null -eq $cfg.systemVariables) {
        return $result
    }

    foreach ($prop in $cfg.systemVariables.PSObject.Properties) {
        $result[$prop.Name] = [string]$prop.Value
    }

    return $result
}

function Get-LabSystemVariable {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $key = $Name.Trim()
    if ($key.StartsWith('$')) {
        $key = $key.Substring(1)
    }

    $all = Get-LabSystemVariables
    if (-not ($all.Contains($key))) {
        return $null
    }

    $value = [string]$all[$key]
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}
