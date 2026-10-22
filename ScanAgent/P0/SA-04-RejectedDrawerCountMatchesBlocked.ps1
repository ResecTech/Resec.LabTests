#Requires -Version 5.1
<#
.SYNOPSIS
  SA-04: Rejected drawer count matches sanitization blocked count after a job with rejections.

.DESCRIPTION
  Selects every eligible file under SA-TestFiles\Blocked\Enchrypted, \FileTypeNotAllowed, and \Infected
  (including nested files under those category folders). Expects outcomeFriendly per category:
  Password Required, Blocked By Policy, and Infected respectively.
  If selecting encrypted fixtures opens the password modal, the script cancels it (cancelPasswordDialog).
  Runs sanitization, asserts per-file outcomes in sanitization.status and rejected drawer
  (no on-disk destination artifacts), then opens the rejected-items drawer and validates counts and per-file rows.
  Destination grid/on-disk checks run only for passed files when present.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - SA-TestFiles\Blocked on drive C:\ with at least one eligible fixture (optional -TestFilesRoot / -SourceFolder).

.NOTES
  Test plan: SA-04 — rejected drawer count aligns with blocked/rejected job outcomes.
  Exit 0 = passed; C:\test destination folder removed on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceFolder = '',
    [string] $TestFilesRoot = '',
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $MaxFolderDepth = 5,
    [int] $MaxJobFiles = 50,
    [int] $MinJobFiles = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:SaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
$script:SaE2eReportScript = Join-Path $script:SaE2eCommonRoot 'Report-ScanAgentTestPlatformResult.ps1'
. (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot -ScanAgentDebug $ScanAgentDebug
$destinationPath = $null
$script:TestFileMaxBytes = 5MB
$script:TestBlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.msp', '.hta', '.jar', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.ps1xml',
    '.vbs', '.vbe', '.js', '.jse', '.ws', '.wsf', '.wsh', '.sh', '.py', '.pyw', '.pl', '.rb', '.php', '.reg', '.inf', '.lnk', '.url'
)
$script:TestBlockedDirectoryNames = @(
    '.git', '.svn', '.hg', '.vs', '.idea', 'node_modules', 'bin', 'obj', '__pycache__', 'packages', 'dist', 'build', 'out', 'target'
)
$script:Sa04DefaultSourceSubfolder = 'Blocked'
$script:Sa04BlockedCategorySpecs = @(
    @{ FolderName = 'Enchrypted'; ExpectedOutcomeFriendly = 'Password Required' }
    @{ FolderName = 'FileTypeNotAllowed'; ExpectedOutcomeFriendly = 'Blocked By Policy' }
    @{ FolderName = 'Infected'; ExpectedOutcomeFriendly = 'Infected' }
)

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Test-DirectoryExists {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        return [System.IO.Directory]::Exists([System.IO.Path]::GetFullPath($Path))
    }
    catch {
        return $false
    }
}


function Get-EligibleFilesUnderCandidateFolder {
    param(
        [string] $CandidateFolder,
        [System.IO.FileInfo[]] $IndexedEligibleFiles
    )

    $prefix = [System.IO.Path]::GetFullPath($CandidateFolder)
    if (-not $prefix.EndsWith('\')) {
        $prefix += '\'
    }

    return [System.IO.FileInfo[]]@(
        $IndexedEligibleFiles | Where-Object {
            $_.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        }
    )
}

function Get-IndexedEligibleFilesForSearch {
    param(
        [string[]] $SearchBases,
        [int] $MaxFolderDepth = 5
    )

    $fileKeys = @{}
    foreach ($base in ($SearchBases | Select-Object -Unique)) {
        if (Test-IsDriveRootDirectory -Path $base) {
            continue
        }
        foreach ($file in (Get-EligibleFilesUnderFolder -RootFolder $base -MaxFolderDepth $MaxFolderDepth)) {
            if ($null -eq $file) {
                continue
            }
            $fileKeys[$file.FullName.ToUpperInvariant()] = $file
        }
    }

    return (ConvertTo-FileInfoArray @($fileKeys.Values | Sort-Object FullName))
}

function Test-PathUnderSearchBase {
    param(
        [string] $FolderPath,
        [string[]] $SearchBases
    )

    $full = [System.IO.Path]::GetFullPath($FolderPath)
    foreach ($base in $SearchBases) {
        if (Test-IsDriveRootDirectory -Path $base) {
            continue
        }
        $baseFull = [System.IO.Path]::GetFullPath($base)
        if (-not $baseFull.EndsWith('\')) {
            $baseFull += '\'
        }
        if ($full.Equals($baseFull.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-SourceFolderCandidatesFromIndexedFiles {
    param(
        [System.IO.FileInfo[]] $IndexedEligibleFiles,
        [string[]] $SearchBases
    )

    $candidateKeys = @{}
    foreach ($base in ($SearchBases | Select-Object -Unique)) {
        if (-not (Test-IsDriveRootDirectory -Path $base)) {
            Add-FixtureCandidateFolder -CandidateKeys $candidateKeys -FolderPath $base
        }
    }

    foreach ($file in (ConvertTo-FileInfoArray $IndexedEligibleFiles)) {
        $dir = $file.DirectoryName
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (-not (Test-PathUnderSearchBase -FolderPath $dir -SearchBases $SearchBases)) {
                break
            }
            Add-FixtureCandidateFolder -CandidateKeys $candidateKeys -FolderPath $dir
            $parent = [System.IO.Path]::GetDirectoryName($dir)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
                break
            }
            $dir = $parent
        }
    }

    return [string[]]@($candidateKeys.Values | Sort-Object)
}

function Test-EligibleTestFile {
    param(
        [System.IO.FileInfo] $File,
        [switch] $AllowPolicyBlockedExtensions
    )

    if ($File.Length -gt $script:TestFileMaxBytes) { return $false }
    if (-not $AllowPolicyBlockedExtensions) {
        if ($script:TestBlockedExtensions -contains $File.Extension.ToLowerInvariant()) { return $false }
    }
    return $true
}

function Test-IsBlockedFixturePathSegment {
    param([string] $SegmentName)

    if ([string]::IsNullOrWhiteSpace($SegmentName)) {
        return $false
    }

    if ($SegmentName.StartsWith('.', [StringComparison]::Ordinal)) {
        return $true
    }

    foreach ($blocked in $script:TestBlockedDirectoryNames) {
        if ($SegmentName.Equals($blocked, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-IsBlockedFixturePath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $false
    }

    foreach ($segment in $relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)) {
        if (Test-IsBlockedFixturePathSegment -SegmentName $segment) {
            return $true
        }
    }

    return $false
}

function Get-RelativeFolderDepthFromRoot {
    param(
        [string] $RootFolder,
        [string] $FileFullPath
    )

    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not $root.EndsWith('\')) {
        $root += '\'
    }

    $full = [System.IO.Path]::GetFullPath($FileFullPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return [int]::MaxValue
    }

    $relative = $full.Substring($root.Length)
    $dirPart = [System.IO.Path]::GetDirectoryName($relative)
    if ([string]::IsNullOrWhiteSpace($dirPart)) {
        return 0
    }

    return @($dirPart.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)).Count
}

function Test-IsHiddenFixturePathOnly {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $false
    }

    foreach ($segment in $relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.StartsWith('.', [StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Get-EligibleFilesUnderFolder {
    param(
        [string] $RootFolder,
        [int] $MaxFolderDepth = 5,
        [switch] $AllowPolicyBlockedExtensions
    )

    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not (Test-DirectoryExists -Path $root)) {
        return [System.IO.FileInfo[]]@()
    }

    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    try {
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            try {
                $file = New-Object System.IO.FileInfo $filePath
                if (-not (Test-EligibleTestFile -File $file -AllowPolicyBlockedExtensions:$AllowPolicyBlockedExtensions)) {
                    continue
                }
                if ((Get-RelativeFolderDepthFromRoot -RootFolder $root -FileFullPath $file.FullName) -gt $MaxFolderDepth) {
                    continue
                }
                if ($AllowPolicyBlockedExtensions) {
                    if (Test-IsHiddenFixturePathOnly -Path $file.FullName) {
                        continue
                    }
                }
                elseif (Test-IsBlockedFixturePath -Path $file.FullName) {
                    continue
                }
                $list.Add($file)
            }
            catch {
            }
        }
    }
    catch {
    }

    return [System.IO.FileInfo[]]@($list | Sort-Object FullName)
}

function Limit-JobFileSelection {
    param(
        [System.IO.FileInfo[]] $Files,
        [int] $MaxCount
    )

    $all = ConvertTo-FileInfoArray $Files
    if ($MaxCount -le 0 -or (Get-CollectionCount $all) -le $MaxCount) {
        return $all
    }

    return ConvertTo-FileInfoArray @($all | Select-Object -First $MaxCount)
}

function Get-RelativeFolderKeyCount {
    param(
        [string] $FolderPath,
        [System.IO.FileInfo[]] $Files
    )

    $prefix = [System.IO.Path]::GetFullPath($FolderPath)
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    $dirKeys = @{}
    foreach ($f in $Files) {
        $rel = $f.FullName.Substring($prefix.Length)
        $dirPart = [System.IO.Path]::GetDirectoryName($rel)
        if ([string]::IsNullOrWhiteSpace($dirPart)) { $dirPart = '.' }
        $dirKeys[$dirPart] = $true
    }
    return (Get-CollectionCount @($dirKeys.Keys))
}

function Select-TestSourceFolder {
    param(
        [string] $Override = '',
        [string] $TestFilesRoot = '',
        [int] $MinEligibleFiles = 1,
        [int] $MinDistinctRelativeFolders = 0,
        [int] $MaxFolderDepth = 5,
        [int] $MaxJobFiles = 10,
        [switch] $AllowPolicyBlockedExtensions
    )

    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRoot
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $sourceRoot = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-DirectoryExists -Path $sourceRoot)) {
            throw "Source folder override does not exist: $sourceRoot"
        }
        $saRootPrefix = $saRoot
        if (-not $saRootPrefix.EndsWith('\')) {
            $saRootPrefix += '\'
        }
        if (-not ($sourceRoot.Equals($saRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $sourceRoot.StartsWith($saRootPrefix, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Source folder '$sourceRoot' must be under SA-TestFiles root '$saRoot' (or set -TestFilesRoot to match)."
        }
    }
    else {
        $sourceRoot = $saRoot
    }

    $files = Limit-JobFileSelection -Files (
        Get-EligibleFilesUnderFolder -RootFolder $sourceRoot -MaxFolderDepth $MaxFolderDepth -AllowPolicyBlockedExtensions:$AllowPolicyBlockedExtensions
    ) -MaxCount $MaxJobFiles

    if ((Get-CollectionCount $files) -lt $MinEligibleFiles) {
        $depthHint = if ($AllowPolicyBlockedExtensions) { 'recursive; policy-blocked extensions allowed' } else { 'recursive' }
        throw "Source '$sourceRoot' has $(Get-CollectionCount $files) eligible file(s) within $MaxFolderDepth folder level(s) ($depthHint); need at least $MinEligibleFiles."
    }

    if ($MinDistinctRelativeFolders -gt 0) {
        $keyCount = Get-RelativeFolderKeyCount -FolderPath $sourceRoot -Files $files
        if ($keyCount -lt $MinDistinctRelativeFolders) {
            throw "Source '$sourceRoot' has eligible files in $keyCount folder path(s); need at least $MinDistinctRelativeFolders."
        }
    }

    Write-TestStep "Fixture root: '$saRoot'; source folder: '$sourceRoot' ($(Get-CollectionCount $files) file(s) for job)"

    return [pscustomobject]@{ Path = $sourceRoot; EligibleFiles = $files }
}

function Format-ScanAgentDebugCommandLine {
    param([string[]] $Arguments)

    $parts = @()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            continue
        }
        $text = [string] $arg
        if ($text -match '[\s"]') {
            $parts += '"' + ($text.Replace('"', '\"')) + '"'
        }
        else {
            $parts += $text
        }
    }
    return ($parts -join ' ')
}

function Invoke-ScanAgentDebug {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(& $Exe @Arguments 2>&1)
        foreach ($line in $lines) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $msg = $line.Exception.Message
                if ([string]::IsNullOrWhiteSpace($msg)) {
                    $msg = $line.ToString()
                }
                if ($msg.StartsWith('Wait:', [StringComparison]::Ordinal)) {
                    Write-Host $msg -ForegroundColor DarkCyan
                }
                else {
                    $stdoutLines.Add($msg)
                }
            }
            elseif ($line -is [string] -and $line.StartsWith('Wait:', [StringComparison]::Ordinal)) {
                Write-Host $line -ForegroundColor DarkCyan
            }
            else {
                $stdoutLines.Add([string] $line)
            }
        }
    }
    catch {
        $stdoutLines.Add($_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $savedEap
    }

    $exitCode = 0
    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }

    $stdout = ($stdoutLines -join [Environment]::NewLine).TrimEnd()

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
        StdErr   = ''
    }
}

function ConvertFrom-ScanAgentDebugOutput {
    param([string] $Stdout)

    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        return $null
    }

    $trimmed = $Stdout.Trim()
    try {
        return ($trimmed | ConvertFrom-Json)
    }
    catch {
    }

    foreach ($line in ($Stdout -split "`r?`n")) {
        $lineTrimmed = $line.Trim()
        if ($lineTrimmed.StartsWith('{')) {
            try {
                return ($lineTrimmed | ConvertFrom-Json)
            }
            catch {
            }
        }
    }

    $start = $Stdout.IndexOf('{')
    $end = $Stdout.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $jsonBlob = $Stdout.Substring($start, $end - $start + 1)
        try {
            return ($jsonBlob | ConvertFrom-Json)
        }
        catch {
            throw "ScanAgentDebug output was not valid JSON: $jsonBlob"
        }
    }

    return $null
}

function Invoke-ScanAgentDebugJson {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments $Arguments
    $commandLine = Format-ScanAgentDebugCommandLine -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdOut) { $result.StdOut } else { $result.StdErr }
        throw (Format-ScanAgentDebugInvokeFailure -ExitCode $result.ExitCode -CommandLine $commandLine -Detail $detail)
    }

    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        throw "ScanAgentDebug returned no stdout: $commandLine"
    }

    $parsed = ConvertFrom-ScanAgentDebugOutput -Stdout $result.StdOut
    if ($null -eq $parsed) {
        throw "ScanAgentDebug returned no JSON: $commandLine`n$($result.StdOut)"
    }

    return $parsed
}

function Assert-OkResponse {
    param($Response, [string] $Step)
    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "${Step} failed: $err"
    }
}

function Get-DriveRootUiName {
    param([string] $FolderPath)
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($FolderPath))
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Cannot determine drive root for path: $FolderPath"
    }
    $letter = $root.TrimEnd('\')
    if (-not $letter.EndsWith(':')) {
        throw "Unexpected path root format: $root"
    }
    return $letter
}

function Get-FolderSegmentsFromDrive {
    param([string] $FolderPath)

    $full = [System.IO.Path]::GetFullPath($FolderPath)
    $driveRoot = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        throw "Invalid folder path: $FolderPath"
    }

    $relative = $full.Substring($driveRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return @()
    }

    return @($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
}

function Invoke-NavigateSourceSegments {
    param(
        [string] $Exe,
        [string[]] $Segments,
        [string] $StepPrefix
    )

    foreach ($segment in $Segments) {
        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $segment, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}

function Initialize-Sa04BlockedFixtures {
    param(
        [Parameter(Mandatory)]
        [string] $SaRoot,
        [Parameter(Mandatory)]
        [string] $BlockedPath
    )

    $relativeSources = @(
        'pdf\JavaScriptOnOpen.pdf',
        'pdf\JavaScriptAlert.pdf',
        'csv\DDE.csv',
        'html\Script change style in HTML.html'
    )

    [void][System.IO.Directory]::CreateDirectory($BlockedPath)
    $copied = 0
    foreach ($rel in $relativeSources) {
        $src = [System.IO.Path]::GetFullPath((Join-Path $SaRoot $rel))
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            continue
        }

        $dest = Join-Path $BlockedPath ([System.IO.Path]::GetFileName($src))
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $copied++
    }

    if ($copied -lt 2) {
        throw "SA-04 could not seed '$BlockedPath' (copied $copied file(s)). Add at least two blocked fixtures under SA-TestFiles, or pass -SourceFolder."
    }

    Write-TestStep "Seeded SA-TestFiles\Blocked with $copied fixture(s) copied from SA-TestFiles."
}

function Resolve-Sa04SourceFolderPath {
    param(
        [string] $SourceFolderOverride = '',
        [string] $TestFilesRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SourceFolderOverride)) {
        $explicit = [System.IO.Path]::GetFullPath($SourceFolderOverride)
        if (-not (Test-DirectoryExists -Path $explicit)) {
            throw "Source folder does not exist on disk (will not auto-create): $explicit"
        }
        return $explicit
    }

    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRoot
    $blocked = [System.IO.Path]::GetFullPath((Join-Path $saRoot $script:Sa04DefaultSourceSubfolder))
    if (-not (Test-DirectoryExists -Path $blocked)) {
        Initialize-Sa04BlockedFixtures -SaRoot $saRoot -BlockedPath $blocked
    }
    else {
        $eligible = Get-EligibleFilesUnderFolder -RootFolder $blocked -MaxFolderDepth $MaxFolderDepth `
            -AllowPolicyBlockedExtensions
        if ((Get-CollectionCount $eligible) -lt 2) {
            Write-TestStep "SA-TestFiles\Blocked has fewer than 2 eligible fixtures; re-seeding from SA-TestFiles."
            Initialize-Sa04BlockedFixtures -SaRoot $saRoot -BlockedPath $blocked
        }
    }

    return $blocked
}

function Resolve-Sa04SeedFilePath {
    param(
        [string] $ExplicitPath,
        [string] $SourceRoot,
        [System.IO.FileInfo[]] $EligibleFiles
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $full = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Seed file does not exist: $full"
        }
        $item = Get-Item -LiteralPath $full
        if (-not (Test-EligibleTestFile -File $item -AllowPolicyBlockedExtensions)) {
            throw "Seed file is not eligible under Blocked (max 5 MB): $full"
        }
        return $full
    }

    $root = [System.IO.Path]::GetFullPath($SourceRoot)
    $candidates = @($EligibleFiles | Where-Object { $_.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
    if ((Get-CollectionCount $candidates) -eq 0) {
        throw "No eligible seed file under '$root'. Pass -SeedFile or add fixtures."
    }

    $preferred = $candidates | Where-Object { $_.Extension -in @('.csv', '.pdf', '.html', '.bmp', '.svg') } | Select-Object -First 1
    if ($null -ne $preferred) {
        Write-TestStep "Auto-selected seed file: $($preferred.FullName)"
        return $preferred.FullName
    }

    Write-TestStep "Auto-selected seed file: $($candidates[0].FullName)"
    return $candidates[0].FullName
}

function Get-NavSegmentsForFileUnderSource {
    param(
        [string] $SourceRoot,
        [string] $FilePath
    )

    $sourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
    $fileDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FilePath))
    if (-not $fileDir.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Seed file is not under source folder '$sourceRoot': $FilePath"
    }

    $relativeDir = $fileDir.Substring($sourceRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativeDir)) {
        return @()
    }

    return @($relativeDir.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
}

function Backup-Sa04SeedFile {
    param([string] $SourceFilePath)

    $full = [System.IO.Path]::GetFullPath($SourceFilePath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "SA-04 seed file does not exist: $full"
    }

    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        throw 'Cannot backup SA-04 seed file: TEMP is not set.'
    }

    $backupName = 'SA04_seed_' + [guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($full)
    $backupPath = [System.IO.Path]::GetFullPath((Join-Path $tempRoot $backupName))
    Write-TestStep "Backup SA-04 seed '$full' -> '$backupPath'"
    Copy-Item -LiteralPath $full -Destination $backupPath -Force
    return $backupPath
}

function Restore-Sa04SeedFixture {
    param(
        [string] $SourceFilePath,
        [string] $BackupPath
    )

    if ([string]::IsNullOrWhiteSpace($SourceFilePath) -or [string]::IsNullOrWhiteSpace($BackupPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return
    }

    if (-not (Test-Path -LiteralPath $SourceFilePath -PathType Leaf)) {
        Write-TestStep "Restore SA-04 seed fixture from backup: $SourceFilePath"
        Copy-Item -LiteralPath $BackupPath -Destination $SourceFilePath -Force
    }

    Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
}

function Get-MainContentRoot {
    param($Payload)

    if ($null -eq $Payload) {
        throw 'ui.mainContent response is null.'
    }

    if ($Payload.PSObject.Properties['mainContent'] -and $null -ne $Payload.mainContent) {
        return $Payload.mainContent
    }

    return $Payload
}

function Test-ScanAgentPasswordDialogOpen {
    param($MainContentRoot)

    if ($null -eq $MainContentRoot) {
        return $false
    }

    if (-not $MainContentRoot.PSObject.Properties['passwordDialog']) {
        return $false
    }

    $dialog = $MainContentRoot.passwordDialog
    if ($null -eq $dialog) {
        return $false
    }

    if ($dialog.PSObject.Properties['isOpen']) {
        return $dialog.isOpen -eq $true
    }

    return $false
}

function Invoke-CancelScanAgentPasswordDialogIfOpen {
    param(
        [string] $Exe,
        [string] $Context
    )

    $dialogOpen = $false
    try {
        $dialogStatus = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('passwordDialogStatus')
        if ($dialogStatus.ok -eq $true -and $dialogStatus.isOpen -eq $true) {
            $dialogOpen = $true
        }
    }
    catch {
    }

    if (-not $dialogOpen) {
        $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
        Assert-OkResponse -Response $main -Step "ui.mainContent ($Context password check)"
        $dialogOpen = Test-ScanAgentPasswordDialogOpen -MainContentRoot (Get-MainContentRoot -Payload $main)
    }

    if (-not $dialogOpen) {
        return $false
    }

    Write-TestStep "Encrypted-file password dialog open; cancel ($Context)"
    $cancel = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'cancelPasswordDialog')
    Assert-OkResponse -Response $cancel -Step "cancelPasswordDialog ($Context)"
    return $true
}

function Invoke-DismissScanAgentPasswordDialogs {
    param(
        [string] $Exe,
        [string] $Context,
        [int] $MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not (Invoke-CancelScanAgentPasswordDialogIfOpen -Exe $Exe -Context "$Context (attempt $attempt)")) {
            return
        }
        Start-Sleep -Milliseconds 300
    }
}

function Get-SanitizationFileProperty {
    param(
        $FileEntry,
        [string[]] $PropertyNames
    )

    if ($null -eq $FileEntry) {
        return $null
    }

    foreach ($propertyName in $PropertyNames) {
        $prop = $FileEntry.PSObject.Properties[$propertyName]
        if ($null -ne $prop) {
            $value = $prop.Value
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [string]$value
            }
        }
    }

    return $null
}

function Normalize-OutcomeToken {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $t = $Text.Trim().ToLowerInvariant()
    $t = $t -replace '[^a-z0-9]+', ''
    return $t
}

function Test-OutcomeTokensAlign {
    param(
        [string] $StatusOutcome,
        [string] $StatusOutcomeFriendly,
        [string] $GridOutcome,
        [string] $GridStatusText
    )

    $expected = @(
        (Normalize-OutcomeToken -Text $StatusOutcome)
        (Normalize-OutcomeToken -Text $StatusOutcomeFriendly)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $gridTokens = @(
        (Normalize-OutcomeToken -Text $GridOutcome)
        (Normalize-OutcomeToken -Text $GridStatusText)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ((Get-CollectionCount $expected) -eq 0 -or (Get-CollectionCount $gridTokens) -eq 0) {
        return $false
    }

    foreach ($exp in $expected) {
        foreach ($grid in $gridTokens) {
            if ($grid -eq $exp) {
                return $true
            }
            if ($grid.Contains($exp) -or $exp.Contains($grid)) {
                return $true
            }
        }
    }

    return $false
}

function Test-OutcomeIsBlockedOrRejected {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    $patterns = @('block', 'reject', 'fail', 'denied', 'notallowed', 'skipped', 'negative', 'password', 'infected', 'policy')
    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        foreach ($pattern in $patterns) {
            if ($token.Contains($pattern)) {
                return $true
            }
        }
    }

    return $false
}

function Test-OutcomeIsPassedSanitize {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    $successTokens = @(
        'outcomepassed', 'outcomereconstructed', 'outcomemodified', 'passed', 'reconstructed', 'modified', 'success'
    )

    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($successTokens -contains $token) {
            return $true
        }
    }

    return $false
}

function Test-IsValidDestinationGridFileName {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    if ($Name -match '[\\/:*?"<>|]') {
        return $false
    }

    return $true
}

function Resolve-OnDiskSourceFileForStatusEntry {
    param(
        $FileEntry,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath
    )

    $statusSourcePath = Get-SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @(
        'sourcePath', 'SourcePath', 'path', 'Path'
    )
    if (-not [string]::IsNullOrWhiteSpace($statusSourcePath)) {
        $statusFull = [System.IO.Path]::GetFullPath($statusSourcePath)
        foreach ($file in (ConvertTo-FileInfoArray $OnDiskSourceFiles)) {
            if ($file.FullName.Equals($statusFull, [StringComparison]::OrdinalIgnoreCase)) {
                return $file
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
            $root = [System.IO.Path]::GetFullPath($SourceRootPath)
            $combined = $statusSourcePath
            if (-not [System.IO.Path]::IsPathRooted($statusSourcePath)) {
                $combined = [System.IO.Path]::GetFullPath((Join-Path $root $statusSourcePath))
            }
            foreach ($file in (ConvertTo-FileInfoArray $OnDiskSourceFiles)) {
                if ($file.FullName.Equals($combined, [StringComparison]::OrdinalIgnoreCase)) {
                    return $file
                }
            }
        }
    }

    $leaf = Get-StatusEntrySourceLeafName -FileEntry $FileEntry -OnDiskSourceFiles $null
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        return $null
    }

    $matches = @(ConvertTo-FileInfoArray $OnDiskSourceFiles | Where-Object {
            $_.Name.Equals($leaf, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -gt 1) {
        throw "Ambiguous on-disk match for source file '$leaf' ($($matches.Count) files under '$SourceRootPath'); sanitization.status must include sourcePath for nested Blocked fixtures."
    }

    return $null
}

function Get-StatusEntrySourceLeafName {
    param(
        $FileEntry,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $sourcePath = Get-SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @(
        'sourcePath', 'SourcePath', 'path', 'Path'
    )
    if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
        return [System.IO.Path]::GetFileName($sourcePath)
    }

    $name = Get-SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @('name', 'fileName', 'FileName')
    if (-not [string]::IsNullOrWhiteSpace($name) -and $name -notmatch '[\\/]') {
        return $name
    }

    if ($OnDiskSourceFiles) {
        foreach ($file in $OnDiskSourceFiles) {
            $entryName = Get-SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @('name', 'fileName', 'FileName')
            if ($entryName -and $file.Name -ieq $entryName) {
                return $file.Name
            }
        }
    }

    return $name
}

function Get-DestinationGridFileItems {
    param($ListPayload)

    if ($null -eq $ListPayload -or $null -eq $ListPayload.items) {
        return @()
    }

    return @(
        $ListPayload.items |
            Where-Object { $_.type -ne 'Directory' -and $_.isVisible -ne $false } |
            Sort-Object name
    )
}

function Get-DestinationGridDirectoryItems {
    param($ListPayload)

    if ($null -eq $ListPayload -or $null -eq $ListPayload.items) {
        return @()
    }

    return @(
        $ListPayload.items |
            Where-Object {
                $typeName = [string] $_.type
                $typeName.Equals('Directory', [StringComparison]::OrdinalIgnoreCase) -and $_.isVisible -ne $false
            } |
            Sort-Object name
    )
}

function Test-DestinationGridHasSubfolder {
    param(
        $ListPayload,
        [string] $FolderName
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    foreach ($dir in (Get-DestinationGridDirectoryItems -ListPayload $ListPayload)) {
        if ([string] $dir.name -eq $FolderName) {
            return $true
        }
    }

    return $false
}

function Invoke-TryOpenDestinationSubfolder {
    param(
        [string] $Exe,
        [string] $FolderName,
        [string] $StepLabel
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    Write-TestStep "$StepLabel try openFolder (name) -> '$FolderName'"
    $open = Invoke-ScanAgentDebug -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'openFolder', '--panel', 'destination', '--name', $FolderName, '--wait-ms', "$UiWaitMs"
    )
    if ($open.ExitCode -ne 0) {
        return $false
    }

    $parsed = ConvertFrom-ScanAgentDebugOutput -Stdout $open.StdOut
    if ($null -eq $parsed -or $parsed.ok -ne $true) {
        return $false
    }

    return $true
}

function Get-ListPayloadFolderPath {
    param($ListPayload)

    if ($null -eq $ListPayload -or $null -eq $ListPayload.folder) {
        return $null
    }

    $folderPath = [string] $ListPayload.folder.path
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        $folderPath = [string] $ListPayload.folder.name
    }

    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($folderPath)
}

function Get-PathRelativeToFolder {
    param(
        [string] $RootFolder,
        [string] $FullPath
    )

    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not $root.EndsWith('\')) {
        $root += '\'
    }

    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $full.Substring($root.Length).TrimStart('\')
}

function Get-FolderDepthUnderRoot {
    param(
        [string] $RootFolder,
        [string] $FolderPath
    )

    $relative = Get-PathRelativeToFolder -RootFolder $RootFolder -FullPath $FolderPath
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return 0
    }

    return @($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)).Count
}

function New-DestinationGridInventoryRecord {
    param(
        $GridItem,
        [string] $FolderPath
    )

    $folder = [System.IO.Path]::GetFullPath($FolderPath)
    $name = [string] $GridItem.name
    $fullItemPath = [System.IO.Path]::GetFullPath((Join-Path $folder $name))

    return [pscustomobject]@{
        Item         = $GridItem
        FolderPath   = $folder
        Name         = $name
        FullItemPath = $fullItemPath
    }
}

function Get-DestinationFolderPathForStatusEntry {
    param(
        $StatusEntry,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $destPath = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('destinationPath', 'DestinationPath')
    if (-not [string]::IsNullOrWhiteSpace($destPath)) {
        $destFull = [System.IO.Path]::GetFullPath($destPath)
        $parent = [System.IO.Path]::GetDirectoryName($destFull)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            return [System.IO.Path]::GetFullPath($parent)
        }
    }

    $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath

    $sourceRelative = $null
    if ($null -ne $sourceFile -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceRelative)) {
        $mirroredFile = [System.IO.Path]::GetFullPath((Join-Path $destRoot $sourceRelative))
        $mirroredParent = [System.IO.Path]::GetDirectoryName($mirroredFile)
        if (-not [string]::IsNullOrWhiteSpace($mirroredParent)) {
            return [System.IO.Path]::GetFullPath($mirroredParent)
        }
    }

    return $destRoot
}

function Get-FolderSegmentsRelativeToRoot {
    param(
        [string] $RootFolder,
        [string] $TargetFolder
    )

    $relative = Get-PathRelativeToFolder -RootFolder $RootFolder -FullPath $TargetFolder
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return @()
    }

    return @($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
}

function Invoke-NavigateDestinationToFolderPath {
    param(
        [string] $Exe,
        [string] $DestDriveUi,
        [string[]] $DestRootSegments,
        [string] $DestinationRoot,
        [string] $TargetFolderPath,
        [int] $MaxFolderDepth
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $targetFolder = [System.IO.Path]::GetFullPath($TargetFolderPath)

    Write-TestStep "selectDestination root '$DestDriveUi' (target folder '$targetFolder')"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $DestDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination (destination verify)'

    Invoke-NavigateDestinationSegments -Exe $Exe -Segments $DestRootSegments -StepPrefix 'Destination (job root)'

    $listAtLevel = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listDestinationFiles')
    Assert-OkResponse -Response $listAtLevel -Step 'listDestinationFiles (job root)'
    Assert-DestinationFolderUnderRoot -ListPayload $listAtLevel -DestinationRoot $destRoot -StepLabel 'listDestinationFiles (job root)'

    $reachedFolder = Get-ListPayloadFolderPath -ListPayload $listAtLevel
    if ([string]::IsNullOrWhiteSpace($reachedFolder)) {
        $reachedFolder = $destRoot
    }

    $reachedFullTarget = $false
    if ($targetFolder.Equals($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $reachedFullTarget = $true
    }
    elseif ($targetFolder.StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeSegments = Get-FolderSegmentsRelativeToRoot -RootFolder $destRoot -TargetFolder $targetFolder
        if ((Get-CollectionCount $relativeSegments) -gt $MaxFolderDepth) {
            Write-TestStep "Destination folder depth exceeds MaxFolderDepth ($MaxFolderDepth); will search at reached level only."
        }
        else {
            foreach ($segment in $relativeSegments) {
                if (-not (Test-DestinationGridHasSubfolder -ListPayload $listAtLevel -FolderName $segment)) {
                    Write-TestStep "Destination subfolder '$segment' is not listed under '$reachedFolder'; using current grid level."
                    break
                }

                if (-not (Invoke-TryOpenDestinationSubfolder -Exe $Exe -FolderName $segment -StepLabel 'Destination')) {
                    Write-TestStep "Destination openFolder failed for '$segment' under '$reachedFolder'; using current grid level."
                    break
                }

                $listAtLevel = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listDestinationFiles')
                Assert-OkResponse -Response $listAtLevel -Step "listDestinationFiles ($segment)"
                Assert-DestinationFolderUnderRoot -ListPayload $listAtLevel -DestinationRoot $destRoot `
                    -StepLabel "listDestinationFiles ($segment)"

                $reachedFolder = Get-ListPayloadFolderPath -ListPayload $listAtLevel
                if ([string]::IsNullOrWhiteSpace($reachedFolder)) {
                    break
                }

                if ([System.IO.Path]::GetFullPath($reachedFolder).Equals($targetFolder, [StringComparison]::OrdinalIgnoreCase)) {
                    $reachedFullTarget = $true
                    break
                }
            }
        }
    }
    else {
        throw "Target destination folder '$targetFolder' is not under job destination root '$destRoot'."
    }

    return [pscustomobject]@{
        ListPayload       = $listAtLevel
        ReachedFolderPath = [System.IO.Path]::GetFullPath($reachedFolder)
        ReachedFullTarget = $reachedFullTarget
    }
}

function Get-DestinationListForFolder {
    param(
        [string] $Exe,
        [string] $DestDriveUi,
        [string[]] $DestRootSegments,
        [string] $DestinationRoot,
        [string] $FolderPath,
        [int] $MaxFolderDepth,
        [hashtable] $Cache
    )

    $key = ([System.IO.Path]::GetFullPath($FolderPath)).ToUpperInvariant()
    if ($Cache.ContainsKey($key)) {
        return $Cache[$key]
    }

    $nav = Invoke-NavigateDestinationToFolderPath -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestRootSegments `
        -DestinationRoot $DestinationRoot -TargetFolderPath $FolderPath -MaxFolderDepth $MaxFolderDepth

    $Cache[$key] = $nav
    return $nav
}

function Find-DestinationGridItemInList {
    param(
        $ListPayload,
        [string[]] $CandidateNames
    )

    $names = @($CandidateNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ((Get-CollectionCount $names) -eq 0) {
        return $null
    }

    foreach ($gridItem in (Get-DestinationGridFileItems -ListPayload $ListPayload)) {
        $gridName = [string] $gridItem.name
        if ([string]::IsNullOrWhiteSpace($gridName)) {
            continue
        }

        foreach ($candidate in $names) {
            if ($candidate.Contains('*')) {
                if ($gridName -like $candidate) {
                    return $gridItem
                }
            }
            elseif ($gridName.Equals($candidate, [StringComparison]::OrdinalIgnoreCase)) {
                return $gridItem
            }
        }

        foreach ($candidate in $names) {
            if ($candidate.Contains('*')) {
                continue
            }
            $base = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
            if (-not [string]::IsNullOrWhiteSpace($base) -and
                $gridName.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
                return $gridItem
            }
        }
    }

    return $null
}

function Get-DestinationCandidateNamesForStatusEntry {
    param(
        $StatusEntry,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $names = New-Object System.Collections.Generic.List[string]
    $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles
    $destPath = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('destinationPath', 'DestinationPath')

    if (-not [string]::IsNullOrWhiteSpace($destPath)) {
        $names.Add([System.IO.Path]::GetFileName($destPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceLeaf)) {
        $names.Add($sourceLeaf)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($sourceLeaf)
        $ext = [System.IO.Path]::GetExtension($sourceLeaf)
        if (-not [string]::IsNullOrWhiteSpace($base) -and $ext) {
            $names.Add(($base + '_*' + $ext))
        }
    }

    $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath
    if ($null -ne $sourceFile -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
        if (-not [string]::IsNullOrWhiteSpace($sourceRelative)) {
            $names.Add([System.IO.Path]::GetFileName($sourceRelative))
            $names.Add($sourceRelative)
        }
    }

    return [string[]]@($names | Select-Object -Unique)
}

function Assert-ListFolderPathMatches {
    param(
        $ListPayload,
        [string] $ExpectedDiskPath,
        [string] $StepLabel
    )

    $folderPath = Get-ListPayloadFolderPath -ListPayload $ListPayload
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        throw "${StepLabel} did not return folder.path in list response."
    }

    $expected = [System.IO.Path]::GetFullPath($ExpectedDiskPath)
    $actual = [System.IO.Path]::GetFullPath($folderPath)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "${StepLabel} folder.path mismatch: expected '$expected', got '$actual'."
    }

    if ($ListPayload.folder.isLoaded -eq $false) {
        throw "${StepLabel} folder is not loaded at '$actual'."
    }

    Write-TestStep "${StepLabel} folder loaded at '$actual' (grid items: $($ListPayload.itemCount))"
}

function Assert-DestinationFolderUnderRoot {
    param(
        $ListPayload,
        [string] $DestinationRoot,
        [string] $StepLabel
    )

    $folderPath = Get-ListPayloadFolderPath -ListPayload $ListPayload
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        throw "${StepLabel} did not return folder.path in list response."
    }

    $root = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not $root.EndsWith('\')) {
        $root += '\'
    }

    $actual = [System.IO.Path]::GetFullPath($folderPath)
    if (-not ($actual.Equals($root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
            $actual.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))) {
        throw "${StepLabel} folder.path '$actual' is not under destination root '$($root.TrimEnd('\'))'."
    }

    if ($ListPayload.folder.isLoaded -eq $false) {
        throw "${StepLabel} folder is not loaded at '$actual'."
    }

    Write-TestStep "${StepLabel} folder loaded at '$actual' (grid items: $($ListPayload.itemCount))"
}

function Assert-NoBlockedArtifactsOnDestinationDisk {
    param(
        [string] $DestinationRoot,
        $FinalStatus,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not (Test-DirectoryExists -Path $destRoot)) {
        return
    }

    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly) {
            continue
        }

        $candidateNames = Get-DestinationCandidateNamesForStatusEntry -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles

        foreach ($candidate in $candidateNames) {
            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Contains('*')) {
                continue
            }

            $directPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $candidate))
            if (Test-Path -LiteralPath $directPath -PathType Leaf) {
                throw "Blocked/rejected file must not exist on disk at destination: '$directPath'"
            }
        }

        $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles `
            -SourceRootPath $SourceRootPath
        if ($null -ne $sourceFile -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
            $relative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                $mirroredPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $relative))
                if (Test-Path -LiteralPath $mirroredPath -PathType Leaf) {
                    throw "Blocked/rejected file must not exist on disk at mirrored destination path: '$mirroredPath'"
                }
            }
        }
    }

    Write-TestStep 'Confirmed blocked/rejected job files have no on-disk artifacts under the destination folder.'
}

function Get-Sa04BlockedCategoryFixtures {
    param(
        [string] $BlockedRootPath,
        [int] $MaxFolderDepth = 5
    )

    $blockedRoot = [System.IO.Path]::GetFullPath($BlockedRootPath)
    if (-not (Test-DirectoryExists -Path $blockedRoot)) {
        throw "SA-04 Blocked root does not exist: $blockedRoot"
    }

    $all = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($spec in $script:Sa04BlockedCategorySpecs) {
        $categoryPath = [System.IO.Path]::GetFullPath((Join-Path $blockedRoot $spec.FolderName))
        if (-not (Test-DirectoryExists -Path $categoryPath)) {
            throw "SA-04 requires category folder '$($spec.FolderName)' under '$blockedRoot'."
        }
        $categoryFiles = Get-EligibleFilesUnderFolder -RootFolder $categoryPath -MaxFolderDepth $MaxFolderDepth `
            -AllowPolicyBlockedExtensions
        $categoryCount = Get-CollectionCount $categoryFiles
        if ($categoryCount -lt 1) {
            throw "SA-04 category '$($spec.FolderName)' has no eligible files under '$categoryPath'."
        }
        Write-TestStep "SA-04 category '$($spec.FolderName)': $categoryCount file(s); expected outcome '$($spec.ExpectedOutcomeFriendly)'"
        foreach ($file in (ConvertTo-FileInfoArray $categoryFiles)) {
            $all.Add($file)
        }
    }

    return [System.IO.FileInfo[]]$all.ToArray()
}

function Get-Sa04ExpectedOutcomeFriendlyForSourceFile {
    param(
        [string] $BlockedRootPath,
        [string] $FileFullPath
    )

    $blockedRoot = [System.IO.Path]::GetFullPath($BlockedRootPath)
    if (-not $blockedRoot.EndsWith('\')) {
        $blockedRoot += '\'
    }
    $full = [System.IO.Path]::GetFullPath($FileFullPath)
    if (-not $full.StartsWith($blockedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $full.Substring($blockedRoot.Length)
    $firstSegment = ($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))[0]
    if ([string]::IsNullOrWhiteSpace($firstSegment)) {
        return $null
    }

    foreach ($spec in $script:Sa04BlockedCategorySpecs) {
        if ($firstSegment.Equals($spec.FolderName, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$spec.ExpectedOutcomeFriendly
        }
    }

    return $null
}

function Test-Sa04OutcomeMatchesExpectedFriendly {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly,
        [string] $ExpectedFriendlyLabel
    )

    $expectedNorm = Normalize-OutcomeToken -Text $ExpectedFriendlyLabel
    if ([string]::IsNullOrWhiteSpace($expectedNorm)) {
        return $false
    }

    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($token -eq $expectedNorm) {
            return $true
        }
        if ($token.Contains($expectedNorm) -or $expectedNorm.Contains($token)) {
            return $true
        }
    }

    if ($expectedNorm -eq 'passwordrequired') {
        foreach ($raw in @($Outcome, $OutcomeFriendly)) {
            $token = Normalize-OutcomeToken -Text $raw
            if ($token.Contains('password')) {
                return $true
            }
        }
    }
    if ($expectedNorm -eq 'blockedbypolicy') {
        foreach ($raw in @($Outcome, $OutcomeFriendly)) {
            $token = Normalize-OutcomeToken -Text $raw
            if ($token.Contains('policy') -or $token.Contains('blocked')) {
                return $true
            }
        }
    }
    if ($expectedNorm -eq 'infected') {
        foreach ($raw in @($Outcome, $OutcomeFriendly)) {
            $token = Normalize-OutcomeToken -Text $raw
            if ($token.Contains('infect')) {
                return $true
            }
        }
    }

    return $false
}

function Assert-Sa04BlockedCategoryOutcomes {
    param(
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $BlockedRootPath
    )

    $verified = 0
    foreach ($sourceFile in (ConvertTo-FileInfoArray $OnDiskSourceFiles)) {
        $expectedFriendly = Get-Sa04ExpectedOutcomeFriendlyForSourceFile -BlockedRootPath $BlockedRootPath `
            -FileFullPath $sourceFile.FullName
        if ([string]::IsNullOrWhiteSpace($expectedFriendly)) {
            throw "On-disk job file is not under an SA-04 category folder: $($sourceFile.FullName)"
        }

        $matchedEntry = $null
        foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
            $resolved = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles `
                -SourceRootPath $BlockedRootPath
            if ($null -ne $resolved -and $resolved.FullName.Equals($sourceFile.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                $matchedEntry = $entry
                break
            }
        }

        if ($null -eq $matchedEntry) {
            throw "sanitization.status has no entry for on-disk file '$($sourceFile.FullName)'."
        }

        $statusOutcome = Get-SanitizationFileProperty -FileEntry $matchedEntry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $matchedEntry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-Sa04OutcomeMatchesExpectedFriendly -Outcome $statusOutcome -OutcomeFriendly $statusFriendly `
                -ExpectedFriendlyLabel $expectedFriendly)) {
            throw "File '$($sourceFile.Name)' under '$($sourceFile.DirectoryName)' expected outcome '$expectedFriendly'; got outcome='$statusOutcome' friendly='$statusFriendly'."
        }

        Write-TestStep "Outcome OK: '$($sourceFile.FullName)' -> '$expectedFriendly' (outcome='$statusOutcome' friendly='$statusFriendly')"
        $verified++
    }

    $statusCount = Get-CollectionCount (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)
    if ($verified -ne $statusCount) {
        throw "Validated $verified on-disk job file(s) but sanitization.status has $statusCount file entries."
    }
}

function Find-RejectedDrawerItemForStatusEntry {
    param(
        $StatusEntry,
        [object[]] $DrawerItems,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath
    )

    $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles
    $statusSourcePath = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
    $resolvedSource = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath
    $resolvedFull = if ($null -ne $resolvedSource) { $resolvedSource.FullName } else { $null }

    foreach ($item in $DrawerItems) {
        $drawerName = [string] $item.name
        if (-not [string]::IsNullOrWhiteSpace($sourceLeaf) -and $drawerName.Equals($sourceLeaf, [StringComparison]::OrdinalIgnoreCase)) {
            return $item
        }

        $drawerSource = $null
        if ($null -ne $item.PSObject.Properties['sourcePath']) {
            $drawerSource = [string] $item.sourcePath
        }
        if (-not [string]::IsNullOrWhiteSpace($statusSourcePath) -and -not [string]::IsNullOrWhiteSpace($drawerSource)) {
            if ([System.IO.Path]::GetFullPath($drawerSource).Equals([System.IO.Path]::GetFullPath($statusSourcePath), [StringComparison]::OrdinalIgnoreCase)) {
                return $item
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedFull) -and -not [string]::IsNullOrWhiteSpace($drawerSource)) {
            if ([System.IO.Path]::GetFullPath($drawerSource).Equals([System.IO.Path]::GetFullPath($resolvedFull), [StringComparison]::OrdinalIgnoreCase)) {
                return $item
            }
        }
    }

    return $null
}

function Assert-Sa04RejectedDrawerItemsMatchStatus {
    param(
        $MainContentPayload,
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath,
        [string] $StepLabel
    )

    $main = Get-MainContentRoot -Payload $MainContentPayload
    if ($null -eq $main.rejectedDrawer) {
        throw "${StepLabel}: mainContent.rejectedDrawer missing."
    }

    $drawerItems = @($main.rejectedDrawer.items)
    if ((Get-CollectionCount $drawerItems) -lt 1) {
        throw "${StepLabel}: rejectedDrawer.items is empty."
    }

    $matched = 0
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')

        if (-not (Test-OutcomeIsBlockedOrRejected -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            continue
        }

        $drawerItem = Find-RejectedDrawerItemForStatusEntry -StatusEntry $entry -DrawerItems $drawerItems `
            -OnDiskSourceFiles $OnDiskSourceFiles -SourceRootPath $SourceRootPath
        if ($null -eq $drawerItem) {
            throw "${StepLabel}: rejected drawer has no row for blocked file '$sourceLeaf'."
        }

        $drawerName = [string] $drawerItem.name
        if (-not (Test-IsValidDestinationGridFileName -Name $drawerName)) {
            throw "${StepLabel}: invalid rejected drawer file name '$drawerName' for '$sourceLeaf'."
        }

        $statusText = ''
        if ($null -ne $drawerItem.PSObject.Properties['statusText']) {
            $statusText = [string] $drawerItem.statusText
        }
        $description = ''
        if ($null -ne $drawerItem.PSObject.Properties['description']) {
            $description = [string] $drawerItem.description
        }

        if ([string]::IsNullOrWhiteSpace($statusText) -and [string]::IsNullOrWhiteSpace($description)) {
            throw "${StepLabel}: rejected drawer row '$drawerName' has no statusText/description (negative status expected)."
        }

        Write-TestStep "${StepLabel}: drawer row OK for '$drawerName' statusText='$statusText' description='$description'"
        $matched++
    }

    $blocked = [int]$FinalStatus.counts.blocked
    if ($matched -ne $blocked) {
        throw "${StepLabel}: matched $matched drawer row(s) for blocked files; expected counts.blocked=$blocked."
    }
}

function Assert-Sa04DestinationNamesAndOutcomes {
    param(
        [string] $Exe,
        [string] $DestDriveUi,
        [string[]] $DestSegments,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [int] $MaxFolderDepth,
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $passedCount = [int]$FinalStatus.counts.passed
    if ($passedCount -le 0) {
        Write-TestStep 'No passed files in job; skipping destination grid/on-disk verification (blocked files are SA UI-only).'
        return
    }

    Write-TestStep 'Post-job: verify destination grid for passed file(s) only'

    $folderNavCache = @{}
    $verifiedRows = 0
    $destRootFull = [System.IO.Path]::GetFullPath($DestinationRoot)

    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        if ([string]::IsNullOrWhiteSpace($sourceLeaf)) {
            throw 'Job status contains a file entry without a resolvable source file name.'
        }

        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            Write-TestStep "Skip destination grid for blocked file '$sourceLeaf' (UI-only negative status)."
            continue
        }

        $targetFolder = Get-DestinationFolderPathForStatusEntry -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
        $candidateNames = Get-DestinationCandidateNamesForStatusEntry -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles

        $searchFolders = New-Object System.Collections.Generic.List[string]
        $searchFolders.Add($destRootFull)
        if (-not $targetFolder.Equals($destRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            $searchFolders.Add([System.IO.Path]::GetFullPath($targetFolder))
        }

        $gridItem = $null
        $destList = $null
        $folderPath = $null
        foreach ($searchFolder in ($searchFolders | Select-Object -Unique)) {
            $nav = Get-DestinationListForFolder -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestSegments `
                -DestinationRoot $DestinationRoot -FolderPath $searchFolder -MaxFolderDepth $MaxFolderDepth -Cache $folderNavCache

            $tryList = $nav.ListPayload
            $tryHit = Find-DestinationGridItemInList -ListPayload $tryList -CandidateNames $candidateNames
            if ($null -ne $tryHit) {
                $gridItem = $tryHit
                $destList = $tryList
                $folderPath = $nav.ReachedFolderPath
                Write-TestStep "Found destination row for '$sourceLeaf' under '$folderPath'"
                break
            }

            Write-TestStep "No destination row for '$sourceLeaf' at '$($nav.ReachedFolderPath)' (candidates: $($candidateNames -join ', '))"
        }

        if ($null -eq $gridItem) {
            throw "No destination grid row for '$sourceLeaf' (searched job root and '$targetFolder'; candidates: $($candidateNames -join ', '))."
        }
        $gridName = [string] $gridItem.name
        if (-not (Test-IsValidDestinationGridFileName -Name $gridName)) {
            throw "Destination grid name invalid for job file '$sourceLeaf': '$gridName'"
        }

        $gridOutcome = [string] $gridItem.sanitizationOutcome
        $gridStatusText = ''
        if ($null -ne $gridItem.PSObject.Properties['statusText']) {
            $gridStatusText = [string] $gridItem.statusText
        }

        if ([string]::IsNullOrWhiteSpace($gridOutcome)) {
            throw "Destination grid row '$gridName' for '$sourceLeaf' in '$targetFolder' has empty sanitizationOutcome."
        }

        if (-not (Test-OutcomeTokensAlign -StatusOutcome $statusOutcome -StatusOutcomeFriendly $statusFriendly `
                -GridOutcome $gridOutcome -GridStatusText $gridStatusText)) {
            throw "Outcome mismatch for '$sourceLeaf' at '$folderPath\$gridName': grid='$gridOutcome' status='$statusOutcome' friendly='$statusFriendly' statusText='$gridStatusText'"
        }

        $fullItemPath = [System.IO.Path]::GetFullPath((Join-Path $folderPath $gridName))
        Write-TestStep "Destination row OK: '$fullItemPath' outcome='$gridOutcome'"
        $verifiedRows++

        if (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly) {
            $reportedDest = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('destinationPath', 'DestinationPath')
            $diskPath = $fullItemPath
            if (-not [string]::IsNullOrWhiteSpace($reportedDest) -and (Test-Path -LiteralPath $reportedDest -PathType Leaf)) {
                $diskPath = $reportedDest
            }
            elseif (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
                throw "Passed file '$sourceLeaf' has no on-disk destination artifact at '$diskPath' (reported='$reportedDest')."
            }
            Write-TestStep "Passed file on disk: '$diskPath'"
        }
    }

    if ($verifiedRows -lt 1) {
        throw 'No destination grid rows were verified for job files.'
    }

    Write-TestStep "Destination grid names and outcomes verified for $verifiedRows job file(s) (including subfolders)."
}

function Assert-RejectedDrawerCountMatchesBlocked {
    param(
        $MainContentPayload,
        $SanitizationStatus,
        [string] $StepLabel
    )

    if ($null -eq $SanitizationStatus -or $null -eq $SanitizationStatus.counts) {
        throw "${StepLabel}: sanitization.status missing counts."
    }

    $blocked = [int]$SanitizationStatus.counts.blocked
    if ($blocked -lt 1) {
        throw "${StepLabel}: expected counts.blocked >= 1 for rejected drawer validation; blocked=$blocked"
    }

    $main = Get-MainContentRoot -Payload $MainContentPayload
    if ($null -eq $main.activity) {
        throw "${StepLabel}: mainContent.activity missing."
    }

    $activityRejected = [int]$main.activity.rejected
    if ($activityRejected -ne $blocked) {
        throw "${StepLabel}: mainContent.activity.rejected ($activityRejected) does not match counts.blocked ($blocked)."
    }

    if ($null -eq $main.rejectedDrawer) {
        throw "${StepLabel}: mainContent.rejectedDrawer missing."
    }

    $drawerCount = [int]$main.rejectedDrawer.itemCount
    if ($drawerCount -ne $blocked) {
        throw "${StepLabel}: rejectedDrawer.itemCount ($drawerCount) does not match counts.blocked ($blocked)."
    }

    $drawerItems = @($main.rejectedDrawer.items)
    $itemsCount = Get-CollectionCount $drawerItems
    if ($itemsCount -ne $drawerCount) {
        throw "${StepLabel}: rejectedDrawer.items count ($itemsCount) does not match itemCount ($drawerCount)."
    }

    Write-TestStep "$StepLabel OK: activity.rejected=$activityRejected drawer.itemCount=$drawerCount items=$itemsCount (blocked=$blocked)"
}

function Test-ShouldSkipSa04BlockedSourceSubfolder {
    param([string] $SegmentName)

    if ([string]::IsNullOrWhiteSpace($SegmentName)) {
        return $true
    }

    return $SegmentName.StartsWith('.', [StringComparison]::Ordinal)
}

function Select-SourceFilesRecursive {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceRootPath,
        [ref] $SelectedCount,
        [ref] $FoldersUsed,
        [hashtable] $SelectedNames,
        [hashtable] $EligiblePathSet,
        [int] $MaxFolderDepth = 5,
        [int] $MaxJobFiles = 10,
        [switch] $Sa04BlockedFixtureRoot
    )

    if ($SelectedCount.Value -ge $MaxJobFiles) {
        return
    }

    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $childFiles = @(Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop | Sort-Object Name)
    $childDirs = @(Get-ChildItem -LiteralPath $diskFolderPath -Directory -Force -ErrorAction Stop | Sort-Object Name)

    foreach ($file in $childFiles) {
        if ($SelectedCount.Value -ge $MaxJobFiles) {
            return
        }
        if (-not $EligiblePathSet.ContainsKey($file.FullName.ToUpperInvariant())) {
            Write-TestStep "Skip ineligible file '$($file.Name)' in '$diskFolderPath'"
            continue
        }
        if ((Get-RelativeFolderDepthFromRoot -RootFolder $SourceRootPath -FileFullPath $file.FullName) -gt $MaxFolderDepth) {
            Write-TestStep "Skip file beyond max depth ($MaxFolderDepth): '$($file.Name)'"
            continue
        }
        Write-TestStep "Select file '$($file.Name)' in '$diskFolderPath'"
        $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--name', $file.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $select -Step "selectSourceFile ($($file.Name))"
        if ($Sa04BlockedFixtureRoot) {
            Invoke-DismissScanAgentPasswordDialogs -Exe $Exe -Context "after select '$($file.Name)'"
        }

        $key = $file.FullName.ToUpperInvariant()
        if ($SelectedNames.ContainsKey($key)) {
            throw "Double-selection detected for file: $($file.FullName)"
        }
        $SelectedNames[$key] = $true
        $SelectedCount.Value++
    }

    foreach ($dir in $childDirs) {
        if ($SelectedCount.Value -ge $MaxJobFiles) {
            return
        }
        $skipDir = if ($Sa04BlockedFixtureRoot) {
            Test-ShouldSkipSa04BlockedSourceSubfolder -SegmentName $dir.Name
        }
        else {
            Test-IsBlockedFixturePathSegment -SegmentName $dir.Name
        }
        if ($skipDir) {
            Write-TestStep "Skip subfolder '$($dir.Name)' under '$diskFolderPath'"
            continue
        }
        $dirDepth = Get-FolderDepthUnderRoot -RootFolder $SourceRootPath -FolderPath $dir.FullName
        if ($dirDepth -gt $MaxFolderDepth) {
            Write-TestStep "Skip subfolder beyond max depth ($MaxFolderDepth) from Blocked root: '$($dir.Name)' (depth=$dirDepth)"
            continue
        }
        $FoldersUsed.Value = $true
        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $dir.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source ($($dir.Name))"

        Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $dir.FullName -SourceRootPath $SourceRootPath `
            -SelectedCount $SelectedCount -FoldersUsed $FoldersUsed -SelectedNames $SelectedNames -EligiblePathSet $EligiblePathSet `
            -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $MaxJobFiles -Sa04BlockedFixtureRoot:$Sa04BlockedFixtureRoot

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-04'

    Write-TestStep "Resolve source folder SA-TestFiles\$($script:Sa04DefaultSourceSubfolder) on C:\"
    $sourcePath = Resolve-Sa04SourceFolderPath -SourceFolderOverride $SourceFolder -TestFilesRoot $TestFilesRoot
    if (-not (Test-DirectoryExists -Path $sourcePath)) {
        throw "Source path does not exist on disk: $sourcePath"
    }

    Write-TestStep "Discover all eligible files under Blocked category folders under '$sourcePath'"
    $onDiskFiles = Get-Sa04BlockedCategoryFixtures -BlockedRootPath $sourcePath -MaxFolderDepth $MaxFolderDepth
    $expectedFileCount = Get-CollectionCount $onDiskFiles
    if ($expectedFileCount -lt 1) {
        throw "SA-04 found no eligible files under Blocked category folders at '$sourcePath'."
    }
    if ($MaxJobFiles -gt 0 -and $expectedFileCount -gt $MaxJobFiles) {
        throw "SA-04 job has $expectedFileCount file(s) but -MaxJobFiles is $MaxJobFiles; increase -MaxJobFiles or reduce fixtures."
    }

    $eligiblePathSet = @{}
    foreach ($f in $onDiskFiles) {
        $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
    }

    Write-TestStep 'Create destination folder under C:\test'
    $destinationPath = New-ScanAgentE2eTestDestinationFolder
    if (-not (Test-DirectoryExists -Path $destinationPath)) {
        throw "Destination path does not exist on disk: $destinationPath"
    }

    Write-TestStep "Source root: '$sourcePath' ($expectedFileCount file(s) in job across 3 category folders; depth $MaxFolderDepth)"
    Write-TestStep "Destination: '$destinationPath'"

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    Write-TestStep 'ping debug pipe'
    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    Write-TestStep 'agent.info (Test Platform componentVersion)'
    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info'
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) {
        Write-TestStep "Reporting componentVersion: $e2eVersion"
    }

    Write-TestStep 'gateway.status'
    $gateway = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('gateway.status')
    Assert-OkResponse -Response $gateway -Step 'gateway.status'

    Write-TestStep 'ui.mainContent header.isConnected'
    $main = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent'
    if ($main.header.isConnected -eq $false) {
        throw 'Scan Agent header is not connected; connect to gateway before running SA-04.'
    }

    $sourceDriveUi = Get-DriveRootUiName -FolderPath $sourcePath
    $destDriveUi = Get-DriveRootUiName -FolderPath $destinationPath
    $sourceNavSegments = Get-FolderSegmentsFromDrive -FolderPath $sourcePath
    $destSegments = Get-FolderSegmentsFromDrive -FolderPath $destinationPath

    Write-TestStep "selectSource root '$sourceDriveUi'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceNavSegments -StepPrefix 'Source'

    Write-TestStep "selectDestination root '$destDriveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination'

    Invoke-NavigateDestinationSegments -Exe $exe -Segments $destSegments -StepPrefix 'Destination'

    Write-TestStep 'Return to source panel at Blocked root for multi-file selection'
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step 'selectSource (before selection)'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceNavSegments -StepPrefix 'Source (selection)'

    Write-TestStep 'clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    $uiSelectedCount = 0
    $foldersUsed = $false
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount
    $foldersUsedRef = [ref] $foldersUsed

    Write-TestStep "Recursive UI selection of up to $expectedFileCount file(s) under Blocked"
    Select-SourceFilesRecursive -Exe $exe -DiskFolderPath $sourcePath -SourceRootPath $sourcePath `
        -SelectedCount $selectedCountRef -FoldersUsed $foldersUsedRef -SelectedNames $selectedNames -EligiblePathSet $eligiblePathSet `
        -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $expectedFileCount -Sa04BlockedFixtureRoot

    if ($uiSelectedCount -ne $expectedFileCount) {
        throw "UI selection count ($uiSelectedCount) does not match on-disk job file count ($expectedFileCount)."
    }

    Invoke-DismissScanAgentPasswordDialogs -Exe $exe -Context 'before startSanitization'

    Write-TestStep "Starting sanitization ($uiSelectedCount file(s) selected; expect policy-blocked/rejected outcomes)"
    $start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization'

    Write-TestStep "Poll sanitization.status up to $SanitizePollSec seconds"
    $deadline = [datetime]::UtcNow.AddSeconds($SanitizePollSec)
    $finalStatus = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        Invoke-DismissScanAgentPasswordDialogs -Exe $exe -Context 'during sanitization poll'
        $status = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if ($status.state -eq 'complete') {
            $finalStatus = $status
            break
        }

        if ($status.state -eq 'idle' -and $status.inProgress -eq $false -and $status.sanitizationFinished -eq $true) {
            $finalStatus = $status
            break
        }

        Write-Host "  state=$($status.state) selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
    }

    if (-not $finalStatus) {
        throw "Sanitization did not reach terminal state within $SanitizePollSec seconds."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running

    Write-TestStep "Final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    $processed = $passed + $blocked

    if ($selected -ne $expectedFileCount) {
        throw "counts.selected ($selected) does not match on-disk job file count ($expectedFileCount)."
    }

    if ($processed -ne $selected) {
        throw "Processed count (passed+blocked=$processed) does not match counts.selected ($selected)."
    }

    if ($passed -ne 0) {
        throw "SA-04 expects all category files to fail sanitization; counts.passed=$passed"
    }
    if ($blocked -ne $expectedFileCount) {
        throw "Expected counts.blocked=$expectedFileCount for full category job; blocked=$blocked"
    }

    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }

    if ($finalStatus.files) {
        $outcomeCount = Get-CollectionCount (Get-SanitizationFileEntries -FilesProperty $finalStatus.files)
        Write-TestStep "Per-file outcomes in status: $outcomeCount"
        if ($outcomeCount -ne $selected) {
            throw "sanitization.status files array count ($outcomeCount) does not match counts.selected ($selected)."
        }
    }
    else {
        throw 'sanitization.status did not include files[] after completion.'
    }

    Assert-Sa04BlockedCategoryOutcomes -FinalStatus $finalStatus -OnDiskSourceFiles $onDiskFiles -BlockedRootPath $sourcePath
    Assert-NoBlockedArtifactsOnDestinationDisk -DestinationRoot $destinationPath -FinalStatus $finalStatus `
        -SourceRootPath $sourcePath -OnDiskSourceFiles $onDiskFiles

    Write-TestStep 'openRejectedDrawer'
    $openDrawer = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'openRejectedDrawer')
    Assert-OkResponse -Response $openDrawer -Step 'openRejectedDrawer'

    Write-TestStep 'ui.mainContent after openRejectedDrawer'
    $mainAfterDrawer = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainAfterDrawer -Step 'ui.mainContent (rejected drawer)'

    Assert-RejectedDrawerCountMatchesBlocked -MainContentPayload $mainAfterDrawer -SanitizationStatus $finalStatus -StepLabel 'SA-04 rejected drawer'
    Assert-Sa04RejectedDrawerItemsMatchStatus -MainContentPayload $mainAfterDrawer -FinalStatus $finalStatus `
        -OnDiskSourceFiles $onDiskFiles -SourceRootPath $sourcePath -StepLabel 'SA-04 rejected drawer items'

    Assert-Sa04DestinationNamesAndOutcomes -Exe $exe -DestDriveUi $destDriveUi -DestSegments $destSegments `
        -DestinationRoot $destinationPath -SourceRootPath $sourcePath -MaxFolderDepth $MaxFolderDepth `
        -FinalStatus $finalStatus -OnDiskSourceFiles $onDiskFiles

    Write-TestStep 'closeRejectedDrawer'
    $closeDrawer = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'closeRejectedDrawer')
    Assert-OkResponse -Response $closeDrawer -Step 'closeRejectedDrawer'

    $script:ScenarioPassed = $true
    Write-Host 'Scenario passed.'
    exit 0
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
    exit 1
}
finally {
    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed -and $destinationPath -and (Test-Path -LiteralPath $destinationPath)) {
        $evidenceOnFailure += $destinationPath
    }
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-04' -TestTitle 'Rejected drawer count matches blocked' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:ScenarioPassed) {
        try {
            if ($destinationPath) {
                Remove-ScanAgentE2eTestDestinationFolder -DestinationFolderPath $destinationPath
            }
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
