#Requires -Version 5.1
<#
.SYNOPSIS
  Scan Agent E2E destination folders under C:\test (not C:\ root).
#>
Set-StrictMode -Version Latest

$script:ScanAgentE2eTestOutputRoot = 'C:\test'

function Get-ScanAgentE2eTestOutputRootPath {
    return [System.IO.Path]::GetFullPath($script:ScanAgentE2eTestOutputRoot)
}

function Test-IsScanAgentE2eManagedDestinationPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = Get-ScanAgentE2eTestOutputRootPath
    if (-not $root.EndsWith('\')) {
        $root += '\'
    }

    return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Ensure-ScanAgentE2eTestOutputRoot {
    $root = Get-ScanAgentE2eTestOutputRootPath
    if (-not [System.IO.Directory]::Exists($root)) {
        $null = [System.IO.Directory]::CreateDirectory($root)
    }

    if (-not [System.IO.Directory]::Exists($root)) {
        throw "Failed to create Scan Agent E2E test output root: $root"
    }

    return $root
}

function Resolve-ScanAgentE2eTestDestinationFolderPath {
    <#
    .SYNOPSIS
      Resolves a fixed per-test destination (e.g. C:\test\SA-14). Creates the folder when using the default.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $TestId,
        [string] $DestinationFolder = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($DestinationFolder)) {
        $path = [System.IO.Path]::GetFullPath($DestinationFolder)
        if (-not [System.IO.Directory]::Exists($path)) {
            throw "Destination folder does not exist: $path"
        }
        return $path
    }

    $root = Ensure-ScanAgentE2eTestOutputRoot
    $path = [System.IO.Path]::GetFullPath((Join-Path $root $TestId))
    if (-not [System.IO.Directory]::Exists($path)) {
        $null = [System.IO.Directory]::CreateDirectory($path)
    }

    if (-not [System.IO.Directory]::Exists($path)) {
        throw "Failed to create destination folder: $path"
    }

    return $path
}

function New-ScanAgentE2eTestDestinationFolder {
    <#
    .SYNOPSIS
      Creates a unique run folder under C:\test (SA_TestDest_<guid>).
    #>
    $root = Ensure-ScanAgentE2eTestOutputRoot
    $name = 'SA_TestDest_' + [guid]::NewGuid().ToString('N')
    $path = [System.IO.Path]::GetFullPath((Join-Path $root $name))
    if ([System.IO.Directory]::Exists($path)) {
        throw "Destination path already exists: $path"
    }

    $null = [System.IO.Directory]::CreateDirectory($path)
    if (-not [System.IO.Directory]::Exists($path)) {
        throw "Failed to create destination folder: $path"
    }

    return $path
}

function Remove-ScanAgentE2eTestDestinationFolder {
    param([string] $DestinationFolderPath)

    $dest = [System.IO.Path]::GetFullPath($DestinationFolderPath)
    if (-not [System.IO.Directory]::Exists($dest)) {
        return
    }

    if (-not (Test-IsScanAgentE2eManagedDestinationPath -Path $dest)) {
        throw "Refusing to delete destination outside C:\test: $dest"
    }

    $message = "Teardown: removing destination folder '$dest'"
    if (Get-Command -Name Write-TestStep -ErrorAction SilentlyContinue) {
        Write-TestStep $message
    }
    else {
        Write-Host $message
    }

    [System.IO.Directory]::Delete($dest, $true)
}
