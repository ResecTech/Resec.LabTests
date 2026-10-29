#Requires -Version 5.1
Set-StrictMode -Version Latest

function Import-LabDeploySuiteDefaultsFromScriptRoot {
    param(
        [Parameter(Mandatory)]
        [string] $ScriptRoot
    )

    $labRoot = if (-not [string]::IsNullOrWhiteSpace($env:LAB_TESTS_ROOT)) {
        $env:LAB_TESTS_ROOT.Trim()
    }
    else {
        $dir = [System.IO.Path]::GetFullPath($ScriptRoot)
        $leaf = [System.IO.Path]::GetFileName($dir.TrimEnd('\', '/'))
        $levelsUp = if ($leaf -match '^P\d+$') { 2 } else { 1 }
        $cursor = $dir
        for ($i = 0; $i -lt $levelsUp; $i++) {
            $parent = [System.IO.Path]::GetDirectoryName($cursor)
            if ([string]::IsNullOrWhiteSpace($parent)) {
                break
            }

            $cursor = $parent
        }

        $cursor
    }

    $defaultsPath = Join-Path $labRoot 'Common\LabTestDeploySuiteDefaults.ps1'
    if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) {
        throw "Lab deploy suite defaults not found: $defaultsPath"
    }

    . $defaultsPath
}

function Get-ScanAgentDeployRequirements {
    return @(
        [PSCustomObject]@{
            DeployScriptId  = 'ScanAgent'
            RequiresRunning = $false
        }
    )
}

function Get-MailDeployRequirements {
    return @(
        [PSCustomObject]@{
            DeployScriptId  = 'Mail'
            RequiresRunning = $false
        }
    )
}

function Get-CoreDeployRequirements {
    return @(
        [PSCustomObject]@{
            DeployScriptId  = 'Core'
            RequiresRunning = $true
        }
    )
}

function Get-FileTypeDetectionDeployRequirements {
    return @(
        [PSCustomObject]@{
            DeployScriptId  = 'FileTypeDetection'
            RequiresRunning = $false
        }
    )
}

function Get-DirWatcherDeployRequirements {
    return @(
        [PSCustomObject]@{
            DeployScriptId  = 'DirWatcher'
            RequiresRunning = $false
        }
    )
}
