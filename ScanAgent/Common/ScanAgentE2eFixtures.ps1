#Requires -Version 5.1
<#
.SYNOPSIS
  Resolves shared sanitize fixture roots (Resec.LabTests\Fixtures and legacy SA-TestFiles layouts).
#>
Set-StrictMode -Version Latest

$script:SaTestFilesFolderName = 'SA-TestFiles'

function Write-SaFixtureResolveStep {
    param([string] $Message)
    if (Get-Command Write-TestStep -ErrorAction SilentlyContinue) {
        Write-TestStep $Message
    }
    else {
        Write-Host $Message
    }
}

function Test-SaFixtureDirectoryExists {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.Directory]::Exists([System.IO.Path]::GetFullPath($Path)) }
    catch { return $false }
}

function Get-SaEnvironmentFixtureAnchors {
    $anchors = New-Object System.Collections.Generic.List[string]

    foreach ($envName in @('LAB_FIXTURES_ROOT', 'SCANAGENT_TEST_FILES_ROOT')) {
        $raw = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        foreach ($part in $raw.Split(';')) {
            $trimmed = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $full = [System.IO.Path]::GetFullPath($trimmed)
            if (Test-SaFixtureDirectoryExists -Path $full) { $anchors.Add($full) }
        }
    }

    return [string[]]@($anchors | Select-Object -Unique)
}

function Get-SaScriptAncestorDirectoryChain {
    $chain = New-Object System.Collections.Generic.List[string]
    $startDir = $PSScriptRoot
    if (Get-Variable -Scope Script -Name SaE2eCallingScriptRoot -ErrorAction SilentlyContinue) {
        if (-not [string]::IsNullOrWhiteSpace($script:SaE2eCallingScriptRoot)) {
            $startDir = $script:SaE2eCallingScriptRoot
        }
    }

    $dir = [System.IO.Path]::GetFullPath($startDir)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $chain.Add($dir)
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return [string[]]$chain.ToArray()
}

function Test-ShouldSkipSaTestFilesDriveSearchDirectory {
    param([string] $DirectoryPath)
    if ([string]::IsNullOrWhiteSpace($DirectoryPath)) { return $true }
    $name = [System.IO.Path]::GetFileName($DirectoryPath.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($name)) { return $true }
    $skipNames = @(
        '$Recycle.Bin', 'System Volume Information', 'Recovery', 'PerfLogs', 'Config.Msi',
        'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
        'node_modules', '.git', '.svn', '.hg', 'WinSxS', 'assembly', 'Installer'
    )
    foreach ($skip in $skipNames) {
        if ($name.Equals($skip, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Find-SaTestFilesRootFoldersOnCDrive {
    $driveRoot = [System.IO.Path]::GetPathRoot('C:\')
    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        throw 'Cannot resolve C:\ drive root when searching for legacy SA-TestFiles.'
    }

    $driveRoot = [System.IO.Path]::GetFullPath($driveRoot)
    if (-not (Test-SaFixtureDirectoryExists -Path $driveRoot)) {
        throw "C:\ drive root is not accessible: $driveRoot"
    }

    $matches = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $visited = @{}
    $queue.Enqueue($driveRoot)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $visitKey = $current.ToUpperInvariant()
        if ($visited.ContainsKey($visitKey)) { continue }
        $visited[$visitKey] = $true

        try {
            foreach ($subdir in [System.IO.Directory]::EnumerateDirectories($current)) {
                if (Test-ShouldSkipSaTestFilesDriveSearchDirectory -DirectoryPath $subdir) { continue }
                $dirName = [System.IO.Path]::GetFileName($subdir.TrimEnd('\'))
                if ($dirName.Equals($script:SaTestFilesFolderName, [StringComparison]::OrdinalIgnoreCase)) {
                    $matches.Add([System.IO.Path]::GetFullPath($subdir))
                }
                $queue.Enqueue($subdir)
            }
        }
        catch { }
    }

    return [string[]]@($matches | Select-Object -Unique)
}

function Select-PreferredSaTestFilesRootFolder {
    param([string[]] $Candidates)

    $list = @($Candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ((Get-CollectionCount $list) -eq 0) { return $null }
    if ((Get-CollectionCount $list) -eq 1) { return [System.IO.Path]::GetFullPath($list[0]) }

    foreach ($anchor in (Get-SaEnvironmentFixtureAnchors)) {
        $anchorFull = [System.IO.Path]::GetFullPath($anchor)
        foreach ($candidate in $list) {
            if ([System.IO.Path]::GetFullPath($candidate).Equals($anchorFull, [StringComparison]::OrdinalIgnoreCase)) {
                return $anchorFull
            }
        }
    }

    foreach ($ancestor in (Get-SaScriptAncestorDirectoryChain)) {
        $near = [System.IO.Path]::GetFullPath((Join-Path $ancestor $script:SaTestFilesFolderName))
        foreach ($candidate in $list) {
            if ([System.IO.Path]::GetFullPath($candidate).Equals($near, [StringComparison]::OrdinalIgnoreCase)) {
                return $near
            }
        }
    }

    $sorted = @(
        $list |
            ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
            Sort-Object @{ Expression = { $_.Length }; Ascending = $true }, @{ Expression = { $_ }; Ascending = $true }
    )
    $shortestLen = $sorted[0].Length
    $shortest = @($sorted | Where-Object { $_.Length -eq $shortestLen })
    if ((Get-CollectionCount $shortest) -eq 1) { return $shortest[0] }

    $listed = ($shortest | ForEach-Object { "'$_'" }) -join ', '
    throw "Multiple '$($script:SaTestFilesFolderName)' folders found on C:\ ($listed). Pass -TestFilesRoot to choose one."
}

function Resolve-SaTestFilesRootFolder {
    <#
    .SYNOPSIS
      Sanitize fixture root: shared Fixtures\ (Allowed/Blocked/CDR) or legacy SA-TestFiles folder.
    #>
    param(
        [string] $OverridePath = '',
        [string] $ScenarioLabel = 'Scan Agent E2E'
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $custom = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-SaFixtureDirectoryExists -Path $custom)) {
            throw "Test files root override does not exist: $custom"
        }
        return $custom
    }

    foreach ($anchor in (Get-SaEnvironmentFixtureAnchors)) {
        $anchorFull = [System.IO.Path]::GetFullPath($anchor)
        if (Test-LabSanitizeFixtureLayout -Path $anchorFull) {
            Write-SaFixtureResolveStep "Using fixture root from environment: '$anchorFull'"
            return $anchorFull
        }
        $leaf = [System.IO.Path]::GetFileName($anchorFull.TrimEnd('\'))
        if ($leaf.Equals($script:SaTestFilesFolderName, [StringComparison]::OrdinalIgnoreCase)) {
            return $anchorFull
        }
    }

    try {
        $labRoot = Get-LabFixturesRoot
        if (Test-LabSanitizeFixtureLayout -Path $labRoot) {
            Write-SaFixtureResolveStep "Using shared lab fixtures root: '$labRoot'"
            return $labRoot
        }
    }
    catch {
        Write-SaFixtureResolveStep "Shared Fixtures folder not used: $($_.Exception.Message)"
    }

    foreach ($ancestor in (Get-SaScriptAncestorDirectoryChain)) {
        $fixturesNear = [System.IO.Path]::GetFullPath((Join-Path $ancestor 'Fixtures'))
        if (Test-LabSanitizeFixtureLayout -Path $fixturesNear) {
            return $fixturesNear
        }

        $legacyNear = [System.IO.Path]::GetFullPath((Join-Path $ancestor $script:SaTestFilesFolderName))
        if (Test-SaFixtureDirectoryExists -Path $legacyNear) {
            return $legacyNear
        }
    }

    Write-SaFixtureResolveStep "Searching C:\ for legacy folder '$($script:SaTestFilesFolderName)'..."
    $found = Find-SaTestFilesRootFoldersOnCDrive
    $chosen = Select-PreferredSaTestFilesRootFolder -Candidates $found
    if ([string]::IsNullOrWhiteSpace($chosen)) {
        throw "$ScenarioLabel requires shared Fixtures (Allowed/Blocked/CDR) under Resec.LabTests, or legacy '$($script:SaTestFilesFolderName)' on C:\. Pass -TestFilesRoot."
    }

    Write-SaFixtureResolveStep "Using legacy SA-TestFiles root: '$chosen'"
    return $chosen
}
