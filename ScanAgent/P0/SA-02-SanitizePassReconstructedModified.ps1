#Requires -Version 5.1
<#
.SYNOPSIS
  SA-02: Local sanitize — pass, reconstructed, and modified outcomes with destination artifacts.

.DESCRIPTION
  Recursively selects every eligible file under SA-TestFiles\Allowed and all of its subfolders (no file-count cap;
  depth <= 5 folder levels, each file <= 5 MB). UI walk: openFolder, select each file, folderUp per subfolder.
  Runs a Fixed/Desktop to Fixed folder sanitization job and asserts the core happy path from the minimal test plan:
  per-file outcomes match the two Allowed fixture layouts used by SA-02:
    Coverage: every eligible file under Allowed\Passed and every eligible file under the combined CDR folder are in the job.
    Allowed\Passed -> Passed for every such file; combined CDR folder on disk (e.g. Modified Or Recontructed; source UI
    uses Modified + Reconstructed) -> Modified or Reconstructed for every such file. Counters match;
    sanitized files exist on disk and destination UI/export checks align (mirrored subfolders under the job destination).
  After sanitization, destination verification calls ui.invoke refreshDestinationContent (navbar Refresh) at the job
  destination folder before listDestinationFiles / grid and exportReport checks.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - SA-TestFiles\Allowed on drive C:\ with Passed and a combined CDR subfolder (not separate Allowed\Modified / Allowed\Reconstructed).

.NOTES
  Test plan: SA-02 — Local sanitize pass / reconstructed / modified (see C:\Resec\Testing\SA-minimal-functional-testplan.htm).
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
    [int] $MinJobFiles = 1
)

$script:Sa02SelectAllFilesSentinel = [int]::MaxValue

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-ScanAgentDeployRequirements
}

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
$script:Sa02DefaultSourceSubfolder = 'Allowed'
$script:Sa02FixtureSubfolderPassed = 'Passed'
$script:Sa02FixtureSubfolderModified = 'Modified'
$script:Sa02FixtureSubfolderReconstructed = 'Reconstructed'
$script:Sa02CombinedCdrFixtureFolderNames = @(
    'Modified Or Reconstructed',
    'Modified Or Recontructed',
    'Modified or Reconstructed',
    'Modified or Recontructed'
)
$script:Sa02OutcomeFixtureKindPassed = 'Passed'
$script:Sa02OutcomeFixtureKindCombinedCdr = 'CombinedCdr'

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Get-CollectionCount {
    param([object] $Value)
    if ($null -eq $Value) {
        return 0
    }
    return @($Value).Count
}

function ConvertTo-FileInfoArray {
    param([object] $Value)

    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ($null -eq $Value) {
        return [System.IO.FileInfo[]]@()
    }

    foreach ($item in @($Value)) {
        if ($item -is [System.IO.FileInfo]) {
            $list.Add($item)
            continue
        }
        if ($item -is [System.Array]) {
            foreach ($inner in $item) {
                if ($inner -is [System.IO.FileInfo]) {
                    $list.Add($inner)
                }
            }
        }
    }

    return [System.IO.FileInfo[]]$list.ToArray()
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
        throw "ScanAgentDebug exited $($result.ExitCode): $commandLine`n$detail"
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
        return [string[]]@()
    }

    return [string[]]@($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
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

function Resolve-Sa02SourceFolderPath {
    param(
        [string] $SourceFolderOverride = '',
        [string] $TestFilesRoot = ''
    )

    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRoot

    if (-not [string]::IsNullOrWhiteSpace($SourceFolderOverride)) {
        $explicit = [System.IO.Path]::GetFullPath($SourceFolderOverride)
        if (-not (Test-DirectoryExists -Path $explicit)) {
            throw "Source folder does not exist on disk (will not auto-create): $explicit"
        }
        $saRootPrefix = $saRoot
        if (-not $saRootPrefix.EndsWith('\')) {
            $saRootPrefix += '\'
        }
        if (-not ($explicit.Equals($saRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $explicit.StartsWith($saRootPrefix, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Source folder '$explicit' must be under SA-TestFiles root '$saRoot' (or set -TestFilesRoot to match)."
        }
        return $explicit
    }

    $allowed = [System.IO.Path]::GetFullPath((Join-Path $saRoot $script:Sa02DefaultSourceSubfolder))
    if (-not (Test-DirectoryExists -Path $allowed)) {
        throw "SA-02 requires '$($script:Sa02DefaultSourceSubfolder)' under SA-TestFiles at '$allowed'. Create the folder and add fixtures, or pass -SourceFolder."
    }

    return $allowed
}

function Get-Sa02AllEligibleFilesUnderAllowed {
    param(
        [string] $AllowedRootPath,
        [int] $MaxFolderDepth = 5
    )

    $allowedRoot = [System.IO.Path]::GetFullPath($AllowedRootPath)
    if (-not (Test-DirectoryExists -Path $allowedRoot)) {
        throw "Allowed source folder does not exist on disk (will not auto-create): $allowedRoot"
    }

    $eligible = Get-EligibleFilesUnderFolder -RootFolder $allowedRoot -MaxFolderDepth $MaxFolderDepth
    $eligibleCount = Get-CollectionCount $eligible

    $onDiskTotal = 0
    $onDiskKeys = @{}
    try {
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($allowedRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
            $onDiskTotal++
            $onDiskKeys[$filePath.ToUpperInvariant()] = $true
        }
    }
    catch {
        throw "Cannot enumerate all files under Allowed root '$allowedRoot': $($_.Exception.Message)"
    }

    foreach ($file in (ConvertTo-FileInfoArray $eligible)) {
        if (-not $onDiskKeys.ContainsKey($file.FullName.ToUpperInvariant())) {
            throw "Internal error: eligible file not under Allowed tree: $($file.FullName)"
        }
    }

    Write-TestStep "Allowed job file set: $eligibleCount eligible file(s) under '$allowedRoot' (recursive; $onDiskTotal total file(s) on disk before eligibility rules)"
    return [System.IO.FileInfo[]](ConvertTo-FileInfoArray $eligible)
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

function Get-SanitizationFileEntries {
    param($FilesProperty)

    if ($null -eq $FilesProperty) {
        return ,@()
    }

    return ,@($FilesProperty)
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

    $patterns = @('block', 'reject', 'fail', 'denied', 'notallowed', 'skipped', 'negative')
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

function Test-OutcomeIsStrictPassed {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    $passTokens = @('outcomepassed', 'passed')
    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($passTokens -contains $token) {
            return $true
        }
    }

    return $false
}

function Test-OutcomeIsReconstructedOrModified {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    $cdrTokens = @('outcomereconstructed', 'outcomemodified', 'reconstructed', 'modified')
    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($cdrTokens -contains $token) {
            return $true
        }
        if ($token.Contains('reconstruct') -or $token.Contains('modif')) {
            return $true
        }
    }

    return $false
}

function Test-OutcomeIsStrictReconstructed {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($token -eq 'outcomereconstructed' -or $token -eq 'reconstructed') {
            return $true
        }
        if ($token.Contains('reconstruct') -and -not $token.Contains('modif')) {
            return $true
        }
    }

    return $false
}

function Test-OutcomeIsStrictModified {
    param(
        [string] $Outcome,
        [string] $OutcomeFriendly
    )

    foreach ($raw in @($Outcome, $OutcomeFriendly)) {
        $token = Normalize-OutcomeToken -Text $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($token -eq 'outcomemodified' -or $token -eq 'modified') {
            return $true
        }
        if ($token.Contains('modif') -and -not $token.Contains('reconstruct')) {
            return $true
        }
    }

    return $false
}

function Test-Sa02IsCombinedCdrFixtureSubfolder {
    param([string] $FolderName)

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    foreach ($alias in $script:Sa02CombinedCdrFixtureFolderNames) {
        if ($FolderName.Equals($alias, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-Sa02IsKnownAllowedFixtureSubfolder {
    param([string] $FolderName)

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    if ($FolderName.Equals($script:Sa02FixtureSubfolderPassed, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $FolderName
}

function Get-Sa02SourceFixtureSubfolderName {
    param(
        [string] $SourceRootPath,
        [string] $SourceFileFullPath
    )

    if ([string]::IsNullOrWhiteSpace($SourceRootPath) -or [string]::IsNullOrWhiteSpace($SourceFileFullPath)) {
        return $null
    }

    $relative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $SourceFileFullPath
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $null
    }

    $parts = [string[]]@($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
    if ((Get-CollectionCount $parts) -lt 2) {
        return $null
    }

    return $parts[0]
}

function Get-Sa02EligibleFileFixtureKind {
    param(
        [string] $SourceRootPath,
        [System.IO.FileInfo] $File
    )

    if ($null -eq $File) {
        return $null
    }

    $segment = Get-Sa02SourceFixtureSubfolderName -SourceRootPath $SourceRootPath -SourceFileFullPath $File.FullName
    if ([string]::IsNullOrWhiteSpace($segment)) {
        return $null
    }

    if ($segment.Equals($script:Sa02FixtureSubfolderPassed, [StringComparison]::OrdinalIgnoreCase)) {
        return $script:Sa02OutcomeFixtureKindPassed
    }

    if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $segment) {
        return $script:Sa02OutcomeFixtureKindCombinedCdr
    }

    return $null
}

function Measure-Sa02EligibleFixtureCoverage {
    param(
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $passedCount = 0
    $combinedCdrCount = 0
    foreach ($file in (ConvertTo-FileInfoArray $OnDiskSourceFiles)) {
        $kind = Get-Sa02EligibleFileFixtureKind -SourceRootPath $SourceRootPath -File $file
        if ($null -eq $kind) {
            throw "SA-02 eligible file must be under Allowed\$($script:Sa02FixtureSubfolderPassed) or a combined CDR folder (not Allowed root or other subfolders): '$($file.FullName)'."
        }
        if ($kind.Equals($script:Sa02OutcomeFixtureKindPassed, [StringComparison]::OrdinalIgnoreCase)) {
            $passedCount++
        }
        elseif ($kind.Equals($script:Sa02OutcomeFixtureKindCombinedCdr, [StringComparison]::OrdinalIgnoreCase)) {
            $combinedCdrCount++
        }
    }

    return [pscustomobject]@{
        Passed      = $passedCount
        CombinedCdr = $combinedCdrCount
    }
}

function Assert-Sa02FixtureCoverageEligibleFiles {
    param(
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $coverage = Measure-Sa02EligibleFixtureCoverage -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
    if ($coverage.Passed -lt 1) {
        throw "SA-02 coverage requires all eligible files under Allowed\$($script:Sa02FixtureSubfolderPassed); found 0 eligible file(s) there."
    }
    if ($coverage.CombinedCdr -lt 1) {
        throw "SA-02 coverage requires all eligible files under a combined CDR folder; found 0 eligible file(s) there."
    }

    Write-TestStep "SA-02 coverage: $($coverage.Passed) eligible Passed file(s) + $($coverage.CombinedCdr) eligible combined CDR file(s) = $(Get-CollectionCount $OnDiskSourceFiles) in job (all must be sanitized)."
}

function Assert-Sa02OutcomeMatchesSourceFixtureSubfolder {
    param(
        [string] $SourceFileFullPath,
        [string] $SourceRootPath,
        [string] $StatusOutcome,
        [string] $StatusOutcomeFriendly
    )

    $fixtureFolder = Get-Sa02SourceFixtureSubfolderName -SourceRootPath $SourceRootPath -SourceFileFullPath $SourceFileFullPath
    if ([string]::IsNullOrWhiteSpace($fixtureFolder)) {
        throw "SA-02 file '$SourceFileFullPath' must live under Allowed\$($script:Sa02FixtureSubfolderPassed) or a combined CDR folder (not directly under Allowed root)."
    }

    if ($fixtureFolder.Equals($script:Sa02FixtureSubfolderPassed, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-OutcomeIsStrictPassed -Outcome $StatusOutcome -OutcomeFriendly $StatusOutcomeFriendly)) {
            throw "File under Passed folder must have Passed outcome; got '$SourceFileFullPath' outcome='$StatusOutcome' friendly='$StatusOutcomeFriendly'."
        }
        return $script:Sa02OutcomeFixtureKindPassed
    }

    if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $fixtureFolder) {
        if (Test-OutcomeIsStrictModified -Outcome $StatusOutcome -OutcomeFriendly $StatusOutcomeFriendly) {
            return $script:Sa02OutcomeFixtureKindCombinedCdr
        }
        if (Test-OutcomeIsStrictReconstructed -Outcome $StatusOutcome -OutcomeFriendly $StatusOutcomeFriendly) {
            return $script:Sa02OutcomeFixtureKindCombinedCdr
        }
        throw "File under combined CDR fixture folder '$fixtureFolder' must have Modified or Reconstructed outcome; got '$SourceFileFullPath' outcome='$StatusOutcome' friendly='$StatusOutcomeFriendly'."
    }

    if ($fixtureFolder.Equals($script:Sa02FixtureSubfolderModified, [StringComparison]::OrdinalIgnoreCase) -or
        $fixtureFolder.Equals($script:Sa02FixtureSubfolderReconstructed, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SA-02 uses a combined CDR folder only; move '$SourceFileFullPath' under Allowed\Modified Or Reconstructed (not Allowed\$fixtureFolder)."
    }

    throw "SA-02 file '$SourceFileFullPath' is under unsupported Allowed subfolder '$fixtureFolder' (expected Passed or a combined CDR folder such as 'Modified Or Reconstructed')."
}

function Assert-Sa02HappyPathSanitizationOutcomes {
    param(
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath,
        $MainContentPayload
    )

    $selected = [int]$FinalStatus.counts.selected
    $passed = [int]$FinalStatus.counts.passed
    $blocked = [int]$FinalStatus.counts.blocked
    $running = [int]$FinalStatus.counts.running

    if ($blocked -ne 0) {
        throw "SA-02 expects no blocked/rejected files; counts.blocked=$blocked"
    }
    if ($passed -ne $selected) {
        throw "SA-02 expects all selected files to pass sanitization; passed=$passed selected=$selected"
    }
    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }

    $coverage = Measure-Sa02EligibleFixtureCoverage -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
    $verifiedPassed = 0
    $verifiedCombinedCdr = 0
    $verified = 0

    foreach ($sourceFile in (ConvertTo-FileInfoArray $OnDiskSourceFiles)) {
        $matchedEntry = $null
        $sourceFull = [System.IO.Path]::GetFullPath($sourceFile.FullName)
        foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
            $statusSourcePath = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @(
                'sourcePath', 'SourcePath', 'path', 'Path'
            )
            if (-not [string]::IsNullOrWhiteSpace($statusSourcePath)) {
                $statusFull = [System.IO.Path]::GetFullPath($statusSourcePath)
                if ($statusFull.Equals($sourceFull, [StringComparison]::OrdinalIgnoreCase)) {
                    $matchedEntry = $entry
                    break
                }
            }
        }

        if ($null -eq $matchedEntry) {
            $leafMatches = @(Get-SanitizationFileEntries -FilesProperty $FinalStatus.files | Where-Object {
                    $leaf = Get-StatusEntrySourceLeafName -FileEntry $_ -OnDiskSourceFiles $OnDiskSourceFiles
                    $leaf -and $leaf.Equals($sourceFile.Name, [StringComparison]::OrdinalIgnoreCase)
                })
            if ((Get-CollectionCount $leafMatches) -eq 1) {
                $matchedEntry = $leafMatches[0]
            }
        }

        if ($null -eq $matchedEntry) {
            throw "sanitization.status has no entry for on-disk file '$($sourceFile.FullName)'."
        }

        $statusOutcome = Get-SanitizationFileProperty -FileEntry $matchedEntry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $matchedEntry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            throw "File '$($sourceFile.FullName)' has non-success outcome: outcome='$statusOutcome' friendly='$statusFriendly'."
        }

        $fixtureKind = Assert-Sa02OutcomeMatchesSourceFixtureSubfolder -SourceFileFullPath $sourceFile.FullName `
            -SourceRootPath $SourceRootPath -StatusOutcome $statusOutcome -StatusOutcomeFriendly $statusFriendly
        $fixtureLabel = Get-Sa02SourceFixtureSubfolderName -SourceRootPath $SourceRootPath -SourceFileFullPath $sourceFile.FullName
        if ($fixtureKind.Equals($script:Sa02OutcomeFixtureKindPassed, [StringComparison]::OrdinalIgnoreCase)) {
            $verifiedPassed++
        }
        elseif ($fixtureKind.Equals($script:Sa02OutcomeFixtureKindCombinedCdr, [StringComparison]::OrdinalIgnoreCase)) {
            $verifiedCombinedCdr++
        }

        Write-TestStep "Outcome OK: '$($sourceFile.FullName)' [$fixtureLabel] -> outcome='$statusOutcome' friendly='$statusFriendly'"
        $verified++
    }

    $statusCount = Get-CollectionCount (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)
    if ($verified -ne $statusCount) {
        throw "Validated $verified on-disk job file(s) but sanitization.status has $statusCount file entries."
    }

    if ($verifiedPassed -ne $coverage.Passed) {
        throw "SA-02 coverage: expected all $($coverage.Passed) eligible Passed file(s) with Passed outcome; verified $verifiedPassed."
    }
    if ($verifiedCombinedCdr -ne $coverage.CombinedCdr) {
        throw "SA-02 coverage: expected all $($coverage.CombinedCdr) eligible combined CDR file(s) with Modified or Reconstructed outcome; verified $verifiedCombinedCdr."
    }

    $main = Get-MainContentRoot -Payload $MainContentPayload
    if ($null -ne $main -and $null -ne $main.activity) {
        $activityRejected = [int]$main.activity.rejected
        if ($activityRejected -ne 0) {
            throw "SA-02 expects activity.rejected=0; got $activityRejected"
        }
    }

    Write-TestStep "SA-02 happy-path outcomes verified for $verified file(s) ($verifiedPassed Passed + $verifiedCombinedCdr combined CDR); passed=$passed blocked=$blocked"
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
    $matchCount = Get-CollectionCount $matches
    if ($matchCount -eq 1) {
        return $matches[0]
    }
    if ($matchCount -gt 1) {
        throw "Ambiguous on-disk match for source file '$leaf' ($matchCount files under '$SourceRootPath'); sanitization.status must include sourcePath for nested Allowed fixtures."
    }

    return $null
}

function Get-ExpectedMirroredDestinationFilePath {
    param(
        $StatusEntry,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $reportedDest = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('destinationPath', 'DestinationPath')
    if (-not [string]::IsNullOrWhiteSpace($reportedDest)) {
        return [System.IO.Path]::GetFullPath($reportedDest)
    }

    $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath
    if ($null -eq $sourceFile -or [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        return $null
    }

    $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
    if ([string]::IsNullOrWhiteSpace($sourceRelative)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath((Join-Path $destRoot $sourceRelative))
}

function Get-DestinationFolderSearchPathsForStatusEntry {
    param(
        $StatusEntry,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $folderKeys = @{}
    $folderKeys[$destRoot.ToUpperInvariant()] = $destRoot

    $targetFolder = Get-DestinationFolderPathForStatusEntry -StatusEntry $StatusEntry -DestinationRoot $DestinationRoot `
        -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
    if (-not [string]::IsNullOrWhiteSpace($targetFolder)) {
        $targetFull = [System.IO.Path]::GetFullPath($targetFolder)
        $folderKeys[$targetFull.ToUpperInvariant()] = $targetFull
    }

    $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath
    if ($null -ne $sourceFile -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
        if (-not [string]::IsNullOrWhiteSpace($sourceRelative)) {
            $mirroredFile = [System.IO.Path]::GetFullPath((Join-Path $destRoot $sourceRelative))
            $dirPart = [System.IO.Path]::GetDirectoryName($mirroredFile)
            $walker = $destRoot
            $folderKeys[$walker.ToUpperInvariant()] = $walker
            foreach ($segment in ($sourceRelative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))) {
                if ($segment.Equals([System.IO.Path]::GetFileName($sourceRelative), [StringComparison]::OrdinalIgnoreCase)) {
                    break
                }
                $walker = [System.IO.Path]::GetFullPath((Join-Path $walker $segment))
                $folderKeys[$walker.ToUpperInvariant()] = $walker
            }
            if (-not [string]::IsNullOrWhiteSpace($dirPart)) {
                $folderKeys[[System.IO.Path]::GetFullPath($dirPart).ToUpperInvariant()] = [System.IO.Path]::GetFullPath($dirPart)
            }
        }
    }

    $reportedDest = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('destinationPath', 'DestinationPath')
    if (-not [string]::IsNullOrWhiteSpace($reportedDest)) {
        $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($reportedDest))
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $parentFull = [System.IO.Path]::GetFullPath($parent)
            $folderKeys[$parentFull.ToUpperInvariant()] = $parentFull
        }
    }

    return [string[]]@($folderKeys.Values | Sort-Object { $_.Length }, { $_ })
}

function Get-RecursiveFileCountUnderFolder {
    param([string] $RootPath)

    $root = [System.IO.Path]::GetFullPath($RootPath)
    if (-not (Test-DirectoryExists -Path $root)) {
        return 0
    }

    $count = 0
    try {
        foreach ($path in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $count++
        }
    }
    catch {
    }

    return $count
}

function Get-Sa02DestinationSearchFolderPathsForSourceFile {
    param(
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo] $SourceFile
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $folders = New-Object System.Collections.Generic.List[string]
    if ($null -eq $SourceFile) {
        return [string[]]@()
    }

    $segment = Get-Sa02SourceFixtureSubfolderName -SourceRootPath $SourceRootPath -SourceFileFullPath $SourceFile.FullName
    if ([string]::IsNullOrWhiteSpace($segment)) {
        return [string[]]@()
    }

    if ($segment.Equals($script:Sa02FixtureSubfolderPassed, [StringComparison]::OrdinalIgnoreCase)) {
        $folders.Add([System.IO.Path]::GetFullPath((Join-Path $destRoot $script:Sa02FixtureSubfolderPassed)))
    }
    elseif (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $segment) {
        $folders.Add([System.IO.Path]::GetFullPath((Join-Path $destRoot $segment)))
        if (Test-DirectoryExists -Path $destRoot) {
            foreach ($subdir in [System.IO.Directory]::EnumerateDirectories($destRoot)) {
                $dirName = [System.IO.Path]::GetFileName($subdir.TrimEnd('\'))
                if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $dirName) {
                    $folders.Add([System.IO.Path]::GetFullPath($subdir))
                    continue
                }
                if ($dirName.Equals($script:Sa02FixtureSubfolderModified, [StringComparison]::OrdinalIgnoreCase) -or
                    $dirName.Equals($script:Sa02FixtureSubfolderReconstructed, [StringComparison]::OrdinalIgnoreCase)) {
                    $folders.Add([System.IO.Path]::GetFullPath($subdir))
                }
            }
        }
    }
    else {
        $folders.Add([System.IO.Path]::GetFullPath((Join-Path $destRoot $segment)))
    }

    $unique = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder)) {
            continue
        }
        $full = [System.IO.Path]::GetFullPath($folder)
        if (-not (Test-DirectoryExists -Path $full)) {
            continue
        }
        $key = $full.ToUpperInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $unique.Add($full)
    }

    return [string[]]$unique.ToArray()
}

function Find-Sa02OnDiskDestinationArtifactPath {
    param(
        [string[]] $SearchFolders,
        [string] $SourceLeaf,
        [string[]] $CandidatePaths
    )

    foreach ($candidate in @($CandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        $candidateFull = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath $candidateFull -PathType Leaf) {
            return $candidateFull
        }
    }

    if ([string]::IsNullOrWhiteSpace($SourceLeaf)) {
        return $null
    }

    $sourceExt = [System.IO.Path]::GetExtension($SourceLeaf)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourceLeaf)

    foreach ($searchFolder in $SearchFolders) {
        if (-not (Test-DirectoryExists -Path $searchFolder)) {
            continue
        }

        $filesInTree = @(
            [System.IO.Directory]::EnumerateFiles($searchFolder, '*', [System.IO.SearchOption]::AllDirectories) |
                ForEach-Object { [System.IO.FileInfo]$_ }
        )

        foreach ($file in $filesInTree) {
            if ($file.Name.Equals($SourceLeaf, [StringComparison]::OrdinalIgnoreCase)) {
                return $file.FullName
            }
        }

        $sameBase = @(
            $filesInTree | Where-Object {
                [System.IO.Path]::GetFileNameWithoutExtension($_.Name).Equals($baseName, [StringComparison]::OrdinalIgnoreCase)
            }
        )
        if ((Get-CollectionCount $sameBase) -eq 1) {
            return $sameBase[0].FullName
        }
        if ((Get-CollectionCount $sameBase) -gt 1) {
            $exactExt = @($sameBase | Where-Object { $_.Extension.Equals($sourceExt, [StringComparison]::OrdinalIgnoreCase) })
            if ((Get-CollectionCount $exactExt) -eq 1) {
                return $exactExt[0].FullName
            }

            if ($sourceExt.Equals('.xlsx', [StringComparison]::OrdinalIgnoreCase)) {
                $xlsb = @($sameBase | Where-Object { $_.Extension.Equals('.xlsb', [StringComparison]::OrdinalIgnoreCase) })
                if ((Get-CollectionCount $xlsb) -eq 1) {
                    return $xlsb[0].FullName
                }
            }
        }
    }

    return $null
}

function Assert-DestinationTreeHasSanitizedFiles {
    param(
        [string] $DestinationRootPath,
        [int] $ExpectedPassedCount
    )

    $root = [System.IO.Path]::GetFullPath($DestinationRootPath)
    $rootOnly = @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue).Count
    $recursive = Get-RecursiveFileCountUnderFolder -RootPath $root
    $subdirs = @(
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
    $subdirText = if ((Get-CollectionCount $subdirs) -gt 0) { ($subdirs -join '; ') } else { '(none)' }
    Write-TestStep "Destination on disk: $rootOnly file(s) at root, $recursive file(s) in full tree; subfolders: $subdirText"
    if ($recursive -lt $ExpectedPassedCount) {
        throw "Expected at least $ExpectedPassedCount sanitized file(s) under destination tree '$root' (recursive count=$recursive)."
    }
}

function Assert-Sa02PassedFilesOnDiskUnderDestinationTree {
    param(
        $FinalStatus,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $verified = 0
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            continue
        }

        $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles `
            -SourceRootPath $SourceRootPath
        $leaf = if ($null -ne $sourceFile) { $sourceFile.Name } else { Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles }

        $candidatePaths = New-Object System.Collections.Generic.List[string]
        $mirrored = Get-ExpectedMirroredDestinationFilePath -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
        if (-not [string]::IsNullOrWhiteSpace($mirrored)) {
            $candidatePaths.Add($mirrored)
        }

        $reportedDest = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('destinationPath', 'DestinationPath')
        if (-not [string]::IsNullOrWhiteSpace($reportedDest)) {
            $candidatePaths.Add([System.IO.Path]::GetFullPath($reportedDest))
        }

        if ($null -ne $sourceFile) {
            $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
            if (-not [string]::IsNullOrWhiteSpace($sourceRelative)) {
                $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
                $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath((Join-Path $destRoot $sourceRelative)))
                if (-not [string]::IsNullOrWhiteSpace($parent) -and -not [string]::IsNullOrWhiteSpace($leaf)) {
                    $candidatePaths.Add([System.IO.Path]::GetFullPath((Join-Path $parent $leaf)))
                }
            }
        }

        $searchFolders = @()
        if ($null -ne $sourceFile) {
            $searchFolders = Get-Sa02DestinationSearchFolderPathsForSourceFile -DestinationRoot $DestinationRoot `
                -SourceRootPath $SourceRootPath -SourceFile $sourceFile
        }

        $hitPath = Find-Sa02OnDiskDestinationArtifactPath -SearchFolders $searchFolders -SourceLeaf $leaf `
            -CandidatePaths @($candidatePaths | Select-Object -Unique)

        if ([string]::IsNullOrWhiteSpace($hitPath)) {
            $listed = ($candidatePaths | Select-Object -Unique | ForEach-Object { "'$_'" }) -join ', '
            $searchText = if ((Get-CollectionCount $searchFolders) -gt 0) { ($searchFolders -join '; ') } else { '(no mapped subfolders)' }
            throw "Passed file '$leaf' has no on-disk destination artifact under expected destination subfolder(s) [$searchText] (explicit paths checked: $listed)."
        }

        Write-TestStep "Destination on-disk OK: '$hitPath' (source '$leaf')"
        $verified++
    }

    $passed = [int]$FinalStatus.counts.passed
    if ($verified -ne $passed) {
        throw "Verified $verified on-disk passed file(s) but counts.passed=$passed."
    }

    Write-TestStep "All $verified passed file(s) found on disk under destination tree (including subfolders)."
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

function Test-DestinationGridItemIsDirectory {
    param(
        $Item,
        [string] $CurrentDiskFolder = ''
    )

    if ($null -eq $Item -or $Item.isVisible -eq $false) {
        return $false
    }

    $typeName = [string] $Item.type
    if ($typeName.Equals('Directory', [StringComparison]::OrdinalIgnoreCase) -or
        $typeName.Equals('Folder', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ($null -ne $Item.PSObject.Properties['isDirectory'] -and $Item.isDirectory -eq $true) {
        return $true
    }

    return $false
}

function Get-DestinationGridFileItems {
    param(
        $ListPayload,
        [string] $CurrentDiskFolder = ''
    )

    if ($null -eq $ListPayload -or $null -eq $ListPayload.items) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($CurrentDiskFolder)) {
        $CurrentDiskFolder = Get-ListPayloadFolderPath -ListPayload $ListPayload
    }

    return @(
        $ListPayload.items |
            Where-Object {
                -not (Test-DestinationGridItemIsDirectory -Item $_ -CurrentDiskFolder $CurrentDiskFolder) -and
                    $_.isVisible -ne $false
            } |
            Sort-Object name
    )
}

function Get-DestinationGridDirectoryItems {
    param(
        $ListPayload,
        [string] $CurrentDiskFolder = ''
    )

    if ($null -eq $ListPayload -or $null -eq $ListPayload.items) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($CurrentDiskFolder)) {
        $CurrentDiskFolder = Get-ListPayloadFolderPath -ListPayload $ListPayload
    }

    return @(
        $ListPayload.items |
            Where-Object {
                Test-DestinationGridItemIsDirectory -Item $_ -CurrentDiskFolder $CurrentDiskFolder
            } |
            Sort-Object name
    )
}

function Find-DestinationGridDirectoryDisplayName {
    param(
        $ListPayload,
        [string] $DirectoryName,
        [string] $CurrentDiskFolder = ''
    )

    if ([string]::IsNullOrWhiteSpace($DirectoryName)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($CurrentDiskFolder)) {
        $CurrentDiskFolder = Get-ListPayloadFolderPath -ListPayload $ListPayload
    }

    foreach ($dir in (Get-DestinationGridDirectoryItems -ListPayload $ListPayload -CurrentDiskFolder $CurrentDiskFolder)) {
        $gridName = [string] $dir.name
        if ($gridName.Equals($DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
            return $gridName
        }
    }

    return $null
}

function Get-DestinationGridDirectoryNameListForDiagnostics {
    param(
        $ListPayload,
        [string] $CurrentDiskFolder = ''
    )

    $names = @(
        Get-DestinationGridDirectoryItems -ListPayload $ListPayload -CurrentDiskFolder $CurrentDiskFolder |
            ForEach-Object { [string] $_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ((Get-CollectionCount $names) -eq 0) {
        return '(none)'
    }
    return ($names -join ', ')
}

function Test-DestinationGridHasSubfolder {
    param(
        $ListPayload,
        [string] $FolderName,
        [string] $CurrentDiskFolder = ''
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace((
            Find-DestinationGridDirectoryDisplayName -ListPayload $ListPayload -DirectoryName $FolderName `
                -CurrentDiskFolder $CurrentDiskFolder
        ))
}

function Invoke-TryOpenDestinationSubfolder {
    param(
        [string] $Exe,
        [string] $FolderName,
        [string] $TargetDiskPath,
        [string] $StepLabel
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) {
        return $false
    }

    Write-TestStep "$StepLabel try openFolder (name) -> '$FolderName'"
    $open = Invoke-ScanAgentDebug -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'openFolder', '--panel', 'destination', '--name', $FolderName, '--wait-ms', "$UiWaitMs"
    )
    if ($open.ExitCode -eq 0) {
        $parsed = ConvertFrom-ScanAgentDebugOutput -Stdout $open.StdOut
        if ($null -ne $parsed -and $parsed.ok -eq $true) {
            return $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetDiskPath)) {
        $targetFull = [System.IO.Path]::GetFullPath($TargetDiskPath)
        Write-TestStep "$StepLabel try openFolder (path) -> '$targetFull'"
        $openPath = Invoke-ScanAgentDebug -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'destination', '--path', $targetFull, '--wait-ms', "$UiWaitMs"
        )
        if ($openPath.ExitCode -eq 0) {
            $parsedPath = ConvertFrom-ScanAgentDebugOutput -Stdout $openPath.StdOut
            if ($null -ne $parsedPath -and $parsedPath.ok -eq $true) {
                return $true
            }
        }
    }

    return $false
}

function Invoke-ClearDestinationPanelSearch {
    param(
        [string] $Exe,
        [string] $StepLabel
    )

    $clear = Invoke-ScanAgentDebug -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'clearSearch', '--panel', 'destination'
    )
    if ($clear.ExitCode -ne 0) {
        Write-TestStep "$StepLabel clearSearch destination exited $($clear.ExitCode) (continuing)"
        return
    }

    $parsed = ConvertFrom-ScanAgentDebugOutput -Stdout $clear.StdOut
    if ($null -eq $parsed -or $parsed.ok -ne $true) {
        Write-TestStep "$StepLabel clearSearch destination returned ok=false (continuing)"
    }
}

function Invoke-RefreshDestinationContent {
    param(
        [string] $Exe,
        [string] $StepLabel
    )

    Write-TestStep "$StepLabel ui.invoke refreshDestinationContent (destination navbar Refresh)"
    $refresh = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'refreshDestinationContent', '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $refresh -Step "$StepLabel refreshDestinationContent"
}

function Get-DestinationGridItemPathTokens {
    param(
        $GridItem,
        [string] $DestinationRoot = ''
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('path', 'Path', 'fullPath', 'FullPath', 'destinationPath', 'DestinationPath', 'relativePath', 'RelativePath')) {
        $value = Get-SanitizationFileProperty -FileEntry $GridItem -PropertyNames @($propertyName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $tokens.Add([System.IO.Path]::GetFullPath($value))
        }
    }

    $name = [string] $GridItem.name
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $tokens.Add($name)
        if (-not [string]::IsNullOrWhiteSpace($DestinationRoot) -and $name -notmatch '[\\/]') {
            $tokens.Add([System.IO.Path]::GetFullPath((Join-Path $DestinationRoot $name)))
        }
    }

    return [string[]]@($tokens | Select-Object -Unique)
}

function Get-DestinationGridFileNameListForDiagnostics {
    param($ListPayload)

    $currentDiskFolder = Get-ListPayloadFolderPath -ListPayload $ListPayload
    $names = @(
        Get-DestinationGridFileItems -ListPayload $ListPayload -CurrentDiskFolder $currentDiskFolder |
            ForEach-Object { [string] $_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ((Get-CollectionCount $names) -eq 0) {
        return '(no file rows)'
    }
    return ($names -join ', ')
}

function Invoke-NavigateDestinationToJobRoot {
    param(
        [string] $Exe,
        [string] $DestDriveUi,
        [string[]] $DestRootSegments,
        [string] $DestinationRoot,
        [string] $StepLabel
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)

    Write-TestStep "$StepLabel selectDestination root '$DestDriveUi' (job root '$destRoot')"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $DestDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "$StepLabel selectDestination"

    Invoke-NavigateDestinationSegments -Exe $Exe -Segments $DestRootSegments -StepPrefix "$StepLabel destination job root"

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed at destination job root ($StepLabel): exit $($ready.ExitCode) $($ready.StdOut)"
    }

    Invoke-RefreshDestinationContent -Exe $Exe -StepLabel $StepLabel
    Invoke-ClearDestinationPanelSearch -Exe $Exe -StepLabel $StepLabel

    $listAtLevel = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listDestinationFiles')
    Assert-OkResponse -Response $listAtLevel -Step "$StepLabel listDestinationFiles (job root)"
    Assert-DestinationFolderUnderRoot -ListPayload $listAtLevel -DestinationRoot $destRoot -StepLabel "$StepLabel job root"

    return $listAtLevel
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
    $sourceFull = if ($null -ne $sourceFile) { $sourceFile.FullName } else { $null }
    if ([string]::IsNullOrWhiteSpace($sourceFull)) {
        $sourceFull = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
    }

    $sourceRelative = $null
    if (-not [string]::IsNullOrWhiteSpace($sourceFull) -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFull
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
        return [string[]]@()
    }

    return [string[]]@($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
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

    if (-not $targetFolder.StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Target destination folder '$targetFolder' is not under job destination root '$destRoot'."
    }

    Write-TestStep "Navigate destination UI toward '$targetFolder' (job root '$destRoot')"
    $listAtLevel = Invoke-NavigateDestinationToJobRoot -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestRootSegments `
        -DestinationRoot $destRoot -StepLabel "destination verify"

    $reachedFolder = Get-ListPayloadFolderPath -ListPayload $listAtLevel
    if ([string]::IsNullOrWhiteSpace($reachedFolder)) {
        $reachedFolder = $destRoot
    }

    $reachedFullTarget = $false
    if ($targetFolder.Equals($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $reachedFullTarget = $true
    }
    elseif ($targetFolder.StartsWith($destRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeSegments = [string[]](Get-FolderSegmentsRelativeToRoot -RootFolder $destRoot -TargetFolder $targetFolder)
        if ((Get-CollectionCount $relativeSegments) -gt $MaxFolderDepth) {
            Write-TestStep "Destination folder depth exceeds MaxFolderDepth ($MaxFolderDepth); will search at reached level only."
        }
        else {
            $walker = [System.IO.Path]::GetFullPath($reachedFolder)
            foreach ($segment in $relativeSegments) {
                $nextDisk = [System.IO.Path]::GetFullPath((Join-Path $walker $segment))
                if (-not (Test-DestinationGridHasSubfolder -ListPayload $listAtLevel -FolderName $segment -CurrentDiskFolder $walker)) {
                    Write-TestStep "Destination subfolder '$segment' is not listed under '$walker'; staying at current grid level (on-disk path may still exist)."
                    break
                }

                if (-not (Invoke-TryOpenDestinationSubfolder -Exe $Exe -FolderName $segment -TargetDiskPath $nextDisk `
                        -StepLabel "Destination verify")) {
                    Write-TestStep "Destination openFolder failed for '$segment' under '$walker'; staying at current grid level (mirrored on-disk subfolders are not always UI-navigable)."
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

                $walker = [System.IO.Path]::GetFullPath($reachedFolder)
                if ($walker.Equals($targetFolder, [StringComparison]::OrdinalIgnoreCase)) {
                    $reachedFullTarget = $true
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($reachedFolder)) {
        $reachedFolder = $destRoot
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

function Test-DestinationGridPathTokenMatchesCandidate {
    param(
        [string] $PathToken,
        [string] $Candidate,
        [string] $DestinationRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($PathToken) -or [string]::IsNullOrWhiteSpace($Candidate)) {
        return $false
    }

    if ($Candidate.Contains('*')) {
        $leaf = [System.IO.Path]::GetFileName($PathToken)
        if (-not [string]::IsNullOrWhiteSpace($leaf) -and $leaf -like $Candidate) {
            return $true
        }
        return $false
    }

    if ($PathToken.Equals($Candidate, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $pathLeaf = [System.IO.Path]::GetFileName($PathToken)
    if ($pathLeaf.Equals($Candidate, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ($PathToken.EndsWith(('\' + $Candidate), [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($DestinationRoot)) {
        $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
        if (-not $destRoot.EndsWith('\')) {
            $destRoot += '\'
        }
        $mirrored = [System.IO.Path]::GetFullPath((Join-Path $destRoot $Candidate))
        if ($PathToken.Equals($mirrored, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Find-DestinationGridItemInList {
    param(
        $ListPayload,
        [string[]] $CandidateNames,
        [string] $DestinationRoot = '',
        [string[]] $CandidateDiskPaths = @()
    )

    $names = @($CandidateNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $diskPaths = @($CandidateDiskPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ((Get-CollectionCount $names) -eq 0 -and (Get-CollectionCount $diskPaths) -eq 0) {
        return $null
    }

    $currentDiskFolder = Get-ListPayloadFolderPath -ListPayload $ListPayload
    foreach ($gridItem in (Get-DestinationGridFileItems -ListPayload $ListPayload -CurrentDiskFolder $currentDiskFolder)) {
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

        foreach ($pathToken in (Get-DestinationGridItemPathTokens -GridItem $gridItem -DestinationRoot $DestinationRoot)) {
            foreach ($candidate in $names) {
                if (Test-DestinationGridPathTokenMatchesCandidate -PathToken $pathToken -Candidate $candidate -DestinationRoot $DestinationRoot) {
                    return $gridItem
                }
            }
            foreach ($diskPath in $diskPaths) {
                if ($pathToken.Equals([System.IO.Path]::GetFullPath($diskPath), [StringComparison]::OrdinalIgnoreCase)) {
                    return $gridItem
                }
            }
        }
    }

    return $null
}

function Find-DestinationGridItemUsingDestinationSearch {
    param(
        [string] $Exe,
        [string] $DestDriveUi,
        [string[]] $DestRootSegments,
        [string] $DestinationRoot,
        [string[]] $CandidateNames,
        [string[]] $CandidateDiskPaths,
        [string] $SearchTerm,
        [string] $StepLabel
    )

    if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
        return $null
    }

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $listAtJobRoot = Invoke-NavigateDestinationToJobRoot -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestRootSegments `
        -DestinationRoot $destRoot -StepLabel "$StepLabel search prep"

    Invoke-ClearDestinationPanelSearch -Exe $Exe -StepLabel $StepLabel

    Write-TestStep "$StepLabel destination search filter -> '$SearchTerm'"
    $search = Invoke-ScanAgentDebug -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'search', '--panel', 'destination', '--name', $SearchTerm, '--wait-ms', "$UiWaitMs"
    )
    if ($search.ExitCode -ne 0) {
        Invoke-ClearDestinationPanelSearch -Exe $Exe -StepLabel $StepLabel
        return $null
    }

    $searchParsed = ConvertFrom-ScanAgentDebugOutput -Stdout $search.StdOut
    if ($null -eq $searchParsed -or $searchParsed.ok -ne $true) {
        Invoke-ClearDestinationPanelSearch -Exe $Exe -StepLabel $StepLabel
        return $null
    }

    $listFiltered = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listDestinationFiles')
    Assert-OkResponse -Response $listFiltered -Step "$StepLabel listDestinationFiles (search)"

    $hit = Find-DestinationGridItemInList -ListPayload $listFiltered -CandidateNames $CandidateNames `
        -DestinationRoot $destRoot -CandidateDiskPaths $CandidateDiskPaths

    Invoke-ClearDestinationPanelSearch -Exe $Exe -StepLabel $StepLabel

    if ($null -eq $hit) {
        return $null
    }

    $folderPath = Get-ListPayloadFolderPath -ListPayload $listFiltered
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        $folderPath = $destRoot
    }

    return [pscustomobject]@{
        GridItem          = $hit
        ListPayload       = $listFiltered
        ReachedFolderPath = [System.IO.Path]::GetFullPath($folderPath)
        UsedSearch        = $true
    }
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

    $resolvedSource = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles `
        -SourceRootPath $SourceRootPath
    if ($null -ne $resolvedSource -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
        $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $resolvedSource.FullName
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

        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        if ($OnDiskSourceFiles -and -not [string]::IsNullOrWhiteSpace($sourceLeaf) -and -not [string]::IsNullOrWhiteSpace($SourceRootPath)) {
            $sourceFile = $OnDiskSourceFiles | Where-Object { $_.Name -eq $sourceLeaf } | Select-Object -First 1
            if ($null -ne $sourceFile) {
                $relative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
                if (-not [string]::IsNullOrWhiteSpace($relative)) {
                    $mirroredPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $relative))
                    if (Test-Path -LiteralPath $mirroredPath -PathType Leaf) {
                        throw "Blocked/rejected file must not exist on disk at mirrored destination path: '$mirroredPath'"
                    }
                }
            }
        }
    }

    Write-TestStep 'Confirmed blocked/rejected job files have no on-disk artifacts under the destination folder.'
}

function Assert-Sa04BlockedFilesVisualStatus {
    param(
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $verified = 0
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        if ([string]::IsNullOrWhiteSpace($sourceLeaf)) {
            throw 'Job status contains a file entry without a resolvable source file name.'
        }

        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if ([string]::IsNullOrWhiteSpace($statusOutcome) -and [string]::IsNullOrWhiteSpace($statusFriendly)) {
            throw "Blocked file '$sourceLeaf' has no outcome/outcomeFriendly in sanitization.status."
        }

        if (-not (Test-OutcomeIsBlockedOrRejected -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            throw "Expected blocked/rejected outcome for '$sourceLeaf'; got outcome='$statusOutcome' friendly='$statusFriendly'."
        }

        $details = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('details', 'Details', 'outcomeFriendly', 'OutcomeFriendly')
        Write-TestStep "Blocked file SA visual status OK: '$sourceLeaf' outcome='$statusOutcome' friendly='$statusFriendly' details='$details'"
        $verified++
    }

    if ($verified -lt 1) {
        throw 'No blocked/rejected per-file outcomes were validated in sanitization.status.'
    }
}

function Find-RejectedDrawerItemForStatusEntry {
    param(
        $StatusEntry,
        [object[]] $DrawerItems,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles
    $sourcePath = Get-SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')

    foreach ($item in $DrawerItems) {
        $drawerName = [string] $item.name
        if (-not [string]::IsNullOrWhiteSpace($sourceLeaf) -and $drawerName.Equals($sourceLeaf, [StringComparison]::OrdinalIgnoreCase)) {
            return $item
        }

        $drawerSource = $null
        if ($null -ne $item.PSObject.Properties['sourcePath']) {
            $drawerSource = [string] $item.sourcePath
        }
        if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and -not [string]::IsNullOrWhiteSpace($drawerSource)) {
            if ([System.IO.Path]::GetFullPath($drawerSource).Equals([System.IO.Path]::GetFullPath($sourcePath), [StringComparison]::OrdinalIgnoreCase)) {
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

        $drawerItem = Find-RejectedDrawerItemForStatusEntry -StatusEntry $entry -DrawerItems $drawerItems -OnDiskSourceFiles $OnDiskSourceFiles
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

function Get-SourceMirrorSubfolderSegmentName {
    param(
        [string] $SourceRootPath,
        [string] $SourceFileFullPath
    )

    return Get-Sa02SourceFixtureSubfolderName -SourceRootPath $SourceRootPath -SourceFileFullPath $SourceFileFullPath
}

function Test-Sa02DestinationMirroredSubfolderGridLayout {
    param(
        [string] $DestinationRoot,
        $JobRootListPayload
    )

    $root = [System.IO.Path]::GetFullPath($DestinationRoot)
    $listFolder = Get-ListPayloadFolderPath -ListPayload $JobRootListPayload
    if ([string]::IsNullOrWhiteSpace($listFolder)) {
        return $false
    }
    if (-not [System.IO.Path]::GetFullPath($listFolder).Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $fileRowCount = Get-CollectionCount (Get-DestinationGridFileItems -ListPayload $JobRootListPayload)
    if ($fileRowCount -gt 0) {
        return $false
    }

    $dirRowCount = Get-CollectionCount (Get-DestinationGridDirectoryItems -ListPayload $JobRootListPayload)
    if ($dirRowCount -lt 1) {
        return $false
    }

    $subdirCount = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue).Count
    if ($subdirCount -lt 1) {
        return $false
    }

    return $true
}

function Test-DestinationGridHasMirroredSubfolderRow {
    param(
        [hashtable] $DirNameKeys,
        [string] $SegmentName
    )

    if ([string]::IsNullOrWhiteSpace($SegmentName)) {
        return $false
    }

    if ($DirNameKeys.ContainsKey($SegmentName.ToUpperInvariant())) {
        return $true
    }

    if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $SegmentName) {
        foreach ($alias in $script:Sa02CombinedCdrFixtureFolderNames) {
            if ($DirNameKeys.ContainsKey($alias.ToUpperInvariant())) {
                return $true
            }
        }

        $hasModUi = $DirNameKeys.ContainsKey($script:Sa02FixtureSubfolderModified.ToUpperInvariant())
        $hasReconUi = $DirNameKeys.ContainsKey($script:Sa02FixtureSubfolderReconstructed.ToUpperInvariant())
        if ($hasModUi -and $hasReconUi) {
            return $true
        }
    }

    return $false
}

function Assert-Sa02MirroredDestinationJobRootGrid {
    param(
        $JobRootListPayload,
        [string] $DestinationRoot,
        [string] $SourceRootPath,
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $dirNames = @(
        Get-DestinationGridDirectoryItems -ListPayload $JobRootListPayload |
            ForEach-Object { [string] $_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $dirNameKeys = @{}
    foreach ($name in $dirNames) {
        $dirNameKeys[$name.ToUpperInvariant()] = $name
    }

    Write-TestStep "SA-02 mirrored destination layout: job-root grid shows subfolder row(s) only: $($dirNames -join ', ') (per-file rows are on disk under those folders; Debug openFolder cannot drill into mirrored subfolders)"

    $verifiedSegments = @{}
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            continue
        }

        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles `
            -SourceRootPath $SourceRootPath
        $segment = $null
        if ($null -ne $sourceFile) {
            $segment = Get-SourceMirrorSubfolderSegmentName -SourceRootPath $SourceRootPath -SourceFileFullPath $sourceFile.FullName
        }

        if ([string]::IsNullOrWhiteSpace($segment)) {
            throw "Passed file '$sourceLeaf' is not under a source subfolder; mirrored destination grid mode requires Allowed fixture subfolders."
        }

        $mirroredDir = [System.IO.Path]::GetFullPath((Join-Path $destRoot $segment))
        if (-not (Test-DirectoryExists -Path $mirroredDir)) {
            throw "On-disk destination is missing mirrored folder '$mirroredDir' for '$sourceLeaf'."
        }

        if (-not (Test-DestinationGridHasMirroredSubfolderRow -DirNameKeys $dirNameKeys -SegmentName $segment)) {
            throw "Destination job-root grid is missing mirrored subfolder row for '$segment' (source file '$sourceLeaf'; visible rows: $($dirNames -join ', '))."
        }

        if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $segment) {
            $segmentKey = ('CDR:' + $segment).ToUpperInvariant()
            if (-not $verifiedSegments.ContainsKey($segmentKey)) {
                Write-TestStep "Destination mirrored CDR folder row OK for '$segment' (on-disk '$mirroredDir')"
                $verifiedSegments[$segmentKey] = $true
            }
            continue
        }

        $segmentKey = $segment.ToUpperInvariant()
        if (-not $verifiedSegments.ContainsKey($segmentKey)) {
            Write-TestStep "Destination mirrored subfolder row OK: '$segment' (on-disk '$mirroredDir')"
            $verifiedSegments[$segmentKey] = $true
        }
    }

    if ((Get-CollectionCount $verifiedSegments.Keys) -lt 1) {
        throw 'No mirrored destination subfolder rows were verified at the job-root grid.'
    }
}

function Get-ExportReportRowPropertyValue {
    param(
        $Row,
        [string[]] $PropertyNameHints
    )

    if ($null -eq $Row) {
        return $null
    }

    foreach ($hint in $PropertyNameHints) {
        foreach ($prop in $Row.PSObject.Properties) {
            if ($prop.Name -like $hint) {
                $value = [string] $prop.Value
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return $value
                }
            }
        }
    }

    return $null
}

function Assert-Sa02DestinationExportReportMatchesStatus {
    param(
        [string] $Exe,
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath
    )

    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        throw 'Cannot export SA job report: TEMP is not set.'
    }

    $reportPath = [System.IO.Path]::GetFullPath((Join-Path $tempRoot ('SA02_export_' + [guid]::NewGuid().ToString('N') + '.csv')))
    Write-TestStep "Export job report for per-file destination outcomes -> '$reportPath'"
    $export = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'exportReport', '--path', $reportPath
    )
    Assert-OkResponse -Response $export -Step 'exportReport'

    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "exportReport did not create file at '$reportPath'."
    }

    $rows = @(Import-Csv -LiteralPath $reportPath)
    if ((Get-CollectionCount $rows) -lt 1) {
        throw "exportReport CSV '$reportPath' has no data rows."
    }

    $verified = 0
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $statusOutcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $statusFriendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (-not (Test-OutcomeIsPassedSanitize -Outcome $statusOutcome -OutcomeFriendly $statusFriendly)) {
            continue
        }

        $sourceLeaf = Get-StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles
        $sourceFile = Resolve-OnDiskSourceFileForStatusEntry -FileEntry $entry -OnDiskSourceFiles $OnDiskSourceFiles `
            -SourceRootPath $SourceRootPath
        $sourceRelative = $null
        if ($null -ne $sourceFile) {
            $sourceRelative = Get-PathRelativeToFolder -RootFolder $SourceRootPath -FullPath $sourceFile.FullName
        }

        $matchedRow = $null
        foreach ($row in $rows) {
            $nameCell = Get-ExportReportRowPropertyValue -Row $row -PropertyNameHints @('*name*', '*file*', '*source*', '*path*')
            $pathCell = Get-ExportReportRowPropertyValue -Row $row -PropertyNameHints @('*path*', '*destination*', '*target*')
            $haystack = @($nameCell, $pathCell) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($text in $haystack) {
                if ($text.Equals($sourceLeaf, [StringComparison]::OrdinalIgnoreCase)) {
                    $matchedRow = $row
                    break
                }
                if (-not [string]::IsNullOrWhiteSpace($sourceRelative) -and $text.EndsWith($sourceRelative, [StringComparison]::OrdinalIgnoreCase)) {
                    $matchedRow = $row
                    break
                }
                if ($text.EndsWith(('\' + $sourceLeaf), [StringComparison]::OrdinalIgnoreCase)) {
                    $matchedRow = $row
                    break
                }
            }
            if ($null -ne $matchedRow) {
                break
            }
        }

        if ($null -eq $matchedRow) {
            throw "exportReport CSV has no row for passed file '$sourceLeaf' (sourceRelative='$sourceRelative')."
        }

        $reportOutcome = Get-ExportReportRowPropertyValue -Row $matchedRow -PropertyNameHints @('*outcome*', '*result*', '*status*')
        $reportDetails = Get-ExportReportRowPropertyValue -Row $matchedRow -PropertyNameHints @('*detail*', '*friendly*', '*description*')
        if (-not (Test-OutcomeTokensAlign -StatusOutcome $statusOutcome -StatusOutcomeFriendly $statusFriendly `
                -GridOutcome $reportOutcome -GridStatusText $reportDetails)) {
            throw "exportReport outcome mismatch for '$sourceLeaf': report='$reportOutcome' details='$reportDetails' status='$statusOutcome' friendly='$statusFriendly'."
        }

        Write-TestStep "exportReport row OK for '$sourceLeaf' outcome='$reportOutcome'"
        $verified++
    }

    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue

    if ($verified -lt 1) {
        throw 'No passed files were verified in exportReport CSV.'
    }

    Write-TestStep "exportReport verified $verified passed file(s) with outcomes aligned to sanitization.status."
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

    Write-TestStep 'Post-job: refresh destination and verify grid for passed file(s) only'

    $folderNavCache = @{}
    $verifiedRows = 0
    $destRootFull = [System.IO.Path]::GetFullPath($DestinationRoot)

    $jobRootList = Invoke-NavigateDestinationToJobRoot -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestSegments `
        -DestinationRoot $DestinationRoot -StepLabel 'Post-job destination verify'
    $jobRootNav = [pscustomobject]@{
        ListPayload       = $jobRootList
        ReachedFolderPath = $destRootFull
        ReachedFullTarget = $true
    }
    $folderNavCache[$destRootFull.ToUpperInvariant()] = $jobRootNav
    if (Test-Sa02DestinationMirroredSubfolderGridLayout -DestinationRoot $destRootFull -JobRootListPayload $jobRootNav.ListPayload) {
        Assert-Sa02MirroredDestinationJobRootGrid -JobRootListPayload $jobRootNav.ListPayload -DestinationRoot $destRootFull `
            -SourceRootPath $SourceRootPath -FinalStatus $FinalStatus -OnDiskSourceFiles $OnDiskSourceFiles
        Assert-Sa02DestinationExportReportMatchesStatus -Exe $Exe -FinalStatus $FinalStatus -OnDiskSourceFiles $OnDiskSourceFiles `
            -SourceRootPath $SourceRootPath
        Write-TestStep "Destination verification complete for mirrored subfolder layout ($passedCount passed file(s); job-root folder rows + exportReport + on-disk tree)."
        return
    }

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

        $searchFolders = [string[]](Get-DestinationFolderSearchPathsForStatusEntry -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles)

        $candidateDiskPaths = New-Object System.Collections.Generic.List[string]
        $mirroredPath = Get-ExpectedMirroredDestinationFilePath -StatusEntry $entry -DestinationRoot $DestinationRoot `
            -SourceRootPath $SourceRootPath -OnDiskSourceFiles $OnDiskSourceFiles
        if (-not [string]::IsNullOrWhiteSpace($mirroredPath)) {
            $candidateDiskPaths.Add($mirroredPath)
        }
        $reportedDestPath = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('destinationPath', 'DestinationPath')
        if (-not [string]::IsNullOrWhiteSpace($reportedDestPath)) {
            $candidateDiskPaths.Add([System.IO.Path]::GetFullPath($reportedDestPath))
        }
        $candidateDiskPathArray = [string[]]@($candidateDiskPaths | Select-Object -Unique)

        $gridItem = $null
        $destList = $null
        $folderPath = $null
        $lastNav = $null
        foreach ($searchFolder in $searchFolders) {
            $nav = Get-DestinationListForFolder -Exe $Exe -DestDriveUi $DestDriveUi -DestRootSegments $DestSegments `
                -DestinationRoot $DestinationRoot -FolderPath $searchFolder -MaxFolderDepth $MaxFolderDepth -Cache $folderNavCache
            $lastNav = $nav

            $tryList = $nav.ListPayload
            $tryHit = Find-DestinationGridItemInList -ListPayload $tryList -CandidateNames $candidateNames `
                -DestinationRoot $destRootFull -CandidateDiskPaths $candidateDiskPathArray
            if ($null -ne $tryHit) {
                $gridItem = $tryHit
                $destList = $tryList
                $folderPath = $nav.ReachedFolderPath
                Write-TestStep "Found destination row for '$sourceLeaf' under '$folderPath'"
                break
            }

            $visibleFiles = Get-DestinationGridFileNameListForDiagnostics -ListPayload $tryList
            Write-TestStep "No destination row for '$sourceLeaf' at '$($nav.ReachedFolderPath)' (reachedFullTarget=$($nav.ReachedFullTarget); visible files: $visibleFiles; candidates: $($candidateNames -join ', '))"
        }

        if ($null -eq $gridItem) {
            $searchHit = Find-DestinationGridItemUsingDestinationSearch -Exe $Exe -DestDriveUi $DestDriveUi `
                -DestRootSegments $DestSegments -DestinationRoot $destRootFull -CandidateNames $candidateNames `
                -CandidateDiskPaths $candidateDiskPathArray -SearchTerm $sourceLeaf -StepLabel "destination search '$sourceLeaf'"
            if ($null -ne $searchHit) {
                $gridItem = $searchHit.GridItem
                $destList = $searchHit.ListPayload
                $folderPath = $searchHit.ReachedFolderPath
                Write-TestStep "Found destination row for '$sourceLeaf' via destination search under '$folderPath'"
            }
        }

        if ($null -eq $gridItem) {
            $diagFolder = if ($null -ne $lastNav) { $lastNav.ReachedFolderPath } else { $destRootFull }
            $diagList = if ($null -ne $lastNav) { $lastNav.ListPayload } else { $null }
            $diagFiles = if ($null -ne $diagList) { Get-DestinationGridFileNameListForDiagnostics -ListPayload $diagList } else { '(unknown)' }
            throw "No destination grid row for '$sourceLeaf' (searched job root and '$targetFolder'; last grid '$diagFolder' files: $diagFiles; candidates: $($candidateNames -join ', '))."
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
            $reportedDest = $reportedDestPath
            $diskPath = $null
            foreach ($candidate in @($fullItemPath, $mirroredPath, $reportedDest)) {
                if ([string]::IsNullOrWhiteSpace($candidate)) {
                    continue
                }
                $candidateFull = [System.IO.Path]::GetFullPath($candidate)
                if (Test-Path -LiteralPath $candidateFull -PathType Leaf) {
                    $diskPath = $candidateFull
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($diskPath)) {
                throw "Passed file '$sourceLeaf' has no on-disk destination artifact (grid='$fullItemPath' mirrored='$mirroredPath' reported='$reportedDest')."
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

function Get-SourceGridFileItems {
    param($ListPayload)

    if ($null -eq $ListPayload -or $null -eq $ListPayload.items) {
        return @()
    }

    return @(
        $ListPayload.items |
            Where-Object {
                $typeName = [string] $_.type
                $typeName -ne 'Directory' -and $_.isVisible -ne $false
            } |
            Sort-Object name
    )
}

function Get-SourceGridDirectoryItems {
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

function Find-SourceGridCombinedCdrFolderDisplayName {
    param(
        $ListPayload,
        [string] $CombinedDiskFolderPath
    )

    $diskName = [System.IO.Path]::GetFileName($CombinedDiskFolderPath.TrimEnd('\'))
    if (-not [string]::IsNullOrWhiteSpace($diskName)) {
        $gridName = Find-SourceGridDirectoryDisplayName -ListPayload $ListPayload -DirectoryName $diskName
        if (-not [string]::IsNullOrWhiteSpace($gridName)) {
            return $gridName
        }
    }

    foreach ($alias in $script:Sa02CombinedCdrFixtureFolderNames) {
        $gridName = Find-SourceGridDirectoryDisplayName -ListPayload $ListPayload -DirectoryName $alias
        if (-not [string]::IsNullOrWhiteSpace($gridName)) {
            return $gridName
        }
    }

    return $null
}

function Select-Sa02EligibleFilesVisibleInCurrentSourceGrid {
    param(
        [string] $Exe,
        [System.IO.FileInfo[]] $EligibleFiles,
        [ref] $SelectedCount,
        [hashtable] $SelectedNames,
        [int] $MaxJobFiles,
        [string] $StepLabel
    )

    $listInUi = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listInUi -Step "listSourceFiles ($StepLabel)"

    $visibleLeaves = @{}
    foreach ($gridItem in (Get-SourceGridFileItems -ListPayload $listInUi)) {
        $leaf = [string] $gridItem.name
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            $visibleLeaves[$leaf.ToUpperInvariant()] = $true
        }
    }

    foreach ($diskFile in (ConvertTo-FileInfoArray $EligibleFiles)) {
        if ($MaxJobFiles -gt 0 -and $SelectedCount.Value -ge $MaxJobFiles) {
            break
        }
        if (-not $visibleLeaves.ContainsKey($diskFile.Name.ToUpperInvariant())) {
            continue
        }

        $selectKey = $diskFile.FullName.ToUpperInvariant()
        if ($SelectedNames.ContainsKey($selectKey)) {
            continue
        }

        Write-TestStep "Select file '$($diskFile.Name)' ($StepLabel)"
        $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--name', $diskFile.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $select -Step "selectSourceFile ($($diskFile.Name) $StepLabel)"
        $SelectedNames[$selectKey] = $true
        $SelectedCount.Value++
    }
}

function Assert-Sa02AllEligibleFilesSelected {
    param(
        [System.IO.FileInfo[]] $EligibleFiles,
        [hashtable] $SelectedNames,
        [string] $ContextLabel
    )

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($diskFile in (ConvertTo-FileInfoArray $EligibleFiles)) {
        $selectKey = $diskFile.FullName.ToUpperInvariant()
        if (-not $SelectedNames.ContainsKey($selectKey)) {
            $missing.Add($diskFile.FullName)
        }
    }

    if ((Get-CollectionCount $missing) -gt 0) {
        throw "${ContextLabel}: failed to select eligible file(s): $($missing -join '; ')"
    }
}

function Select-Sa02FilesFromCombinedCdrDiskFolder {
    param(
        [string] $Exe,
        [string] $CombinedDiskFolderPath,
        [string] $ParentDiskFolderPath,
        [string] $SourceRootPath,
        [string] $SourceDriveUi,
        [ref] $SelectedCount,
        [ref] $FoldersUsed,
        [hashtable] $SelectedNames,
        [hashtable] $EligiblePathSet,
        [int] $MaxJobFiles = 10
    )

    $combinedPath = [System.IO.Path]::GetFullPath($CombinedDiskFolderPath)
    $combinedFolderName = [System.IO.Path]::GetFileName($combinedPath.TrimEnd('\'))
    $combinedPrefix = $combinedPath
    if (-not $combinedPrefix.EndsWith('\')) {
        $combinedPrefix += '\'
    }
    $combinedPrefix = $combinedPrefix.ToUpperInvariant()

    $eligibleFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($key in $EligiblePathSet.Keys) {
        $full = [System.IO.Path]::GetFullPath([string] $key)
        if ($full.StartsWith($combinedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $eligibleFiles.Add([System.IO.FileInfo]$full)
        }
    }

    if ((Get-CollectionCount $eligibleFiles) -eq 0) {
        Write-TestStep "No eligible files under combined CDR disk folder '$combinedPath'"
        return
    }

    $parentPath = [System.IO.Path]::GetFullPath($ParentDiskFolderPath)
    $FoldersUsed.Value = $true

    $listAtParent = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $parentPath -SourceDriveUi $SourceDriveUi `
        -StepLabel "before combined CDR folder '$combinedFolderName'"
    $unifiedGridName = Find-SourceGridCombinedCdrFolderDisplayName -ListPayload $listAtParent -CombinedDiskFolderPath $combinedPath

    if (-not [string]::IsNullOrWhiteSpace($unifiedGridName)) {
        Write-TestStep "Select files from combined CDR disk folder '$combinedPath' via source UI folder '$unifiedGridName' (files in folder root)"
        Invoke-OpenSourceSubfolderFromGrid -Exe $Exe -ParentDiskPath $parentPath -SubfolderName $combinedFolderName `
            -TargetDiskPath $combinedPath -SourceDriveUi $SourceDriveUi -StepLabel "combined CDR '$unifiedGridName'"

        Select-Sa02EligibleFilesVisibleInCurrentSourceGrid -Exe $Exe -EligibleFiles $eligibleFiles `
            -SelectedCount $SelectedCount -SelectedNames $SelectedNames -MaxJobFiles $MaxJobFiles `
            -StepLabel "combined CDR folder '$unifiedGridName'"

        Assert-Sa02AllEligibleFilesSelected -EligibleFiles $eligibleFiles -SelectedNames $SelectedNames `
            -ContextLabel "Combined CDR folder '$combinedPath'"

        Write-TestStep "folderUp from combined CDR UI folder '$unifiedGridName'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source combined CDR ($unifiedGridName)"
        $null = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $parentPath -SourceDriveUi $SourceDriveUi `
            -StepLabel "after combined CDR '$unifiedGridName'"
        return
    }

    Write-TestStep "Select files from combined CDR disk folder '$combinedPath' via split source UI folders Modified and Reconstructed"

    foreach ($uiFolder in @($script:Sa02FixtureSubfolderModified, $script:Sa02FixtureSubfolderReconstructed)) {
        if ($MaxJobFiles -gt 0 -and $SelectedCount.Value -ge $MaxJobFiles) {
            return
        }

        $list = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $parentPath -SourceDriveUi $SourceDriveUi `
            -StepLabel "before CDR UI folder '$uiFolder'"
        $gridName = Find-SourceGridDirectoryDisplayName -ListPayload $list -DirectoryName $uiFolder
        if ([string]::IsNullOrWhiteSpace($gridName)) {
            continue
        }

        Write-TestStep "Open source UI folder '$gridName' (disk CDR files under '$combinedPath')"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $gridName, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source CDR ($gridName)"

        Select-Sa02EligibleFilesVisibleInCurrentSourceGrid -Exe $Exe -EligibleFiles $eligibleFiles `
            -SelectedCount $SelectedCount -SelectedNames $SelectedNames -MaxJobFiles $MaxJobFiles `
            -StepLabel "CDR UI folder '$gridName'"

        Write-TestStep "folderUp from CDR UI folder '$gridName'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source CDR ($gridName)"
        $null = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $parentPath -SourceDriveUi $SourceDriveUi `
            -StepLabel "after CDR UI folder '$gridName'"
    }

    Assert-Sa02AllEligibleFilesSelected -EligibleFiles $eligibleFiles -SelectedNames $SelectedNames `
        -ContextLabel "Combined CDR disk folder '$combinedPath' (split Modified/Reconstructed UI)"

    $hasMod = -not [string]::IsNullOrWhiteSpace((Find-SourceGridDirectoryDisplayName -ListPayload $listAtParent -DirectoryName $script:Sa02FixtureSubfolderModified))
    $hasRecon = -not [string]::IsNullOrWhiteSpace((Find-SourceGridDirectoryDisplayName -ListPayload $listAtParent -DirectoryName $script:Sa02FixtureSubfolderReconstructed))
    if (-not $hasMod -and -not $hasRecon) {
        $visible = Get-SourceGridDirectoryNameListForDiagnostics -ListPayload $listAtParent
        throw "Source grid at '$parentPath' has no combined CDR folder '$combinedFolderName' and no Modified/Reconstructed UI folders for disk '$combinedPath'. Visible directories: $visible"
    }
}

function Find-SourceGridDirectoryDisplayName {
    param(
        $ListPayload,
        [string] $DirectoryName
    )

    if ([string]::IsNullOrWhiteSpace($DirectoryName)) {
        return $null
    }

    foreach ($dir in (Get-SourceGridDirectoryItems -ListPayload $ListPayload)) {
        $gridName = [string] $dir.name
        if ($gridName.Equals($DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
            return $gridName
        }
    }

    return $null
}

function Get-SourceGridDirectoryNameListForDiagnostics {
    param($ListPayload)

    $names = @(
        Get-SourceGridDirectoryItems -ListPayload $ListPayload |
            ForEach-Object { [string] $_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ((Get-CollectionCount $names) -eq 0) {
        return '(none)'
    }
    return ($names -join ', ')
}

function Ensure-SourceUiAtDiskFolder {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceDriveUi,
        [string] $StepLabel
    )

    $expected = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $list -Step "listSourceFiles ($StepLabel)"

    $actualPath = Get-ListPayloadFolderPath -ListPayload $list
    if (-not [string]::IsNullOrWhiteSpace($actualPath)) {
        $actual = [System.IO.Path]::GetFullPath($actualPath)
        if ($actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase) -and $list.folder.isLoaded -ne $false) {
            return $list
        }
        Write-TestStep "$StepLabel source UI folder is '$actual'; re-sync to '$expected'"
    }
    else {
        Write-TestStep "$StepLabel source UI folder unknown; navigate to '$expected'"
    }

    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $SourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "selectSource ($StepLabel sync)"

    $segments = Get-FolderSegmentsFromDrive -FolderPath $expected
    Invoke-NavigateSourceSegments -Exe $Exe -Segments $segments -StepPrefix "Source sync ($StepLabel)"

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed during source sync ($StepLabel): exit $($ready.ExitCode) $($ready.StdOut)"
    }

    $listAfter = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listAfter -Step "listSourceFiles after sync ($StepLabel)"
    Assert-ListFolderPathMatches -ListPayload $listAfter -ExpectedDiskPath $expected -StepLabel "Source sync ($StepLabel)"
    return $listAfter
}

function Invoke-OpenSourceSubfolderFromGrid {
    param(
        [string] $Exe,
        [string] $ParentDiskPath,
        [string] $SubfolderName,
        [string] $TargetDiskPath,
        [string] $SourceDriveUi,
        [string] $StepLabel
    )

    $parentPath = [System.IO.Path]::GetFullPath($ParentDiskPath)
    $targetPath = [System.IO.Path]::GetFullPath($TargetDiskPath)

    $list = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $parentPath -SourceDriveUi $SourceDriveUi -StepLabel $StepLabel
    $gridName = Find-SourceGridDirectoryDisplayName -ListPayload $list -DirectoryName $SubfolderName
    if ([string]::IsNullOrWhiteSpace($gridName)) {
        $visible = Get-SourceGridDirectoryNameListForDiagnostics -ListPayload $list
        throw "Source grid at '$parentPath' has no subdirectory '$SubfolderName' (disk path '$targetPath'). Visible directories: $visible"
    }

    Write-TestStep "$StepLabel openFolder source -> '$gridName' (under '$parentPath')"
    $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $gridName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $open -Step "openFolder source ($gridName)"

    $listAfter = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listAfter -Step "listSourceFiles after openFolder ($gridName)"
    Assert-ListFolderPathMatches -ListPayload $listAfter -ExpectedDiskPath $targetPath -StepLabel "openFolder source ($gridName)"
}

function Select-SourceFilesRecursive {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceRootPath,
        [string] $SourceDriveUi,
        [ref] $SelectedCount,
        [ref] $FoldersUsed,
        [hashtable] $SelectedNames,
        [hashtable] $EligiblePathSet,
        [int] $MaxFolderDepth = 5,
        [int] $MaxJobFiles = 10,
        [int] $CurrentDepth = 0,
        [switch] $Sa04BlockedFixtureRoot
    )

    if ($MaxJobFiles -gt 0 -and $SelectedCount.Value -ge $MaxJobFiles) {
        return
    }

    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $null = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $diskFolderPath -SourceDriveUi $SourceDriveUi `
        -StepLabel "before selection at '$diskFolderPath'"
    $childFiles = @(Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop | Sort-Object Name)
    $childDirs = @(Get-ChildItem -LiteralPath $diskFolderPath -Directory -Force -ErrorAction Stop | Sort-Object Name)

    foreach ($file in $childFiles) {
        if ($MaxJobFiles -gt 0 -and $SelectedCount.Value -ge $MaxJobFiles) {
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

        $key = $file.FullName.ToUpperInvariant()
        if ($SelectedNames.ContainsKey($key)) {
            throw "Double-selection detected for file: $($file.FullName)"
        }
        $SelectedNames[$key] = $true
        $SelectedCount.Value++
    }

    if ($CurrentDepth -ge $MaxFolderDepth) {
        return
    }

    foreach ($dir in $childDirs) {
        if ($MaxJobFiles -gt 0 -and $SelectedCount.Value -ge $MaxJobFiles) {
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
        if (-not $Sa04BlockedFixtureRoot -and -not (Test-Sa02IsKnownAllowedFixtureSubfolder -FolderName $dir.Name)) {
            Write-TestStep "Skip unsupported Allowed fixture subfolder '$($dir.Name)' under '$diskFolderPath'"
            continue
        }
        if (Test-Sa02IsCombinedCdrFixtureSubfolder -FolderName $dir.Name) {
            Select-Sa02FilesFromCombinedCdrDiskFolder -Exe $Exe -CombinedDiskFolderPath $dir.FullName `
                -ParentDiskFolderPath $diskFolderPath -SourceRootPath $SourceRootPath -SourceDriveUi $SourceDriveUi `
                -SelectedCount $SelectedCount -FoldersUsed $FoldersUsed -SelectedNames $SelectedNames `
                -EligiblePathSet $EligiblePathSet -MaxJobFiles $MaxJobFiles
            continue
        }
        $FoldersUsed.Value = $true
        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        Invoke-OpenSourceSubfolderFromGrid -Exe $Exe -ParentDiskPath $diskFolderPath -SubfolderName $dir.Name `
            -TargetDiskPath $dir.FullName -SourceDriveUi $SourceDriveUi -StepLabel "enter '$($dir.Name)'"

        Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $dir.FullName -SourceRootPath $SourceRootPath `
            -SourceDriveUi $SourceDriveUi -SelectedCount $SelectedCount -FoldersUsed $FoldersUsed -SelectedNames $SelectedNames `
            -EligiblePathSet $EligiblePathSet -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $MaxJobFiles `
            -CurrentDepth ($CurrentDepth + 1) -Sa04BlockedFixtureRoot:$Sa04BlockedFixtureRoot

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
        $null = Ensure-SourceUiAtDiskFolder -Exe $Exe -DiskFolderPath $diskFolderPath -SourceDriveUi $SourceDriveUi `
            -StepLabel "after folderUp from '$($dir.Name)'"
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-02'

    if ($MinJobFiles -lt 1) {
        throw 'SA-02 requires -MinJobFiles >= 1.'
    }

    Write-TestStep "Resolve source folder SA-TestFiles\$($script:Sa02DefaultSourceSubfolder) on C:\"
    $sourcePath = Resolve-Sa02SourceFolderPath -SourceFolderOverride $SourceFolder -TestFilesRoot $TestFilesRoot
    if (-not (Test-DirectoryExists -Path $sourcePath)) {
        throw "Source path does not exist on disk (will not auto-create): $sourcePath"
    }

    Write-TestStep "Discover every eligible file under '$sourcePath' and all subfolders (no job file cap)"
    $onDiskFiles = Get-Sa02AllEligibleFilesUnderAllowed -AllowedRootPath $sourcePath -MaxFolderDepth $MaxFolderDepth
    $expectedFileCount = Get-CollectionCount $onDiskFiles
    if ($expectedFileCount -lt $MinJobFiles) {
        throw "SA-02 needs at least $MinJobFiles eligible file(s) under '$sourcePath'; discovered $expectedFileCount."
    }

    Assert-Sa02FixtureCoverageEligibleFiles -SourceRootPath $sourcePath -OnDiskSourceFiles $onDiskFiles

    $eligiblePathSet = @{}
    foreach ($f in $onDiskFiles) {
        $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
    }

    Write-TestStep 'Create destination folder under C:\test'
    $destinationPath = New-ScanAgentE2eTestDestinationFolder
    if (-not (Test-DirectoryExists -Path $destinationPath)) {
        throw "Destination path does not exist on disk: $destinationPath"
    }

    Write-TestStep "Source root: '$sourcePath' ($expectedFileCount file(s) in job; all eligible under Allowed; max depth $MaxFolderDepth)"
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
        throw 'Scan Agent header is not connected; connect to gateway before running SA-02.'
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

    Write-TestStep 'Return to source panel at Allowed root for multi-file selection'
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step 'selectSource (before selection)'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceNavSegments -StepPrefix 'Source (selection)'

    Write-TestStep 'waitReady before Allowed file selection'
    $readyBeforeSelect = Invoke-ScanAgentDebug -Exe $exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($readyBeforeSelect.ExitCode -ne 0) {
        throw "waitReady failed before file selection: exit $($readyBeforeSelect.ExitCode) $($readyBeforeSelect.StdOut)"
    }
    $null = Ensure-SourceUiAtDiskFolder -Exe $exe -DiskFolderPath $sourcePath -SourceDriveUi $sourceDriveUi `
        -StepLabel 'Allowed root before selection'

    Write-TestStep 'clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    $uiSelectedCount = 0
    $foldersUsed = $false
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount
    $foldersUsedRef = [ref] $foldersUsed

    Write-TestStep "Recursive UI selection of all $expectedFileCount file(s) under Allowed (every subfolder)"
    Select-SourceFilesRecursive -Exe $exe -DiskFolderPath $sourcePath -SourceRootPath $sourcePath -SourceDriveUi $sourceDriveUi `
        -SelectedCount $selectedCountRef -FoldersUsed $foldersUsedRef -SelectedNames $selectedNames -EligiblePathSet $eligiblePathSet `
        -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $script:Sa02SelectAllFilesSentinel

    if ($uiSelectedCount -ne $expectedFileCount) {
        throw "UI selection count ($uiSelectedCount) does not match on-disk job file count ($expectedFileCount)."
    }

    $mainBeforeStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainBeforeStart -Step 'ui.mainContent before startSanitization'
    if ($mainBeforeStart.mainContent.canStartSanitization -ne $true) {
        throw 'Start sanitization is not enabled (canStartSanitization is false).'
    }

    Write-TestStep "Starting sanitization ($uiSelectedCount file(s) selected; expect pass/reconstructed/modified outcomes)"
    $start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization'

    Write-TestStep "Poll sanitization.status up to $SanitizePollSec seconds"
    $deadline = [datetime]::UtcNow.AddSeconds($SanitizePollSec)
    $finalStatus = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
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

    $mainAfterJob = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainAfterJob -Step 'ui.mainContent after sanitization'

    Assert-Sa02HappyPathSanitizationOutcomes -FinalStatus $finalStatus -OnDiskSourceFiles $onDiskFiles `
        -SourceRootPath $sourcePath -MainContentPayload $mainAfterJob

    $passedCount = [int]$finalStatus.counts.passed
    Assert-DestinationTreeHasSanitizedFiles -DestinationRootPath $destinationPath -ExpectedPassedCount $passedCount

    Assert-Sa04DestinationNamesAndOutcomes -Exe $exe -DestDriveUi $destDriveUi -DestSegments $destSegments `
        -DestinationRoot $destinationPath -SourceRootPath $sourcePath -MaxFolderDepth $MaxFolderDepth `
        -FinalStatus $finalStatus -OnDiskSourceFiles $onDiskFiles

    Assert-Sa02PassedFilesOnDiskUnderDestinationTree -FinalStatus $finalStatus -DestinationRoot $destinationPath `
        -SourceRootPath $sourcePath -OnDiskSourceFiles $onDiskFiles

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
        -TestId 'SA-02' -TestTitle 'Local sanitize pass reconstructed modified' -Passed:$script:ScenarioPassed `
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
