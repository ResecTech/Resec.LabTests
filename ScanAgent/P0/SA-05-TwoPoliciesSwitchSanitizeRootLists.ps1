#Requires -Version 5.1
<#
.SYNOPSIS
  SA-05: Two policies — switch, sanitize, root lists.

.DESCRIPTION
  Verifies policy A and B can be selected without UI freeze, source/destination root lists have no
  duplicates and match the active policy after round-trip switching, one sanitization job completes
  per policy (random 5–10 files per job), and after each policy switch the source panel resets to the
  first drive/root in listSources dropdown order with a fresh grid (not the prior deep folder/selections)
  before the next job navigates source then destination.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - Core REST debug hooks enabled (EnableDebugInterface) for default policy lab setup.
    - WebMC export XML with a Scan Agent template policy (optional -PolicyTemplateXml; default is embedded lab policy in ScanAgentE2eEmbeddedPolicyBase.ps1).
    - Folder named SA-TestFiles on drive C:\ with eligible test files (optional -TestFilesRoot / -SourceFolder).

  Default Core setup (unless -SkipCorePolicySetup): GET pushpolicystate (snapshot DB policies + rules),
  POST importpolicies (policies Test5-a and Test5-b with SMB Source + SMB Destination sharing the same store
  display names but mapped to different lab folders on disk + scan_agent rule),
  GET commdown (disconnect all agents, 5s hold), GET commup, then GET poppolicystate in finally.
  See Core docs/core-debug-api.md.

.NOTES
  Test plan: SA-05 — Switch A<->B without freeze; each policy's source/dest roots differ correctly;
  sanitize once per policy; no duplicate roots. (See C:\Resec\Testing\SA-minimal-functional-testplan.htm)
  Exit 0 = passed; C:\test destination folder removed on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceFolder = '',
    [string] $TestFilesRoot = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyBaseRaw = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $CorePolicyNameA = 'Test5-a',
    [string] $CorePolicyNameB = 'Test5-b',
    [int] $PolicyIdA = 0,
    [int] $PolicyIdB = 0,
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $MaxFolderDepth = 5,
    [int] $MinJobFiles = 5,
    [int] $MaxJobFiles = 10
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

# Resolve policies by name for scenario steps (default Test5-a / Test5-b; overridable via -CorePolicyNameA/B).
$script:Sa05ResolvePolicyNameA = $CorePolicyNameA
$script:Sa05ResolvePolicyNameB = $CorePolicyNameB

$destinationPath = $null
$script:TestFileMaxBytes = 5MB
$script:TestBlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.msp', '.hta', '.jar', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.ps1xml',
    '.vbs', '.vbe', '.js', '.jse', '.ws', '.wsf', '.wsh', '.sh', '.py', '.pyw', '.pl', '.rb', '.php', '.reg', '.inf', '.lnk', '.url'
)
$script:TestBlockedDirectoryNames = @(
    '.git', '.svn', '.hg', '.vs', '.idea', 'node_modules', 'bin', 'obj', '__pycache__', 'packages', 'dist', 'build', 'out', 'target'
)

$destinationPath = $null
$script:OriginalPolicyId = $null
$script:Sa05CorePolicyStackPushed = $false
$script:Sa05CoreDebugHookUrl = $null
$script:Sa05SmbLabMode = $false
# Must match ScanAgentE2eCorePolicy.ps1 New-Sa05CorePolicyImportBody defaults.
$script:Sa05SmbLabSourceA = 'c:\temp\SA-05-in-a'
$script:Sa05SmbLabDestA = 'c:\test\SA-05-out-a'
$script:Sa05SmbLabSourceB = 'c:\test\SA-05-in-b'
$script:Sa05SmbLabDestB = 'c:\temp\SA-05-out-b'
# Same SMB store display names in both policies (different Core folder mapping per policy).
$script:Sa05SmbStoreSource = 'sa05-smb-in'
$script:Sa05SmbStoreDest = 'sa05-smb-out'

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


function Test-EligibleTestFile {
    param([System.IO.FileInfo] $File)
    if ($File.Length -gt $script:TestFileMaxBytes) { return $false }
    if ($script:TestBlockedExtensions -contains $File.Extension.ToLowerInvariant()) { return $false }
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

function Get-EligibleFilesUnderFolder {
    param(
        [string] $RootFolder,
        [int] $MaxFolderDepth = 5
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
                if (-not (Test-EligibleTestFile -File $file)) {
                    continue
                }
                if ((Get-RelativeFolderDepthFromRoot -RootFolder $root -FileFullPath $file.FullName) -gt $MaxFolderDepth) {
                    continue
                }
                if (Test-IsBlockedFixturePath -Path $file.FullName) {
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

function Get-RandomJobFileCount {
    param(
        [int] $MinCount,
        [int] $MaxCount
    )

    if ($MinCount -gt $MaxCount) {
        throw "MinCount ($MinCount) cannot exceed MaxCount ($MaxCount)."
    }
    if ($MinCount -eq $MaxCount) {
        return $MinCount
    }

    return (Get-Random -Minimum $MinCount -Maximum ($MaxCount + 1))
}

function Select-RandomJobFilesFromPool {
    param(
        [System.IO.FileInfo[]] $Pool,
        [int] $Count
    )

    $all = ConvertTo-FileInfoArray $Pool
    $available = Get-CollectionCount $all
    if ($Count -gt $available) {
        throw "Requested $Count job file(s) but only $available eligible file(s) in pool."
    }
    if ($Count -lt 1) {
        throw "Job file count must be at least 1; got $Count."
    }

    $shuffled = @($all | Sort-Object { Get-Random })
    $picked = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $seenNames = @{}
    foreach ($candidate in $shuffled) {
        $leafName = $candidate.Name
        if ([string]::IsNullOrWhiteSpace($leafName) -or $seenNames.ContainsKey($leafName)) {
            continue
        }

        $seenNames[$leafName] = $true
        $picked.Add($candidate)
        if ($picked.Count -ge $Count) {
            break
        }
    }

    if ($picked.Count -lt $Count) {
        throw "Requested $Count job file(s) with unique names but pool only has $($picked.Count) distinct name(s)."
    }

    return ConvertTo-FileInfoArray @($picked | Sort-Object FullName)
}

function Select-TestSourceFolder {
    param(
        [string] $Override = '',
        [string] $TestFilesRoot = '',
        [int] $MinEligibleFiles = 1,
        [int] $MaxFolderDepth = 5,
        [int] $MaxJobFiles = 10
    )

    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRoot
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $sourceRoot = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-DirectoryExists -Path $sourceRoot)) {
            throw "Source folder override does not exist on disk: $sourceRoot"
        }
        $saRootPrefix = $saRoot
        if (-not $saRootPrefix.EndsWith('\')) {
            $saRootPrefix += '\'
        }
        if (-not ($sourceRoot.Equals($saRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $sourceRoot.StartsWith($saRootPrefix, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Source folder '$sourceRoot' must be under SA-TestFiles root '$saRoot'."
        }
    }
    else {
        $sourceRoot = $saRoot
    }

    $files = Limit-JobFileSelection -Files (
        Get-EligibleFilesUnderFolder -RootFolder $sourceRoot -MaxFolderDepth $MaxFolderDepth
    ) -MaxCount $MaxJobFiles

    if ((Get-CollectionCount $files) -lt $MinEligibleFiles) {
        throw "Source '$sourceRoot' has $(Get-CollectionCount $files) eligible file(s) within $MaxFolderDepth level(s); need at least $MinEligibleFiles."
    }

    $fileCount = Get-CollectionCount $files
    if ($MaxJobFiles -le 0) {
        Write-TestStep "Fixture root: '$saRoot'; source folder: '$sourceRoot' ($fileCount eligible file(s) in pool)"
    }
    else {
        Write-TestStep "Fixture root: '$saRoot'; source folder: '$sourceRoot' ($fileCount file(s) for job)"
    }

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

    $stdoutText = $result.StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($stdoutText)) {
        throw "ScanAgentDebug returned no JSON: $commandLine"
    }

    try {
        return ($stdoutText | ConvertFrom-Json)
    }
    catch {
        $jsonLine = $null
        foreach ($line in ($stdoutText -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
                $jsonLine = $trimmed
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($jsonLine)) {
            throw "ScanAgentDebug returned no JSON: $commandLine`n$stdoutText"
        }

        try {
            return $jsonLine | ConvertFrom-Json
        }
        catch {
            throw "ScanAgentDebug output was not JSON: $commandLine`n$stdoutText"
        }
    }
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

function Assert-PanelRootsLoaded {
    param(
        $ListPayload,
        [string] $PanelLabel
    )

    $rootCount = Get-CollectionCount $ListPayload.roots
    if ($rootCount -lt 1) {
        throw "Empty $PanelLabel roots for active policy."
    }

    $accessible = @($ListPayload.roots | Where-Object { $_.isAccessible -eq $true })
    if ((Get-CollectionCount $accessible) -lt 1) {
        throw "No accessible $PanelLabel roots for active policy."
    }

    Write-TestStep "$PanelLabel roots: $rootCount total, $(Get-CollectionCount $accessible) accessible"
}

function Assert-NoDuplicatePanelRoots {
    param(
        $ListPayload,
        [string] $PanelLabel
    )

    $names = @($ListPayload.roots | ForEach-Object { [string] $_.name })
    $groups = $names | Group-Object
    foreach ($group in $groups) {
        if ($group.Count -gt 1) {
            throw "$PanelLabel roots contain duplicate name '$($group.Name)' ($($group.Count) entries)."
        }
    }
}

function Get-PanelRootSignature {
    param($ListPayload)

    $parts = @($ListPayload.roots | ForEach-Object {
            $name = [string] $_.name
            $acc = if ($_.isAccessible -eq $true) { '1' } else { '0' }
            "$name|$acc"
        } | Sort-Object)
    return ($parts -join ';')
}

function Assert-RootListIncludesDrive {
    param(
        $ListPayload,
        [string] $DriveUiName,
        [string] $PanelLabel
    )

    $names = @($ListPayload.roots | ForEach-Object { [string] $_.name })
    if ($names -notcontains $DriveUiName) {
        throw "$PanelLabel roots do not include root '$DriveUiName' required for test paths."
    }
}

function Wait-ScanAgentSourceRootVisible {
    param(
        [string] $Exe,
        [string] $RootName,
        [int] $TimeoutSec = 60
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $lastRoots = @()
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $listSources = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSources')
        Assert-OkResponse -Response $listSources -Step "listSources (wait for source root '$RootName')"
        $lastRoots = @($listSources.roots | ForEach-Object { [string] $_.name })
        if ($lastRoots -contains $RootName) {
            return $listSources
        }
        Start-Sleep -Milliseconds 500
    }

    $listed = if ($lastRoots.Count -gt 0) { $lastRoots -join ', ' } else { '(none)' }
    throw "Timed out after ${TimeoutSec}s waiting for source root '$RootName'. Last roots: $listed"
}

function Assert-ListFolderPathMatches {
    param(
        $ListPayload,
        [string] $ExpectedDiskPath,
        [string] $StepLabel
    )

    $folderPath = $null
    if ($ListPayload.folder -and $ListPayload.folder.path) {
        $folderPath = [string] $ListPayload.folder.path
    }
    if ([string]::IsNullOrWhiteSpace($folderPath)) {
        throw "$StepLabel did not return folder.path in list response."
    }

    $expected = [System.IO.Path]::GetFullPath($ExpectedDiskPath)
    $actual = [System.IO.Path]::GetFullPath($folderPath)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$StepLabel folder.path mismatch: expected '$expected', got '$actual'."
    }

    if ($ListPayload.folder.isLoaded -eq $false) {
        throw "$StepLabel folder is not loaded at '$actual'."
    }

    Write-TestStep "$StepLabel folder loaded at '$actual' (grid items: $($ListPayload.itemCount))"
}

function Get-SourceGridSnapshot {
    param(
        [string] $Exe,
        [string] $Label
    )

    $raw = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $raw -Step "listSourceFiles ($Label)"

    $folderPath = ''
    $rootLocation = ''
    $isLoaded = $false
    if ($null -ne $raw.folder) {
        if ($raw.folder.path) {
            $folderPath = [string] $raw.folder.path
        }
        if ($raw.folder.rootLocation) {
            $rootLocation = [string] $raw.folder.rootLocation
        }
        if ($raw.folder.isLoaded -eq $true) {
            $isLoaded = $true
        }
    }

    $items = @($raw.items)
    $visibleNames = @(
        $items |
            Where-Object { $_.isVisible -ne $false } |
            ForEach-Object { [string] $_.name } |
            Sort-Object
    )
    $selectedNames = @(
        $items |
            Where-Object {
                $null -ne $_.selection -and [string]$_.selection -ne '' -and [string]$_.selection -ne 'None'
            } |
            ForEach-Object { [string] $_.name }
    )
    $signatureParts = @(
        $items |
            Where-Object { $_.isVisible -ne $false } |
            ForEach-Object {
                $sel = 'None'
                if ($null -ne $_.selection -and [string]$_.selection -ne '') {
                    $sel = [string] $_.selection
                }
                return ("{0}|{1}|{2}" -f [string]$_.name, [string]$_.type, $sel)
            } |
            Sort-Object
    )

    return [pscustomobject]@{
        Raw               = $raw
        FolderPath        = $folderPath
        RootLocation      = $rootLocation
        IsLoaded          = $isLoaded
        ItemCount         = Get-CollectionCount $visibleNames
        ItemNames         = $visibleNames
        SelectedItemNames = $selectedNames
        ItemSignature     = ($signatureParts -join ';')
    }
}

function Get-OnDiskFolderChildNamesForGridCompare {
    param([string] $FolderPath)

    $full = [System.IO.Path]::GetFullPath($FolderPath)
    if (-not (Test-DirectoryExists -Path $full)) {
        throw "On-disk folder does not exist for grid compare: $full"
    }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($child in @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($child.PSIsContainer) {
            if (Test-IsBlockedFixturePathSegment -SegmentName $child.Name) {
                continue
            }
        }
        if ($child.Name.StartsWith('.', [StringComparison]::Ordinal)) {
            continue
        }
        $names.Add($child.Name)
    }

    return [string[]]$names.ToArray()
}

function Assert-SourceGridNoResidualSelection {
    param(
        $Snapshot,
        [string] $Label
    )

    $selected = @($Snapshot.SelectedItemNames)
    if ((Get-CollectionCount $selected) -gt 0) {
        $listed = ($selected | ForEach-Object { "'$_'" }) -join ', '
        throw "Source grid still has selected item(s) after policy switch ($Label): $listed"
    }
}

function Invoke-NavigateSourceToDiskPath {
    param(
        [string] $Exe,
        [string] $SourcePath,
        [string] $Label
    )

    $sourceDriveUi = Get-DriveRootUiName -FolderPath $SourcePath
    $sourceSegments = Get-FolderSegmentsFromDrive -FolderPath $SourcePath

    Write-TestStep "selectSource root '$sourceDriveUi' ($Label)"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "selectSource ($Label)"

    Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix "Source ($Label)"
}

function Assert-SourceGridMatchesOnDiskChildren {
    param(
        $Snapshot,
        [string] $FolderPath,
        [string] $Label
    )

    $diskNames = @(Get-OnDiskFolderChildNamesForGridCompare -FolderPath $FolderPath)
    $gridNames = @($Snapshot.ItemNames)
    $diskCount = Get-CollectionCount $diskNames
    $gridCount = Get-CollectionCount $gridNames

    if ($diskCount -ne $gridCount) {
        throw "Source grid item count ($gridCount) does not match on-disk children ($diskCount) ($Label)."
    }

    for ($i = 0; $i -lt $diskCount; $i++) {
        if (-not $diskNames[$i].Equals($gridNames[$i], [StringComparison]::OrdinalIgnoreCase)) {
            throw "Source grid item mismatch at index $i ($Label): on-disk='$($diskNames[$i])' grid='$($gridNames[$i])'."
        }
    }
}

function Get-FirstSourceDropdownRootName {
    param($ListSourcesPayload)

    $roots = @($ListSourcesPayload.roots)
    if ((Get-CollectionCount $roots) -lt 1) {
        throw 'listSources returned no roots for the active policy.'
    }

    foreach ($root in $roots) {
        $name = [string] $root.name
        if ($name -match '^[A-Za-z]:$') {
            return $name
        }
    }

    return [string] $roots[0].name
}

function Get-SelectedSourceRootName {
    param($ListSourcesPayload)

    $selected = @($ListSourcesPayload.roots | Where-Object { $_.isSelected -eq $true })
    if ((Get-CollectionCount $selected) -ne 1) {
        $count = Get-CollectionCount $selected
        throw "Expected exactly one selected source root after policy switch; found $count."
    }

    return [string] $selected[0].name
}

function Test-IsLocalFilesystemFolderPath {
    param([string] $FolderPath)

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        return $false
    }

    return Test-DirectoryExists -Path $FolderPath
}

function Get-Sa05SmbGridItemNamesOnlyOnPriorLabSource {
    param(
        [Parameter(Mandatory)]
        [string] $PriorLabSourceFolder,
        [Parameter(Mandatory)]
        [string] $ActiveLabSourceFolder
    )

    $priorNames = @{}
    Get-ChildItem -LiteralPath $PriorLabSourceFolder -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -notlike '*-lab-folder.txt' } |
        ForEach-Object { $priorNames[$_.Name] = $true }

    Get-ChildItem -LiteralPath $ActiveLabSourceFolder -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -notlike '*-lab-folder.txt' } |
        ForEach-Object {
            if ($priorNames.ContainsKey($_.Name)) {
                $priorNames.Remove($_.Name)
            }
        }

    return @($priorNames.Keys | Sort-Object)
}

function Assert-SourceGridForbiddenItemNames {
    param(
        $Snapshot,
        [string[]] $ForbiddenItemNames,
        [string] $Label
    )

    if ($null -eq $ForbiddenItemNames -or (Get-CollectionCount $ForbiddenItemNames) -lt 1) {
        return
    }

    $gridNames = @($Snapshot.ItemNames)
    foreach ($forbidden in $ForbiddenItemNames) {
        if ([string]::IsNullOrWhiteSpace($forbidden)) {
            continue
        }
        $match = @($gridNames | Where-Object { $_.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase) })
        if ((Get-CollectionCount $match) -gt 0) {
            throw "Source grid still lists '$forbidden' from the prior policy's SMB folder after switch ($Label)."
        }
    }
}

function Assert-SourceGridAtFirstDropdownRootAfterPolicySwitch {
    param(
        [string] $Exe,
        [string] $PriorJobSourcePath,
        $PriorSnapshot,
        [int] $ExpectedPolicyId,
        [string] $Label,
        [string] $ExpectedSmbLabSourcePath = '',
        [string[]] $ForbiddenGridItemNames = @()
    )

    Write-TestStep "Assert source reset to first dropdown root after policy switch ($Label)"
    Assert-PolicyAndHeaderAligned -Exe $Exe -ExpectedPolicyId $ExpectedPolicyId -StepLabel "source reset ($Label)"

    $listSources = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSources')
    Assert-OkResponse -Response $listSources -Step "listSources ($Label)"

    $firstRoot = Get-FirstSourceDropdownRootName -ListSourcesPayload $listSources
    $selectedRoot = Get-SelectedSourceRootName -ListSourcesPayload $listSources
    $selectedRootLocation = [string] $listSources.selectedRootLocation

    if (-not $selectedRoot.Equals($firstRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "After policy switch ($Label), selected source root is '$selectedRoot' but first dropdown root is '$firstRoot'."
    }
    if (-not [string]::IsNullOrWhiteSpace($selectedRootLocation) -and
        -not $selectedRootLocation.Equals($firstRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "After policy switch ($Label), listSources.selectedRootLocation '$selectedRootLocation' does not match first dropdown root '$firstRoot'."
    }

    $grid = Get-SourceGridSnapshot -Exe $Exe -Label "first root grid $Label"
    Assert-SourceGridNoResidualSelection -Snapshot $grid -Label $Label

    if (-not $grid.IsLoaded) {
        throw "Source grid for first dropdown root '$firstRoot' is not loaded after policy switch ($Label)."
    }
    if (-not $grid.RootLocation.Equals($firstRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "listSourceFiles.rootLocation '$($grid.RootLocation)' does not match first dropdown root '$firstRoot' ($Label)."
    }

    $priorJobFolder = [System.IO.Path]::GetFullPath($PriorJobSourcePath)
    if (-not [string]::IsNullOrWhiteSpace($grid.FolderPath)) {
        $currentFolder = [System.IO.Path]::GetFullPath($grid.FolderPath)
        if ($currentFolder.Equals($priorJobFolder, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Source grid still shows prior job folder '$currentFolder' after policy switch ($Label); expected first root '$firstRoot' view."
        }
    }

    if ($null -ne $PriorSnapshot) {
        if (-not [string]::IsNullOrWhiteSpace($PriorSnapshot.FolderPath) -and
            -not [string]::IsNullOrWhiteSpace($grid.FolderPath)) {
            $priorFolder = [System.IO.Path]::GetFullPath($PriorSnapshot.FolderPath)
            $currentFolder = [System.IO.Path]::GetFullPath($grid.FolderPath)
            if ($currentFolder.Equals($priorFolder, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Source grid folder.path unchanged from prior policy at '$priorFolder' ($Label)."
            }
        }

        $priorSelected = Get-CollectionCount $PriorSnapshot.SelectedItemNames
        if ($priorSelected -gt 0 -and $grid.ItemSignature -eq $PriorSnapshot.ItemSignature) {
            throw "Source grid item list unchanged from prior policy (same names/types/selection) after switch ($Label)."
        }
    }

    if (Test-IsLocalFilesystemFolderPath -FolderPath $grid.FolderPath) {
        Assert-SourceGridMatchesOnDiskChildren -Snapshot $grid -FolderPath $grid.FolderPath -Label "first root local grid $Label"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSmbLabSourcePath)) {
        Write-TestStep "Assert SMB source grid matches active policy lab folder after switch ($Label)"
        Assert-SourceGridForbiddenItemNames -Snapshot $grid -ForbiddenItemNames $ForbiddenGridItemNames -Label $Label
        Assert-SourceGridMatchesOnDiskChildren -Snapshot $grid -FolderPath $ExpectedSmbLabSourcePath `
            -Label "SMB lab source $Label"
    }

    Write-TestStep "Source at first dropdown root '$firstRoot' with $($grid.ItemCount) grid item(s) before next sanitization ($Label)."
}

function Get-PolicyRootSnapshot {
    param(
        [string] $Exe,
        [string] $SourceDriveUi,
        [string] $DestDriveUi,
        [string] $Label
    )

    Write-TestStep "Capture root lists ($Label)"
    $listSources = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSources')
    Assert-OkResponse -Response $listSources -Step "listSources ($Label)"
    $listDestinations = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listDestinations')
    Assert-OkResponse -Response $listDestinations -Step "listDestinations ($Label)"

    Assert-PanelRootsLoaded -ListPayload $listSources -PanelLabel 'Source'
    Assert-PanelRootsLoaded -ListPayload $listDestinations -PanelLabel 'Destination'
    Assert-NoDuplicatePanelRoots -ListPayload $listSources -PanelLabel 'Source'
    Assert-NoDuplicatePanelRoots -ListPayload $listDestinations -PanelLabel 'Destination'
    Assert-RootListIncludesDrive -ListPayload $listSources -DriveUiName $SourceDriveUi -PanelLabel 'Source'
    Assert-RootListIncludesDrive -ListPayload $listDestinations -DriveUiName $DestDriveUi -PanelLabel 'Destination'

    return [pscustomobject]@{
        SourceSignature      = (Get-PanelRootSignature -ListPayload $listSources)
        DestinationSignature = (Get-PanelRootSignature -ListPayload $listDestinations)
        SourceCount          = Get-CollectionCount $listSources.roots
        DestCount            = Get-CollectionCount $listDestinations.roots
    }
}

function Assert-PolicyAndHeaderAligned {
    param(
        [string] $Exe,
        [int] $ExpectedPolicyId,
        [string] $StepLabel
    )

    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step "ui.mainContent ($StepLabel)"
    if ($null -eq $main.header) {
        throw "ui.mainContent.header missing ($StepLabel)."
    }
    if ($main.header.isConnected -ne $true) {
        throw "Header not connected after $StepLabel."
    }

    $policyCurrent = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrent -Step "policy.current ($StepLabel)"
    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step "policy.list ($StepLabel)"

    $currentId = [int]$policyCurrent.policy.id
    if ($currentId -ne $ExpectedPolicyId) {
        throw "policy.current id ($currentId) does not match expected $ExpectedPolicyId ($StepLabel)."
    }
    if ([int]$main.header.currentPolicyId -ne $ExpectedPolicyId) {
        throw "header.currentPolicyId ($($main.header.currentPolicyId)) does not match expected $ExpectedPolicyId ($StepLabel)."
    }
    if ([int]$policyList.currentPolicyId -ne $ExpectedPolicyId) {
        throw "policy.list currentPolicyId ($($policyList.currentPolicyId)) does not match expected $ExpectedPolicyId ($StepLabel)."
    }

    $currentInList = @($policyList.policies | Where-Object { $_.id -eq $ExpectedPolicyId -and $_.isCurrent -eq $true })
    if ((Get-CollectionCount $currentInList) -lt 1) {
        throw "Policy id $ExpectedPolicyId is not marked isCurrent in policy.list ($StepLabel)."
    }

    Write-TestStep "${StepLabel}: active policy id=$currentId name='$($policyCurrent.policy.name)'"
}

function Invoke-SelectPolicyById {
    param(
        [string] $Exe,
        [int] $PolicyId,
        [string] $Label
    )

    Write-TestStep "policy.select --policy-id $PolicyId ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--policy-id', "$PolicyId", '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $select -Step "policy.select ($Label)"

    Write-TestStep "waitReady after policy switch ($Label)"
    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy switch '$Label' (exit $($ready.ExitCode)): $($ready.StdOut)"
    }

    $ping = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step "ping after policy switch ($Label)"
    if ($ping.message -and $ping.message -ne 'pong') {
        throw "Unexpected ping after policy switch ($Label): $($ping.message)"
    }

    Assert-PolicyAndHeaderAligned -Exe $Exe -ExpectedPolicyId $PolicyId -StepLabel $Label
}

function Test-SanitizationQuiescent {
    param($Status)

    if ($null -eq $Status) {
        return $false
    }

    if ([string]$Status.state -eq 'idle') {
        return $true
    }

    if ([string]$Status.state -eq 'complete') {
        $inProgress = $false
        if ($null -ne $Status.PSObject.Properties['inProgress']) {
            $inProgress = [bool]$Status.inProgress
        }
        $finished = $true
        if ($null -ne $Status.PSObject.Properties['sanitizationFinished']) {
            $finished = [bool]$Status.sanitizationFinished
        }
        if (-not $inProgress -and $finished) {
            $running = 0
            if ($Status.counts -and $null -ne $Status.counts.PSObject.Properties['running']) {
                $running = [int]$Status.counts.running
            }
            if ($running -eq 0) {
                return $true
            }
        }
    }

    return $false
}

function Wait-SanitizationIdle {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [string] $Context
    )

    Write-TestStep "Poll sanitization.status until quiescent (idle or finished complete) ($Context), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $lastLoggedState = $null

    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if (Test-SanitizationQuiescent -Status $status) {
            Write-TestStep "sanitization.status quiescent: state=$($status.state) ($Context)"
            return
        }

        $state = [string]$status.state
        if ($state -ne $lastLoggedState) {
            $selected = ''
            $running = ''
            if ($status.counts) {
                $selected = [string]$status.counts.selected
                $running = [string]$status.counts.running
            }
            Write-TestStep "sanitization.status waiting: state=$state selected=$selected running=$running ($Context)"
            $lastLoggedState = $state
        }

        Start-Sleep -Seconds 2
    }

    throw "sanitization.status did not reach a quiescent state within ${TimeoutSec}s ($Context)."
}

function Wait-SanitizationComplete {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [int] $ExpectedSelected
    )

    Write-TestStep "Poll sanitization.status until complete (expected selected=$ExpectedSelected), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $finalStatus = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
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
        throw "Sanitization did not reach complete within $TimeoutSec seconds."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running
    $processed = $passed + $blocked

    Write-TestStep "Final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne $ExpectedSelected) {
        throw "counts.selected ($selected) does not match expected UI selection ($ExpectedSelected)."
    }
    if ($processed -ne $selected) {
        throw "passed+blocked ($processed) does not match counts.selected ($selected)."
    }
    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }
    if (-not $finalStatus.files) {
        throw 'sanitization.status did not include files[] after completion.'
    }
    $outcomeCount = Get-CollectionCount (Get-SanitizationFileEntries -FilesProperty $finalStatus.files)
    if ($outcomeCount -ne $selected) {
        throw "files[] count ($outcomeCount) does not match counts.selected ($selected)."
    }

    return $finalStatus
}

function Select-SourceFilesRecursive {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceRootPath,
        [ref] $SelectedCount,
        [hashtable] $SelectedNames,
        [hashtable] $EligiblePathSet,
        [int] $MaxFolderDepth = 5,
        [int] $MaxJobFiles = 10,
        [int] $CurrentDepth = 0
    )

    if ($SelectedCount.Value -ge $MaxJobFiles) {
        return
    }

    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $childFiles = @(
        Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -notlike '*-lab-folder.txt' } |
            Sort-Object Name
    )
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
        if ($SelectedCount.Value -ge $MaxJobFiles) {
            return
        }
        if (Test-IsBlockedFixturePathSegment -SegmentName $dir.Name) {
            Write-TestStep "Skip blocked/hidden subfolder '$($dir.Name)' under '$diskFolderPath'"
            continue
        }
        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $dir.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source ($($dir.Name))"

        Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $dir.FullName -SourceRootPath $SourceRootPath `
            -SelectedCount $SelectedCount -SelectedNames $SelectedNames -EligiblePathSet $EligiblePathSet `
            -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $MaxJobFiles -CurrentDepth ($CurrentDepth + 1)

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

function Clear-Sa05LabSourceToMarkerOnly {
    param(
        [Parameter(Mandatory)]
        [string] $LabSourceFolder
    )

    if (-not (Test-DirectoryExists -Path $LabSourceFolder)) {
        throw "SMB lab source folder does not exist: $LabSourceFolder"
    }

    foreach ($existing in @(Get-ChildItem -LiteralPath $LabSourceFolder -File -Force -ErrorAction SilentlyContinue)) {
        if ($existing.Name -like '*-lab-folder.txt') {
            continue
        }
        Remove-Item -LiteralPath $existing.FullName -Force
    }
}

function Copy-Sa05JobFilesToLabSource {
    param(
        [Parameter(Mandatory)]
        [string] $LabSourceFolder,
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]] $JobFiles
    )

    if (-not (Test-DirectoryExists -Path $LabSourceFolder)) {
        throw "SMB lab source folder does not exist: $LabSourceFolder"
    }

    Clear-Sa05LabSourceToMarkerOnly -LabSourceFolder $LabSourceFolder

    foreach ($file in $JobFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $LabSourceFolder -Force
    }
}

function Invoke-SanitizationJob {
    param(
        [string] $Exe,
        [string] $SourcePath,
        [System.IO.FileInfo[]] $JobFiles,
        [string] $DestinationPath,
        [string] $PolicyLabel,
        [string] $SourceRootUiName = '',
        [string] $DestRootUiName = ''
    )

    $expectedFileCount = Get-CollectionCount $JobFiles
    $eligiblePathSet = @{}
    foreach ($f in $JobFiles) {
        $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
        $jobCopyPath = [System.IO.Path]::GetFullPath((Join-Path $SourcePath $f.Name))
        $eligiblePathSet[$jobCopyPath.ToUpperInvariant()] = $true
    }

    $sourceDriveUi = if (-not [string]::IsNullOrWhiteSpace($SourceRootUiName)) {
        $SourceRootUiName
    }
    else {
        Get-DriveRootUiName -FolderPath $SourcePath
    }
    $destDriveUi = if (-not [string]::IsNullOrWhiteSpace($DestRootUiName)) {
        $DestRootUiName
    }
    else {
        Get-DriveRootUiName -FolderPath $DestinationPath
    }
    # SMB policy roots map to the lab folder itself — do not walk drive-relative segments (e.g. temp\SA-05-in-a).
    $sourceSegments = if (-not [string]::IsNullOrWhiteSpace($SourceRootUiName)) {
        @()
    }
    else {
        Get-FolderSegmentsFromDrive -FolderPath $SourcePath
    }
    $destSegments = if (-not [string]::IsNullOrWhiteSpace($DestRootUiName)) {
        @()
    }
    else {
        Get-FolderSegmentsFromDrive -FolderPath $DestinationPath
    }

    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context "before job ($PolicyLabel)"

    Write-TestStep "selectSource root '$sourceDriveUi' ($PolicyLabel)"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "selectSource ($PolicyLabel)"
    if ($null -eq $sourceSegments) { $sourceSegments = @() }
    if ((Get-CollectionCount $sourceSegments) -gt 0) {
        Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix "Source ($PolicyLabel)"
    }

    Write-TestStep "selectDestination root '$destDriveUi' ($PolicyLabel)"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "selectDestination ($PolicyLabel)"
    if ($null -eq $destSegments) { $destSegments = @() }
    if ((Get-CollectionCount $destSegments) -gt 0) {
        Invoke-NavigateDestinationSegments -Exe $Exe -Segments $destSegments -StepPrefix "Destination ($PolicyLabel)"
    }

    Write-TestStep "Return to source folder for selection ($PolicyLabel)"
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step "selectSource before selection ($PolicyLabel)"
    if ((Get-CollectionCount $sourceSegments) -gt 0) {
        Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix "Source selection ($PolicyLabel)"
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceRootUiName)) {
        Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "refresh SMB source before selection ($PolicyLabel)"
        $listInUi = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
        Assert-OkResponse -Response $listInUi -Step "listSourceFiles ($PolicyLabel)"
        $uiNames = @{}
        foreach ($item in @($listInUi.items)) {
            if ($null -ne $item.name) {
                $uiNames[[string]$item.name] = $true
            }
        }
        $copiedJobCount = Get-CollectionCount $JobFiles
        $JobFiles = @(
            $JobFiles |
                Where-Object { $uiNames.ContainsKey($_.Name) } |
                Sort-Object Name -Unique
        )
        $expectedFileCount = Get-CollectionCount $JobFiles
        if ($expectedFileCount -lt $MinJobFiles) {
            throw "SMB source UI lists $expectedFileCount of $copiedJobCount copied job file(s); need at least $MinJobFiles visible for $PolicyLabel."
        }
        $eligiblePathSet = @{}
        foreach ($f in $JobFiles) {
            $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
            $jobCopyPath = [System.IO.Path]::GetFullPath((Join-Path $SourcePath $f.Name))
            $eligiblePathSet[$jobCopyPath.ToUpperInvariant()] = $true
        }
        Write-TestStep "SMB source UI lists $expectedFileCount job file(s) for selection ($PolicyLabel)"
    }

    Write-TestStep "clearSelection ($PolicyLabel)"
    $clear = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step "clearSelection ($PolicyLabel)"

    $uiSelectedCount = 0
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount

    Write-TestStep "Recursive UI selection ($PolicyLabel, target=$expectedFileCount file(s))"
    Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $SourcePath -SourceRootPath $SourcePath `
        -SelectedCount $selectedCountRef -SelectedNames $selectedNames -EligiblePathSet $eligiblePathSet `
        -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $expectedFileCount

    if ($uiSelectedCount -ne $expectedFileCount) {
        throw "UI selection count ($uiSelectedCount) does not match on-disk job file count ($expectedFileCount) for $PolicyLabel."
    }

    Write-TestStep "startSanitization ($PolicyLabel, selected=$uiSelectedCount)"
    $start = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step "startSanitization ($PolicyLabel)"

    $finalStatus = Wait-SanitizationComplete -Exe $Exe -TimeoutSec $SanitizePollSec -ExpectedSelected $expectedFileCount
    Write-TestStep "Sanitization job complete for $PolicyLabel (passed=$($finalStatus.counts.passed) blocked=$($finalStatus.counts.blocked))"

    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context "after job ($PolicyLabel)"
}

function Resolve-TwoPolicyIds {
    param(
        [string] $Exe,
        [int] $OverrideA,
        [int] $OverrideB,
        [string] $PolicyNameA,
        [string] $PolicyNameB
    )

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list'

    $pair = Resolve-TwoPolicyIdsFromList -PolicyList $policyList -OverrideA $OverrideA -OverrideB $OverrideB `
        -PolicyNameA $PolicyNameA -PolicyNameB $PolicyNameB

    if ([string]::IsNullOrWhiteSpace($PolicyNameA) -or [string]::IsNullOrWhiteSpace($PolicyNameB)) {
        Write-TestStep "Using policies from list: A=$($pair.PolicyA) B=$($pair.PolicyB)"
    }
    else {
        Write-TestStep "Resolved policies by name ($PolicyNameA / $PolicyNameB): A=$($pair.PolicyA) B=$($pair.PolicyB)"
    }

    return $pair
}

function Assert-RootSnapshotsMatch {
    param(
        $Expected,
        $Actual,
        [string] $PolicyLabel
    )

    if ($Expected.SourceSignature -ne $Actual.SourceSignature) {
        throw "Source root signature changed for $PolicyLabel. Was '$($Expected.SourceSignature)', now '$($Actual.SourceSignature)'."
    }
    if ($Expected.DestinationSignature -ne $Actual.DestinationSignature) {
        throw "Destination root signature changed for $PolicyLabel. Was '$($Expected.DestinationSignature)', now '$($Actual.DestinationSignature)'."
    }

    Write-TestStep "Root signatures stable for $PolicyLabel (source roots=$($Actual.SourceCount), dest roots=$($Actual.DestCount))"
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-05'

    if ($MinJobFiles -lt 1) {
        throw '-MinJobFiles must be at least 1.'
    }
    if ($MaxJobFiles -lt $MinJobFiles) {
        throw "-MaxJobFiles ($MaxJobFiles) must be >= -MinJobFiles ($MinJobFiles)."
    }

    Write-TestStep 'Resolve on-disk source path under SA-TestFiles'
    $sourcePick = Select-TestSourceFolder -Override $SourceFolder -TestFilesRoot $TestFilesRoot -MinEligibleFiles $MaxJobFiles `
        -MaxFolderDepth $MaxFolderDepth -MaxJobFiles 0
    $sourcePath = $sourcePick.Path
    if (-not (Test-DirectoryExists -Path $sourcePath)) {
        throw "Source path does not exist on disk: $sourcePath"
    }

    $eligiblePool = ConvertTo-FileInfoArray $sourcePick.EligibleFiles

    Write-TestStep 'Create destination folder under C:\test'
    $destinationPath = New-ScanAgentE2eTestDestinationFolder
    if (-not (Test-DirectoryExists -Path $destinationPath)) {
        throw "Destination path does not exist on disk: $destinationPath"
    }

    Write-TestStep "Source (on disk): '$sourcePath' ($(Get-CollectionCount $eligiblePool) eligible file(s); each job picks $MinJobFiles-$MaxJobFiles at random)"
    Write-TestStep "Destination (on disk): '$destinationPath'"

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

    Write-TestStep 'gateway.status (poll Core connect; UI idle not required)'
    $gateway = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 120 -Context 'before SA-05 scenario' -NudgeReconnect
    Assert-OkResponse -Response $gateway -Step 'gateway.status'

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: pushpolicystate (snapshot current policies and assignment rules)'
        $corePush = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
        $script:Sa05CorePolicyStackPushed = $true
        $script:Sa05CoreDebugHookUrl = $corePush.HookUrl
        $depth = if ($corePush.PushResponse.PSObject.Properties.Name -contains 'policyStateStackDepth') {
            $corePush.PushResponse.policyStateStackDepth
        } else { '?' }
        Write-TestStep "Core pushpolicystate OK (policyStateStackDepth=$depth)"

        Write-TestStep "Core: importpolicies ($CorePolicyNameA, $CorePolicyNameB + scan_agent rule); then commdown 5s commup (disconnect all agents)"
        $coreImport = Import-ScanAgentSa05CoreDebugPolicies -HookUrl $script:Sa05CoreDebugHookUrl -Exe $exe `
            -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
            -PolicyNameA $CorePolicyNameA -PolicyNameB $CorePolicyNameB -UiWaitMs $UiWaitMs
        $importedCount = if ($coreImport.ImportResponse.PSObject.Properties.Name -contains 'importedPolicyCount') {
            $coreImport.ImportResponse.importedPolicyCount
        } else { '?' }
        Write-TestStep "Core importpolicies OK (policyBase='$($coreImport.PolicyBaseSource)', imported $importedCount policies; agent policy.list count=$($coreImport.AgentPolicyList.count))"
        $script:Sa05SmbLabMode = $true
        $destinationPath = $script:Sa05SmbLabDestA
        Write-TestStep "SMB lab mode: jobs use policy A/B SMB in/out folders on disk (see ScanAgentE2eCorePolicy.ps1)"
    }

    $policyCurrentStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrentStart -Step 'policy.current (initial)'
    $script:OriginalPolicyId = [int]$policyCurrentStart.policy.id

    $policyPair = Resolve-TwoPolicyIds -Exe $exe -OverrideA $PolicyIdA -OverrideB $PolicyIdB `
        -PolicyNameA $script:Sa05ResolvePolicyNameA -PolicyNameB $script:Sa05ResolvePolicyNameB
    $idA = $policyPair.PolicyA
    $idB = $policyPair.PolicyB

    if ($script:Sa05SmbLabMode) {
        Write-TestStep 'SMB lab: round-trip policy select after Core import (refresh locations when policy ids are reused)'
        Invoke-SelectPolicyById -Exe $exe -PolicyId $idB -Label 'post-import refresh (B)'
        Invoke-SelectPolicyById -Exe $exe -PolicyId $idA -Label 'post-import refresh (A)'
        $null = Wait-ScanAgentSourceRootVisible -Exe $exe -RootName $script:Sa05SmbStoreSource

        $labA = [pscustomobject]@{
            SourcePath = $script:Sa05SmbLabSourceA
            DestPath   = $script:Sa05SmbLabDestA
            SourceRoot = $script:Sa05SmbStoreSource
            DestRoot   = $script:Sa05SmbStoreDest
        }
        $labB = [pscustomobject]@{
            SourcePath = $script:Sa05SmbLabSourceB
            DestPath   = $script:Sa05SmbLabDestB
            SourceRoot = $script:Sa05SmbStoreSource
            DestRoot   = $script:Sa05SmbStoreDest
        }
    }
    else {
        $sourceDriveUi = Get-DriveRootUiName -FolderPath $sourcePath
        $destDriveUi = Get-DriveRootUiName -FolderPath $destinationPath
        $labA = [pscustomobject]@{
            SourcePath = $sourcePath
            DestPath   = $destinationPath
            SourceRoot = $sourceDriveUi
            DestRoot   = $destDriveUi
        }
        $labB = $labA
    }

    Wait-SanitizationIdle -Exe $exe -TimeoutSec $SanitizePollSec -Context 'pre-scenario'

    Invoke-SelectPolicyById -Exe $exe -PolicyId $idA -Label "$CorePolicyNameA (initial)"
    $snapshotA1 = Get-PolicyRootSnapshot -Exe $exe -SourceDriveUi $labA.SourceRoot -DestDriveUi $labA.DestRoot -Label "$CorePolicyNameA initial"

    $jobCountA = Get-RandomJobFileCount -MinCount $MinJobFiles -MaxCount $MaxJobFiles
    $jobFilesA = Select-RandomJobFilesFromPool -Pool $eligiblePool -Count $jobCountA
    Write-TestStep "$CorePolicyNameA sanitization job: $jobCountA file(s) selected from pool"
    if ($script:Sa05SmbLabMode) {
        Copy-Sa05JobFilesToLabSource -LabSourceFolder $labA.SourcePath -JobFiles $jobFilesA
    }
    Invoke-SanitizationJob -Exe $exe -SourcePath $labA.SourcePath -JobFiles $jobFilesA -DestinationPath $labA.DestPath `
        -PolicyLabel $CorePolicyNameA -SourceRootUiName $labA.SourceRoot -DestRootUiName $labA.DestRoot
    $sourceGridAfterJobA = Get-SourceGridSnapshot -Exe $exe -Label "after $CorePolicyNameA job"

    if ($script:Sa05SmbLabMode) {
        Clear-Sa05LabSourceToMarkerOnly -LabSourceFolder $labB.SourcePath
    }

    $forbiddenNamesFromJobA = if ($script:Sa05SmbLabMode) {
        Get-Sa05SmbGridItemNamesOnlyOnPriorLabSource -PriorLabSourceFolder $labA.SourcePath -ActiveLabSourceFolder $labB.SourcePath
    }
    else {
        @()
    }
    Invoke-SelectPolicyById -Exe $exe -PolicyId $idB -Label "$CorePolicyNameB (switch from $CorePolicyNameA)"
    Assert-SourceGridAtFirstDropdownRootAfterPolicySwitch -Exe $exe -PriorJobSourcePath $labA.SourcePath -PriorSnapshot $sourceGridAfterJobA `
        -ExpectedPolicyId $idB -Label "$CorePolicyNameA to $CorePolicyNameB" `
        -ExpectedSmbLabSourcePath $(if ($script:Sa05SmbLabMode) { $labB.SourcePath } else { '' }) `
        -ForbiddenGridItemNames $forbiddenNamesFromJobA
    $snapshotB1 = Get-PolicyRootSnapshot -Exe $exe -SourceDriveUi $labB.SourceRoot -DestDriveUi $labB.DestRoot -Label "$CorePolicyNameB initial"

    if ($snapshotA1.SourceSignature -eq $snapshotB1.SourceSignature -and
        $snapshotA1.DestinationSignature -eq $snapshotB1.DestinationSignature) {
        if ($script:Sa05SmbLabMode) {
            Write-TestStep "$CorePolicyNameA and $CorePolicyNameB share SMB store display names ($($script:Sa05SmbStoreSource) / $($script:Sa05SmbStoreDest)); listSources root signatures match as expected."
        }
        else {
            Write-TestStep "$CorePolicyNameA and $CorePolicyNameB root signatures are identical on this environment (allowed if policies share the same root configuration)."
        }
    }
    else {
        Write-TestStep "$CorePolicyNameA and $CorePolicyNameB root signatures differ as expected for distinct policy configurations."
    }

    $jobCountB = Get-RandomJobFileCount -MinCount $MinJobFiles -MaxCount $MaxJobFiles
    $jobFilesB = Select-RandomJobFilesFromPool -Pool $eligiblePool -Count $jobCountB
    Write-TestStep "$CorePolicyNameB sanitization job: $jobCountB file(s) selected from pool"
    if ($script:Sa05SmbLabMode) {
        Copy-Sa05JobFilesToLabSource -LabSourceFolder $labB.SourcePath -JobFiles $jobFilesB
    }
    Invoke-SanitizationJob -Exe $exe -SourcePath $labB.SourcePath -JobFiles $jobFilesB -DestinationPath $labB.DestPath `
        -PolicyLabel $CorePolicyNameB -SourceRootUiName $labB.SourceRoot -DestRootUiName $labB.DestRoot
    $sourceGridAfterJobB = Get-SourceGridSnapshot -Exe $exe -Label "after $CorePolicyNameB job"

    $forbiddenNamesFromJobB = if ($script:Sa05SmbLabMode) {
        Get-Sa05SmbGridItemNamesOnlyOnPriorLabSource -PriorLabSourceFolder $labB.SourcePath -ActiveLabSourceFolder $labA.SourcePath
    }
    else {
        @()
    }
    Invoke-SelectPolicyById -Exe $exe -PolicyId $idA -Label "$CorePolicyNameA (round-trip)"
    Assert-SourceGridAtFirstDropdownRootAfterPolicySwitch -Exe $exe -PriorJobSourcePath $labB.SourcePath -PriorSnapshot $sourceGridAfterJobB `
        -ExpectedPolicyId $idA -Label "$CorePolicyNameB to $CorePolicyNameA" `
        -ExpectedSmbLabSourcePath $(if ($script:Sa05SmbLabMode) { $labA.SourcePath } else { '' }) `
        -ForbiddenGridItemNames $forbiddenNamesFromJobB
    $snapshotA2 = Get-PolicyRootSnapshot -Exe $exe -SourceDriveUi $labA.SourceRoot -DestDriveUi $labA.DestRoot -Label "$CorePolicyNameA after $CorePolicyNameB"
    Assert-RootSnapshotsMatch -Expected $snapshotA1 -Actual $snapshotA2 -PolicyLabel $CorePolicyNameA

    Invoke-SelectPolicyById -Exe $exe -PolicyId $idB -Label "$CorePolicyNameB (round-trip)"
    $snapshotB2 = Get-PolicyRootSnapshot -Exe $exe -SourceDriveUi $labB.SourceRoot -DestDriveUi $labB.DestRoot -Label "$CorePolicyNameB after $CorePolicyNameA"
    Assert-RootSnapshotsMatch -Expected $snapshotB1 -Actual $snapshotB2 -PolicyLabel $CorePolicyNameB

    if ($script:OriginalPolicyId -ne $idA -and $script:OriginalPolicyId -ne $idB) {
        Write-TestStep "Restore original policy id $($script:OriginalPolicyId)"
        Invoke-SelectPolicyById -Exe $exe -PolicyId $script:OriginalPolicyId -Label 'Original policy restore'
    }

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
    if ($script:Sa05CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Sa05CoreDebugHookUrl)) {
        try {
            Write-TestStep 'Core: poppolicystate (restore pre-test policies and assignment rules)'
            Restore-ScanAgentSa05CorePolicyStack -HookUrl $script:Sa05CoreDebugHookUrl | Out-Null
        }
        catch {
            Write-Warning "Core poppolicystate failed: $($_.Exception.Message)"
        }
    }

    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed -and $destinationPath -and (Test-Path -LiteralPath $destinationPath)) {
        $evidenceOnFailure += $destinationPath
    }
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-05' -TestTitle 'Two policies switch sanitize root lists' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:ScenarioPassed -and $destinationPath) {
        try {
            Remove-ScanAgentE2eTestDestinationFolder -DestinationFolderPath $destinationPath
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
