#Requires -Version 5.1
<#
.SYNOPSIS
  SA-15: Deleted source file before job starts — clear failure/skip; agent remains usable.

.DESCRIPTION
  Selects an existing fixture file in the UI (default CSV\DDE.csv), deletes it from disk, then starts sanitization.
  Asserts the job does not successfully reconstruct the file (passed=0) and reports a clear
  blocked/skipped/failed outcome. Verifies the debug pipe and gateway remain usable afterward,
  then runs one successful local-to-local sanitization (fixture file left on disk) to confirm the
  agent is not stuck. Logs sanitization outcomes to the test log. No grid-sync retry loops.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - Source folder exists on disk. Default destination is C:\test\SA-15 (created if missing); override with -DestinationFolder.
    - -SeedFile optional; when omitted, the first suitable fixture under -SourceFolder is used (e.g. CSV\DDE.csv).
    - -FollowUpSourceFile optional (default Excel\links.xlsx under -SourceFolder) for the success sanitization after SA-15.
    - The SA-15 seed file is backed up and restored after the run if it was deleted during the test.
    - Before jobs run, removes prior destination outputs for the SA-15 and follow-up source leaf names
      (e.g. links.xlsx, links_1.xlsx) so naming collisions do not break assertions.

.NOTES
  Test plan: SA-15 (P1 — Deleted source before job starts).
  Exit 0 = passed; follow-up output file(s) removed from destination on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceFolder = '',
    [string] $DestinationFolder = '',
    [string] $SeedFile = '',
    [string] $NestedSubfolder = 'CSV',
    [string] $FollowUpSourceFile = '',
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600
)

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
$script:Sa15SourceFile = $null
$script:Sa15SourceBackupPath = $null
$script:FollowUpDestinationCleanupPaths = @()
$destinationPath = $null

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function ConvertTo-StringArray {
    param([object] $Value)

    # Comma before @() prevents PowerShell from unwrapping single-element arrays at return/assign.
    if ($null -eq $Value) {
        return ,@()
    }

    if ($Value -is [string]) {
        return ,@([string]$Value)
    }

    return ,@($Value | ForEach-Object { [string]$_ })
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
        # Fall through: stdout may be pretty-printed JSON or include Wait: lines.
    }

    foreach ($line in ($Stdout -split "`r?`n")) {
        $lineTrimmed = $line.Trim()
        if ($lineTrimmed.StartsWith('{')) {
            try {
                return ($lineTrimmed | ConvertFrom-Json)
            }
            catch {
                # Continue; line may be only the opening brace of multi-line JSON.
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
        return (ConvertTo-StringArray @())
    }

    return (ConvertTo-StringArray ($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)))
}

function Invoke-NavigateSourceSegments {
    param(
        [string] $Exe,
        [string[]] $Segments,
        [string] $StepPrefix
    )

    foreach ($segment in (ConvertTo-StringArray $Segments)) {
        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $segment, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}

function Write-SanitizationOutcomeLog {
    param(
        $Status,
        [string] $JobLabel
    )

    if ($null -eq $Status) {
        Write-TestStep "$JobLabel sanitization result: (no status object)"
        return
    }

    $state = [string]$Status.state
    $selected = if ($Status.counts) { [string]$Status.counts.selected } else { 'n/a' }
    $passed = if ($Status.counts) { [string]$Status.counts.passed } else { 'n/a' }
    $blocked = if ($Status.counts) { [string]$Status.counts.blocked } else { 'n/a' }
    $running = if ($Status.counts) { [string]$Status.counts.running } else { 'n/a' }

    Write-TestStep "$JobLabel sanitization result: state=$state selected=$selected passed=$passed blocked=$blocked running=$running"

    $entries = Get-SanitizationFileEntries $Status.files
    if ((Get-CollectionCount $entries) -eq 0) {
        Write-TestStep "$JobLabel per-file outcomes: (none in sanitization.status)"
        return
    }

    foreach ($entry in $entries) {
        $name = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('name', 'fileName', 'FileName')
        $outcome = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $friendly = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        $source = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
        $dest = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('destinationPath', 'DestinationPath')
        Write-TestStep "$JobLabel file='$name' outcome=$outcome friendly=$friendly source=$source destination=$dest"
    }
}

function Find-SourceListItemByFileName {
    param(
        $ListResponse,
        [string] $FileName
    )

    $leafName = [System.IO.Path]::GetFileName($FileName)
    foreach ($item in (Get-SanitizationFileEntries $ListResponse.items)) {
        $name = Get-SanitizationFileProperty -FileEntry $item -PropertyNames @('name', 'fileName', 'FileName')
        if ($name -eq $leafName) {
            return $item
        }

        $path = Get-SanitizationFileProperty -FileEntry $item -PropertyNames @('path', 'Path')
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            if ($path -eq $FilePath -or $path -eq $leafName -or $path -like "*$leafName") {
                return $item
            }
        }
    }

    return $null
}

function Invoke-SelectSourceFileByGridPathOnce {
    param(
        [string] $Exe,
        $ListItem,
        [string] $LeafName,
        [string] $DiskPath
    )

    $uiPath = Get-SanitizationFileProperty -FileEntry $ListItem -PropertyNames @('path', 'Path')
    $listName = Get-SanitizationFileProperty -FileEntry $ListItem -PropertyNames @('name', 'fileName', 'FileName')

    if (-not [string]::IsNullOrWhiteSpace($uiPath)) {
        $selectFile = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--path', $uiPath, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $selectFile -Step "selectSourceFile (grid path '$uiPath')"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($listName)) {
        $selectFile = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--name', $listName, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $selectFile -Step "selectSourceFile (grid name '$listName')"
        return
    }

    $selectFile = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSourceFile', '--name', $LeafName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $selectFile -Step "selectSourceFile (name '$LeafName')"
}

function Invoke-SelectSourceFileOnce {
    param(
        [string] $Exe,
        [string] $FileName,
        [string] $FilePath,
        [string] $StepLabel
    )

    Write-TestStep $StepLabel
    $leafName = [System.IO.Path]::GetFileName($FileName)
    $diskPath = [System.IO.Path]::GetFullPath($FilePath)

    $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $list -Step 'listSourceFiles'
    $item = Find-SourceListItemByFileName -ListResponse $list -FileName $leafName

    if ($null -ne $item) {
        Invoke-SelectSourceFileByGridPathOnce -Exe $Exe -ListItem $item -LeafName $leafName -DiskPath $diskPath
        return
    }

    $selectFile = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSourceFile', '--name', $leafName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $selectFile -Step "selectSourceFile (name '$leafName')"
}

function Invoke-StartSanitizationOnce {
    param(
        [string] $Exe,
        [string] $StepLabel
    )

    Write-TestStep $StepLabel
    $start = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    if ($start.ExitCode -ne 0) {
        $detail = if ($start.StdOut) { $start.StdOut } else { $start.StdErr }
        throw "startSanitization failed (exit $($start.ExitCode)): $detail"
    }

    if ([string]::IsNullOrWhiteSpace($start.StdOut)) {
        return $null
    }

    return (ConvertFrom-ScanAgentDebugOutput -Stdout $start.StdOut)
}

function Get-DestinationArtifactFilters {
    param([string] $SourceLeafName)

    if ([string]::IsNullOrWhiteSpace($SourceLeafName)) {
        return ,@()
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($SourceLeafName)
    $ext = [System.IO.Path]::GetExtension($SourceLeafName)
    return ,@(
        $SourceLeafName,
        ($base + '_*' + $ext),
        ($SourceLeafName + '.Allowed.html'),
        ($base + '_*' + $ext + '.Allowed.html')
    )
}

function Remove-TestDestinationPreflightArtifacts {
    param(
        [string] $DestinationRoot,
        [string[]] $SourceLeafNames
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not (Test-Path -LiteralPath $destRoot -PathType Container)) {
        return
    }

    foreach ($leaf in (ConvertTo-StringArray $SourceLeafNames)) {
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            continue
        }

        $exactPath = Join-Path $destRoot $leaf
        if (Test-Path -LiteralPath $exactPath -PathType Leaf) {
            Write-TestStep "Pre-test destination cleanup: removing '$exactPath'"
            Remove-Item -LiteralPath $exactPath -Force -ErrorAction Stop
        }

        foreach ($filter in (Get-DestinationArtifactFilters -SourceLeafName $leaf)) {
            if ($filter -eq $leaf) {
                continue
            }

            Get-ChildItem -LiteralPath $destRoot -Filter $filter -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Write-TestStep "Pre-test destination cleanup: removing '$($_.FullName)'"
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                }
        }
    }
}

function Wait-DestinationOutputOnDisk {
    param(
        [string] $DestinationRoot,
        [string] $ReportedDestinationPath,
        [string] $SourceLeafName,
        [int] $TimeoutSec = 15,
        [int] $PollSec = 2
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $resolved = Resolve-DestinationOutputOnDisk -DestinationRoot $DestinationRoot `
            -ReportedDestinationPath $ReportedDestinationPath -SourceLeafName $SourceLeafName
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            return $resolved
        }

        Start-Sleep -Seconds $PollSec
    }

    return $null
}

function Resolve-DestinationOutputOnDisk {
    param(
        [string] $DestinationRoot,
        [string] $ReportedDestinationPath,
        [string] $SourceLeafName
    )

    if (-not [string]::IsNullOrWhiteSpace($ReportedDestinationPath)) {
        $reportedFull = [System.IO.Path]::GetFullPath($ReportedDestinationPath)
        if (Test-Path -LiteralPath $reportedFull -PathType Leaf) {
            return $reportedFull
        }
    }

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    $leaf = if ([string]::IsNullOrWhiteSpace($SourceLeafName)) {
        if ($ReportedDestinationPath) { [System.IO.Path]::GetFileName($ReportedDestinationPath) } else { $null }
    }
    else {
        $SourceLeafName
    }

    if ([string]::IsNullOrWhiteSpace($leaf)) {
        return $null
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext = [System.IO.Path]::GetExtension($leaf)
    $suffixPattern = '^' + [regex]::Escape($base) + '_\d+' + [regex]::Escape($ext) + '$'
    $allowedHtml = $leaf + '.Allowed.html'
    $allowedHtmlSuffixPattern = '^' + [regex]::Escape($base) + '_\d+' + [regex]::Escape($ext) + '\.Allowed\.html$'

    $candidates = @(Get-ChildItem -LiteralPath $destRoot -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $leaf -or
            $_.Name -match $suffixPattern -or
            $_.Name -eq $allowedHtml -or
            $_.Name -match $allowedHtmlSuffixPattern
        } |
        Sort-Object LastWriteTime -Descending)

    if ((Get-CollectionCount $candidates) -gt 0) {
        return $candidates[0].FullName
    }

    return $null
}

function Get-FollowUpDestinationPathsFromStatus {
    param(
        $Status,
        [string] $DestinationRoot
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in (Get-SanitizationFileEntries $Status.files)) {
        $dest = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('destinationPath', 'DestinationPath')
        $entryName = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('name', 'fileName', 'FileName')
        $entrySourcePath = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
        $leaf = $entryName
        if ([string]::IsNullOrWhiteSpace($leaf) -and $entrySourcePath) {
            $leaf = [System.IO.Path]::GetFileName($entrySourcePath)
        }

        $resolved = Resolve-DestinationOutputOnDisk -DestinationRoot $DestinationRoot `
            -ReportedDestinationPath $dest -SourceLeafName $leaf
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            $paths.Add($resolved)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($dest)) {
            $paths.Add([System.IO.Path]::GetFullPath($dest))
        }
    }

    return @($paths | Select-Object -Unique)
}

function Remove-SanitizationDestinationArtifacts {
    param([string[]] $DestinationFilePaths)

    foreach ($path in $DestinationFilePaths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $full = [System.IO.Path]::GetFullPath($path)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Write-TestStep "Post-test cleanup: removing destination file '$full'"
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        }
    }
}

function Test-OutcomeIndicatesFailureOrSkip {
    param($FileOutcome)

    if (-not $FileOutcome) {
        return $false
    }

    $tokens = @()
    $outcome = Get-SanitizationFileProperty -FileEntry $FileOutcome -PropertyNames @('outcome', 'Outcome')
    $outcomeFriendly = Get-SanitizationFileProperty -FileEntry $FileOutcome -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
    if ($outcome) {
        $tokens += $outcome
    }
    if ($outcomeFriendly) {
        $tokens += $outcomeFriendly
    }

    $combined = ($tokens -join ' ').ToLowerInvariant()
    $patterns = @(
        'block', 'reject', 'fail', 'skip', 'missing', 'notfound', 'not found',
        'deleted', 'unavailable', 'error', 'denied'
    )

    foreach ($pattern in $patterns) {
        if ($combined.Contains($pattern)) {
            return $true
        }
    }

    if ($outcome -eq 'OutcomeReconstructed') {
        return $false
    }

    return $false
}

function Assert-Sa15SanitizationOutcome {
    param(
        $Status,
        [string] $DeletedFileName,
        [string] $DestinationRoot
    )

    $selected = [int]$Status.counts.selected
    $passed = [int]$Status.counts.passed
    $blocked = [int]$Status.counts.blocked
    $running = [int]$Status.counts.running

    Write-TestStep "Assert job outcome: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -lt 1) {
        throw "Expected at least one selected file; counts.selected=$selected"
    }

    if ($passed -gt 0) {
        $filesJson = if ($Status.files) { ($Status.files | ConvertTo-Json -Depth 5 -Compress) } else { '(no files)' }
        throw "Deleted source should not pass sanitization; counts.passed=$passed. files=$filesJson"
    }

    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }

    $failureReported = ($blocked -ge 1)
    $matchedFile = $null

    foreach ($entry in (Get-SanitizationFileEntries $Status.files)) {
        if (Test-OutcomeIndicatesFailureOrSkip -FileOutcome $entry) {
            $failureReported = $true
        }

        $entryName = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('name', 'fileName', 'FileName')
        $entrySourcePath = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
        if ($entryName -eq $DeletedFileName) {
            $matchedFile = $entry
        }
        if ($entrySourcePath -and $entrySourcePath -like "*$DeletedFileName*") {
            $matchedFile = $entry
        }
    }

    if (-not $failureReported) {
        $filesJson = if ($Status.files) { ($Status.files | ConvertTo-Json -Depth 5 -Compress) } else { '(no files)' }
        throw "Expected clear failure/skip (blocked>=1 or negative per-file outcome); counts.blocked=$blocked files=$filesJson"
    }

    $matchedOutcome = Get-SanitizationFileProperty -FileEntry $matchedFile -PropertyNames @('outcome', 'Outcome')
    if ($matchedFile -and $matchedOutcome -eq 'OutcomeReconstructed') {
        throw "Per-file outcome for '$DeletedFileName' must not be OutcomeReconstructed."
    }

    foreach ($filter in (Get-DestinationArtifactFilters -SourceLeafName $DeletedFileName)) {
        $destHits = @(Get-ChildItem -LiteralPath $DestinationRoot -Filter $filter -File -Force -ErrorAction SilentlyContinue)
        if ((Get-CollectionCount $destHits) -gt 0) {
            throw "Destination contains output for deleted source file '$DeletedFileName' ($($destHits[0].FullName))."
        }
    }
}

function Wait-SanitizationTerminalState {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [string] $StepLabel
    )

    Write-TestStep "$StepLabel poll sanitization.status up to $TimeoutSec seconds"
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
        throw "$StepLabel did not reach a terminal state within $TimeoutSec seconds."
    }

    return $finalStatus
}

function Test-OutcomeIsSuccessfulSanitize {
    param($FileOutcome)

    if (-not $FileOutcome) {
        return $false
    }

    $outcome = Get-SanitizationFileProperty -FileEntry $FileOutcome -PropertyNames @('outcome', 'Outcome')
    $outcomeFriendly = Get-SanitizationFileProperty -FileEntry $FileOutcome -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
    $successOutcomes = @(
        'OutcomeReconstructed', 'OutcomeModified', 'OutcomePassed', 'OutcomeClean'
    )
    $successFriendly = @('Reconstructed', 'Modified', 'Passed', 'Clean')

    if ($outcome -and ($successOutcomes -contains $outcome)) {
        return $true
    }

    if ($outcomeFriendly -and ($successFriendly -contains $outcomeFriendly)) {
        return $true
    }

    return $false
}

function Assert-FollowUpSanitizationOutcome {
    param(
        $Status,
        [string] $SourceFileName,
        [string] $SourceFileFullPath,
        [string] $DestinationRoot
    )

    $selected = [int]$Status.counts.selected
    $passed = [int]$Status.counts.passed
    $blocked = [int]$Status.counts.blocked
    $running = [int]$Status.counts.running

    Write-TestStep "Assert follow-up job outcome: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne 1) {
        throw "Follow-up job expected counts.selected=1; got $selected"
    }

    if ($passed -ne 1) {
        $filesJson = if ($Status.files) { ($Status.files | ConvertTo-Json -Depth 5 -Compress) } else { '(no files)' }
        throw "Follow-up job expected counts.passed=1; got $passed. files=$filesJson"
    }

    if ($blocked -ne 0) {
        throw "Follow-up job expected counts.blocked=0; got $blocked"
    }

    if ($running -ne 0) {
        throw "Follow-up job expected no running items after completion; running=$running"
    }

    if (-not $Status.files) {
        throw 'Follow-up sanitization.status did not include files[] after completion.'
    }

    $sourceFullPath = [System.IO.Path]::GetFullPath($SourceFileFullPath)
    $jobFile = $null
    foreach ($entry in (Get-SanitizationFileEntries $Status.files)) {
        $entrySourcePath = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')
        if (-not [string]::IsNullOrWhiteSpace($entrySourcePath)) {
            if ([System.IO.Path]::GetFullPath($entrySourcePath) -eq $sourceFullPath) {
                $jobFile = $entry
                break
            }
        }
    }

    if (-not $jobFile) {
        foreach ($entry in (Get-SanitizationFileEntries $Status.files)) {
            $entryName = Get-SanitizationFileProperty -FileEntry $entry -PropertyNames @('name', 'fileName', 'FileName')
            if ($entryName -eq $SourceFileName) {
                $jobFile = $entry
                break
            }
        }
    }

    if (-not $jobFile) {
        $filesJson = ($Status.files | ConvertTo-Json -Depth 5 -Compress)
        throw "Follow-up job has no per-file entry for '$SourceFileName'. files=$filesJson"
    }

    if (-not (Test-OutcomeIsSuccessfulSanitize -FileOutcome $jobFile)) {
        $outcome = Get-SanitizationFileProperty -FileEntry $jobFile -PropertyNames @('outcome', 'Outcome')
        $outcomeFriendly = Get-SanitizationFileProperty -FileEntry $jobFile -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        throw "Follow-up file outcome must indicate success (e.g. Reconstructed/Modified); got outcome=$outcome friendly=$outcomeFriendly"
    }

    $reportedDestination = Get-SanitizationFileProperty -FileEntry $jobFile -PropertyNames @('destinationPath', 'DestinationPath')
    Write-TestStep "Follow-up: wait up to 15s for destination artifact under '$DestinationRoot'"
    $actualDestination = Wait-DestinationOutputOnDisk -DestinationRoot $DestinationRoot `
        -ReportedDestinationPath $reportedDestination -SourceLeafName $SourceFileName

    if ([string]::IsNullOrWhiteSpace($actualDestination)) {
        Write-TestStep "Follow-up: no destination artifact on disk (reported='$reportedDestination'); relying on passed=1 and per-file success outcome."
        return
    }

    if ($actualDestination -ne $reportedDestination) {
        Write-TestStep "Follow-up destination on disk: '$actualDestination' (status reported '$reportedDestination')"
    }
}

function Invoke-FollowUpSanitizationJob {
    param(
        [string] $Exe,
        [string] $SourceDriveUi,
        [string[]] $SourceNavSegments,
        [string] $DestDriveUi,
        [string[]] $DestSegments,
        [string] $FollowUpFileName,
        [string] $FollowUpFileFullPath,
        [string] $DestinationRoot
    )

    Write-TestStep 'Step 9: Follow-up sanitization (same source/destination, file not deleted)'

    Write-TestStep 'Step 9a: clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection (follow-up)'

    Write-TestStep "Step 9b: selectSource root '$SourceDriveUi' for follow-up selection"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $SourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource (follow-up)'

    Invoke-NavigateSourceSegments -Exe $Exe -Segments $SourceNavSegments -StepPrefix 'Source (follow-up)'

    if (-not (Test-Path -LiteralPath $FollowUpFileFullPath -PathType Leaf)) {
        throw "Follow-up source file missing on disk before selection: $FollowUpFileFullPath"
    }

    Invoke-SelectSourceFileOnce -Exe $Exe -FileName $FollowUpFileName -FilePath $FollowUpFileFullPath `
        -StepLabel "Step 9c: Select follow-up source file '$FollowUpFileName' (no delete)"

    Write-TestStep "Step 9d: selectDestination root '$DestDriveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $DestDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination (follow-up)'

    Invoke-NavigateDestinationSegments -Exe $Exe -Segments $DestSegments -StepPrefix 'Destination (follow-up)'

    $startJson = Invoke-StartSanitizationOnce -Exe $Exe -StepLabel 'Step 9e: startSanitization for follow-up job'
    if ($null -ne $startJson) {
        Assert-OkResponse -Response $startJson -Step 'startSanitization (follow-up)'
    }

    $followUpStatus = Wait-SanitizationTerminalState -Exe $Exe -TimeoutSec $SanitizePollSec -StepLabel 'Step 9f: Follow-up job'
    Write-SanitizationOutcomeLog -Status $followUpStatus -JobLabel 'Follow-up local sanitize'
    Assert-FollowUpSanitizationOutcome -Status $followUpStatus -SourceFileName $FollowUpFileName `
        -SourceFileFullPath $FollowUpFileFullPath -DestinationRoot $DestinationRoot

    Write-TestStep 'Step 9g: Assert agent still usable after follow-up job'
    Assert-AgentUsable -Exe $Exe

    return (Get-FollowUpDestinationPathsFromStatus -Status $followUpStatus -DestinationRoot $DestinationRoot)
}

function Assert-AgentUsable {
    param([string] $Exe)

    Write-TestStep 'Assert agent remains usable (ping + gateway + idle sanitization)'
    $ping = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping (post-job)'

    $gateway = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('gateway.status')
    Assert-OkResponse -Response $gateway -Step 'gateway.status (post-job)'

    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent (post-job)'
    if ($main.header.isConnected -eq $false) {
        throw 'Agent header is not connected after job; agent is not usable.'
    }

    $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
    Assert-OkResponse -Response $status -Step 'sanitization.status (post-job)'
    if ($status.state -eq 'running') {
        throw 'Sanitization still running after job completion poll; agent not idle.'
    }
}

function Resolve-SeedFilePath {
    param(
        [string] $ExplicitSeed,
        [string] $SourceRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSeed)) {
        $full = [System.IO.Path]::GetFullPath($ExplicitSeed)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Seed file does not exist: $full"
        }
        return $full
    }

    $root = [System.IO.Path]::GetFullPath($SourceRoot)
    $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop |
        Where-Object {
            -not $_.Name.StartsWith('sa15-', [StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object FullName)

    if ((Get-CollectionCount $candidates) -eq 0) {
        throw "No fixture files under source folder and -SeedFile was not provided: $root"
    }

    $preferred = $candidates | Where-Object {
            $_.Extension -in @('.csv', '.txt', '.xlsx', '.docx', '.pdf')
        } | Select-Object -First 1

    if ($null -ne $preferred) {
        Write-TestStep "Auto-selected seed file: $($preferred.FullName)"
        return $preferred.FullName
    }

    Write-TestStep "Auto-selected seed file: $($candidates[0].FullName)"
    return $candidates[0].FullName
}

function Get-WorkSubfolderSegments {
    param(
        [string] $SourceRoot,
        [string] $NestedSubfolder,
        [string] $SeedPath
    )

    $sourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)

    if (-not [string]::IsNullOrWhiteSpace($NestedSubfolder)) {
        $workDir = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $NestedSubfolder))
        if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
            throw "Work subfolder under source does not exist (will not auto-create): $workDir"
        }

        return (ConvertTo-StringArray ($NestedSubfolder.Trim('\', '/').Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)))
    }

    $seedDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($SeedPath))
    if (-not $seedDir.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Seed file must be under source folder: $SeedPath"
    }

    $relative = $seedDir.Substring($sourceRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return (ConvertTo-StringArray @())
    }

    return (ConvertTo-StringArray ($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)))
}

function Get-WorkFolderPath {
    param(
        [string] $SourceRoot,
        [string[]] $WorkRelativeSegments
    )

    $segments = ConvertTo-StringArray $WorkRelativeSegments
    $targetDir = [System.IO.Path]::GetFullPath($SourceRoot)
    if ((Get-CollectionCount $segments) -gt 0) {
        $targetDir = [System.IO.Path]::GetFullPath((Join-Path $targetDir ($segments -join '\')))
    }

    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        throw "Work folder does not exist (will not auto-create): $targetDir"
    }

    return $targetDir
}

function Resolve-FollowUpSourceFilePath {
    param(
        [string] $ExplicitPath,
        [string] $SourceRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $full = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Follow-up source file does not exist: $full"
        }
        return $full
    }

    $defaultPath = [System.IO.Path]::GetFullPath((Join-Path $SourceRoot 'Excel\links.xlsx'))
    if (-not (Test-Path -LiteralPath $defaultPath -PathType Leaf)) {
        throw "Follow-up source file not found: $defaultPath. Pass -FollowUpSourceFile."
    }

    return $defaultPath
}

function Get-NavSegmentsForFileUnderSource {
    param(
        [string] $SourceRoot,
        [string] $FilePath
    )

    $sourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
    $fileFull = [System.IO.Path]::GetFullPath($FilePath)
    $fileDir = [System.IO.Path]::GetDirectoryName($fileFull)
    if (-not $fileDir.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File is not under source folder '$sourceRoot': $fileFull"
    }

    $relativeDir = $fileDir.Substring($sourceRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativeDir)) {
        return (ConvertTo-StringArray @())
    }

    return (ConvertTo-StringArray ($relativeDir.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)))
}

function Backup-Sa15SourceFile {
    param([string] $SourceFilePath)

    $full = [System.IO.Path]::GetFullPath($SourceFilePath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "SA-15 source file does not exist: $full"
    }

    $backupPath = Join-Path ([System.IO.Path]::GetDirectoryName($full)) ('sa15-seed-backup' + [System.IO.Path]::GetExtension($full))
    Write-TestStep "Backup SA-15 source '$full' -> '$backupPath'"
    Copy-Item -LiteralPath $full -Destination $backupPath -Force

    return $backupPath
}

function Restore-Sa15SourceFixture {
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
        Write-TestStep "Restore SA-15 seed fixture from backup: $SourceFilePath"
        Copy-Item -LiteralPath $BackupPath -Destination $SourceFilePath -Force
    }

    Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
}

function Remove-StaleSa15RunFiles {
    param([string] $SourceRoot)

    $pattern = Join-Path ([System.IO.Path]::GetFullPath($SourceRoot)) '**\sa15-run.*'
    Get-ChildItem -Path $pattern -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Write-TestStep "Removing stale test file: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-15'

    $sourcePath = if ([string]::IsNullOrWhiteSpace($SourceFolder)) {
        Get-LabDefaultCdrFixtureFolder
    }
    else {
        [System.IO.Path]::GetFullPath($SourceFolder)
    }

    Write-TestStep 'Validate source folder exists on disk'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Source folder does not exist: $sourcePath"
    }

    Write-TestStep 'Resolve destination folder under C:\test'
    $destinationPath = Resolve-ScanAgentE2eTestDestinationFolderPath -TestId 'SA-15' -DestinationFolder $DestinationFolder

    $resolvedSeedFile = Resolve-SeedFilePath -ExplicitSeed $SeedFile -SourceRoot $sourcePath
    $workSubfolderSegments = Get-WorkSubfolderSegments -SourceRoot $sourcePath -NestedSubfolder $NestedSubfolder -SeedPath $resolvedSeedFile
    $workFolderDisplay = if ((Get-CollectionCount $workSubfolderSegments) -gt 0) { $workSubfolderSegments -join '\' } else { '(source root)' }
    $sa15SourceFile = [System.IO.Path]::GetFullPath($resolvedSeedFile)
    $sa15SourceLeaf = [System.IO.Path]::GetFileName($sa15SourceFile)
    $script:Sa15SourceFile = $sa15SourceFile
    $script:Sa15SourceBackupPath = Backup-Sa15SourceFile -SourceFilePath $sa15SourceFile

    $followUpSourceFile = Resolve-FollowUpSourceFilePath -ExplicitPath $FollowUpSourceFile -SourceRoot $sourcePath
    $followUpSourceLeaf = [System.IO.Path]::GetFileName($followUpSourceFile)

    Write-TestStep "SA-15 source (select then delete): $sa15SourceFile"
    Write-TestStep "Follow-up source (success job): $followUpSourceFile"
    Write-TestStep "SA-15 UI folder under source: $workFolderDisplay"

    Write-TestStep 'Pre-test destination cleanup for SA-15 and follow-up output leaf names'
    Remove-TestDestinationPreflightArtifacts -DestinationRoot $destinationPath `
        -SourceLeafNames @($sa15SourceLeaf, $followUpSourceLeaf)

    Remove-StaleSa15RunFiles -SourceRoot $sourcePath

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
        throw 'Scan Agent header is not connected; connect to gateway before running SA-15.'
    }

    $sourceDriveUi = Get-DriveRootUiName -FolderPath $sourcePath
    $destDriveUi = Get-DriveRootUiName -FolderPath $destinationPath
    $sourceBaseSegments = Get-FolderSegmentsFromDrive -FolderPath $sourcePath
    $destSegments = Get-FolderSegmentsFromDrive -FolderPath $destinationPath

    Write-TestStep "selectSource root '$sourceDriveUi'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource'

    $sa15NavSegments = $sourceBaseSegments + (ConvertTo-StringArray $workSubfolderSegments)
    Invoke-NavigateSourceSegments -Exe $exe -Segments $sa15NavSegments -StepPrefix 'Source'

    Write-TestStep "selectDestination root '$destDriveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination'

    Invoke-NavigateDestinationSegments -Exe $exe -Segments $destSegments -StepPrefix 'Destination'

    Write-TestStep 'Return to source panel for SA-15 file selection'
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step 'selectSource (before selection)'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sa15NavSegments -StepPrefix 'Source (selection)'

    Write-TestStep 'clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    Invoke-SelectSourceFileOnce -Exe $exe -FileName $sa15SourceLeaf -FilePath $sa15SourceFile `
        -StepLabel "Select SA-15 source file '$sa15SourceLeaf' in UI (fixture visible in grid)"

    Write-TestStep "Delete SA-15 source file from disk after UI selection: $sa15SourceFile"
    if (-not (Test-Path -LiteralPath $sa15SourceFile -PathType Leaf)) {
        throw "SA-15 source file missing before delete step: $sa15SourceFile"
    }
    Remove-Item -LiteralPath $sa15SourceFile -Force
    if (Test-Path -LiteralPath $sa15SourceFile) {
        throw "SA-15 source file still present after delete: $sa15SourceFile"
    }

    $startJson = Invoke-StartSanitizationOnce -Exe $exe -StepLabel 'startSanitization after source file deleted (single attempt)'
    if ($null -ne $startJson -and $startJson.ok -eq $false) {
        Write-TestStep "SA-15 startSanitization rejected before job run: $($startJson.error)"
        Write-SanitizationOutcomeLog -Status $null -JobLabel 'SA-15 deleted-source (not started)'
    }
    else {
        if ($null -ne $startJson) {
            Assert-OkResponse -Response $startJson -Step 'startSanitization'
        }

        $finalStatus = Wait-SanitizationTerminalState -Exe $exe -TimeoutSec $SanitizePollSec -StepLabel 'SA-15 deleted-source job'
        Write-SanitizationOutcomeLog -Status $finalStatus -JobLabel 'SA-15 deleted-source'
        Assert-Sa15SanitizationOutcome -Status $finalStatus -DeletedFileName $sa15SourceLeaf -DestinationRoot $destinationPath
    }

    Write-TestStep 'Step 8: Assert agent remains usable after deleted-source job'
    Assert-AgentUsable -Exe $exe

    $followUpNavSegments = $sourceBaseSegments + (Get-NavSegmentsForFileUnderSource -SourceRoot $sourcePath -FilePath $followUpSourceFile)

    $script:FollowUpDestinationCleanupPaths = @(Invoke-FollowUpSanitizationJob -Exe $exe `
        -SourceDriveUi $sourceDriveUi `
        -SourceNavSegments $followUpNavSegments `
        -DestDriveUi $destDriveUi `
        -DestSegments $destSegments `
        -FollowUpFileName $followUpSourceLeaf `
        -FollowUpFileFullPath $followUpSourceFile `
        -DestinationRoot $destinationPath)

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
        -TestId 'SA-15' -TestTitle 'Deleted source before job starts' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    try {
        Restore-Sa15SourceFixture -SourceFilePath $script:Sa15SourceFile -BackupPath $script:Sa15SourceBackupPath
    }
    catch {
        Write-Error "Failed to restore SA-15 seed fixture: $($_.Exception.Message)"
    }

    if ($script:ScenarioPassed) {
        try {
            Remove-SanitizationDestinationArtifacts -DestinationFilePaths $script:FollowUpDestinationCleanupPaths
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
