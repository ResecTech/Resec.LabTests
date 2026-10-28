#Requires -Version 5.1
<#
.SYNOPSIS
  SA-14: Results export after job — export report is non-empty and matches job outcomes.

.DESCRIPTION
  Navigates source to the CDR test tree (segment-by-segment UI navigation), selects destination,
  recursively selects all files under the source folder, runs sanitization, polls until complete,
  then invokes exportReport and asserts the CSV is non-empty and consistent with
  sanitization.status per-file outcomes.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - Agent build supports ui.invoke action exportReport (see ScanAgentDebug help exportReport).
    - Source folder exists on disk. Default destination is C:\test\SA-14 (created if missing); override with -DestinationFolder.
    - CDR fixture tree under Resec.LabTests\Fixtures\CDR (default when -SourceFolder omitted).

.NOTES
  Test plan: SA-14 "Results export after job" — expected: export non-empty and matches job outcomes.
  Exit 0 = passed; destination folder purged on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceFolder = '',
    [string] $DestinationFolder = '',
    [string] $ExportReportPath = '',
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
$script:ExportFileToRemove = $null
$destinationPath = $null

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
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

    $jsonLine = $null
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('{')) {
            $jsonLine = $trimmed
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        throw "ScanAgentDebug returned no JSON line: $commandLine`n$($result.StdOut)"
    }

    try {
        return $jsonLine | ConvertFrom-Json
    }
    catch {
        throw "ScanAgentDebug output was not JSON: $commandLine`n$jsonLine"
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

function Get-OnDiskFilesRecursive {
    param([string] $RootFolder)

    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Source folder does not exist: $root"
    }

    $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop
    return @($files | Sort-Object FullName)
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

function Select-SourceFilesRecursive {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [ref] $SelectedCount,
        [hashtable] $SelectedNames
    )

    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $childFiles = @(Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop | Sort-Object Name)
    $childDirs = @(Get-ChildItem -LiteralPath $diskFolderPath -Directory -Force -ErrorAction Stop | Sort-Object Name)

    foreach ($file in $childFiles) {
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

    foreach ($dir in $childDirs) {
        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $dir.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source ($($dir.Name))"

        Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $dir.FullName -SelectedCount $SelectedCount -SelectedNames $SelectedNames

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

function Remove-DestinationContents {
    param([string] $DestinationFolderPath)

    $dest = [System.IO.Path]::GetFullPath($DestinationFolderPath)
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
        return
    }

    Write-TestStep "Teardown: removing contents of destination '$dest'"
    Get-ChildItem -LiteralPath $dest -Force -ErrorAction Stop | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
    }
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

function Find-CsvPropertyName {
    param(
        [object] $SampleRow,
        [string[]] $PreferredNames,
        [string[]] $SubstringHints
    )

    $props = @($SampleRow.PSObject.Properties.Name)
    foreach ($name in $PreferredNames) {
        $hit = $props | Where-Object { $_.Trim() -ieq $name } | Select-Object -First 1
        if ($hit) {
            return [string] $hit
        }
    }

    foreach ($hint in $SubstringHints) {
        $hit = $props | Where-Object { $_.Trim() -ilike "*$hint*" } | Select-Object -First 1
        if ($hit) {
            return [string] $hit
        }
    }

    return $null
}

function Get-StatusFileSourcePath {
    param(
        $FileEntry,
        [System.IO.FileInfo[]] $OnDiskFiles
    )

    if ($FileEntry.PSObject.Properties['sourcePath']) {
        $sourcePath = [string] $FileEntry.sourcePath
        if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
            return [System.IO.Path]::GetFullPath($sourcePath)
        }
    }

    foreach ($prop in @('source', 'path', 'fullPath', 'name')) {
        if (-not $FileEntry.PSObject.Properties[$prop]) {
            continue
        }
        $candidate = [string] $FileEntry.$prop
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if ($prop -eq 'name' -and $candidate -notmatch '[\\/]') {
            continue
        }
        return [System.IO.Path]::GetFullPath($candidate)
    }

    if ($OnDiskFiles -and $FileEntry.PSObject.Properties['name']) {
        $statusName = [string] $FileEntry.name
        if (-not [string]::IsNullOrWhiteSpace($statusName)) {
            $matches = @($OnDiskFiles | Where-Object { $_.Name -ieq $statusName })
            if ((Get-CollectionCount $matches) -eq 1) {
                return $matches[0].FullName
            }
        }
    }

    throw 'sanitization.status files[] entry has no sourcePath (or resolvable path).'
}

function Assert-ExportReportMatchesJob {
    param(
        [string] $CsvPath,
        [int] $ExportItemCount,
        $FinalStatus,
        [System.IO.FileInfo[]] $OnDiskFiles
    )

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Export report file was not created: $CsvPath"
    }

    $bytes = (Get-Item -LiteralPath $CsvPath).Length
    if ($bytes -lt 1) {
        throw "Export report is empty: $CsvPath"
    }

    Write-TestStep "Export report size: $bytes byte(s) at '$CsvPath'"

    $rows = @(Import-Csv -LiteralPath $CsvPath -ErrorAction Stop)
    $rowCount = Get-CollectionCount $rows
    if ($rowCount -lt 1) {
        throw "Export report CSV has no data rows (only header or blank): $CsvPath"
    }

    $statusFiles = @(Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)
    $selected = [int]$FinalStatus.counts.selected

    if ($ExportItemCount -ne $selected) {
        throw "exportReport itemCount ($ExportItemCount) does not match counts.selected ($selected)."
    }

    if ($rowCount -ne $selected) {
        throw "Export CSV row count ($rowCount) does not match counts.selected ($selected)."
    }

    if ((Get-CollectionCount $statusFiles) -ne $selected) {
        throw "sanitization.status files[] count ($(Get-CollectionCount $statusFiles)) does not match counts.selected ($selected)."
    }

    $sourceColumn = Find-CsvPropertyName -SampleRow $rows[0] -PreferredNames @(
        'Source Path', 'SourcePath', 'Source File', 'SourceFile', 'File Name', 'FileName', 'Name', 'File'
    ) -SubstringHints @('source', 'path', 'file', 'name')

    $outcomeColumn = Find-CsvPropertyName -SampleRow $rows[0] -PreferredNames @(
        'Outcome', 'Sanitization Outcome', 'Result', 'Status', 'Outcome Friendly', 'OutcomeFriendly'
    ) -SubstringHints @('outcome', 'result', 'status')

    if ([string]::IsNullOrWhiteSpace($sourceColumn)) {
        $headers = ($rows[0].PSObject.Properties.Name -join ', ')
        throw "Could not identify source path column in export CSV. Headers: $headers"
    }

    if ([string]::IsNullOrWhiteSpace($outcomeColumn)) {
        $headers = ($rows[0].PSObject.Properties.Name -join ', ')
        throw "Could not identify outcome/status column in export CSV. Headers: $headers"
    }

    Write-TestStep "Export CSV columns for matching: source='$sourceColumn', outcome='$outcomeColumn'"

    $rowsBySourcePath = @{}
    foreach ($row in $rows) {
        $cell = [string] $row.$sourceColumn
        if ([string]::IsNullOrWhiteSpace($cell)) {
            throw 'Export CSV contains a row with an empty source path column.'
        }

        $key = [System.IO.Path]::GetFullPath($cell).ToUpperInvariant()
        if ($rowsBySourcePath.ContainsKey($key)) {
            throw "Export CSV has duplicate source path '$cell'."
        }
        $rowsBySourcePath[$key] = $row
    }

    foreach ($fileEntry in $statusFiles) {
        $sourceFullPath = Get-StatusFileSourcePath -FileEntry $fileEntry -OnDiskFiles $OnDiskFiles
        $lookupKey = $sourceFullPath.ToUpperInvariant()
        if (-not $rowsBySourcePath.ContainsKey($lookupKey)) {
            throw "Export CSV has no row for source path '$sourceFullPath'."
        }

        $csvOutcome = [string] $rowsBySourcePath[$lookupKey].$outcomeColumn
        $outcomeRaw = if ($fileEntry.PSObject.Properties['outcome']) { [string] $fileEntry.outcome } else { '' }
        $outcomeFriendlyRaw = if ($fileEntry.PSObject.Properties['outcomeFriendly']) { [string] $fileEntry.outcomeFriendly } else { '' }
        $expectedTokens = @(
            Normalize-OutcomeToken -Text $outcomeRaw
            Normalize-OutcomeToken -Text $outcomeFriendlyRaw
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $csvToken = Normalize-OutcomeToken -Text $csvOutcome
        $matched = $false
        foreach ($expected in $expectedTokens) {
            if ($csvToken -eq $expected) {
                $matched = $true
                break
            }
            if ($csvToken.Contains($expected) -or $expected.Contains($csvToken)) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            throw "Export outcome mismatch for '$sourceFullPath': CSV '$csvOutcome' vs status outcome='$outcomeRaw' outcomeFriendly='$outcomeFriendlyRaw'."
        }
    }

    Write-TestStep 'Export report row count and per-file outcomes match sanitization.status.'
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-14'

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
    $destinationPath = Resolve-ScanAgentE2eTestDestinationFolderPath -TestId 'SA-14' -DestinationFolder $DestinationFolder

    $onDiskFiles = Get-OnDiskFilesRecursive -RootFolder $sourcePath
    $expectedFileCount = Get-CollectionCount $onDiskFiles
    if ($expectedFileCount -lt 1) {
        throw "Source folder has no files to select: $sourcePath"
    }

    Write-TestStep "On-disk file inventory: $expectedFileCount file(s) under '$sourcePath'"

    if ([string]::IsNullOrWhiteSpace($ExportReportPath)) {
        $ExportReportPath = Join-Path $env:TEMP ("SA14_export_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
    }
    $exportPath = [System.IO.Path]::GetFullPath($ExportReportPath)
    $script:ExportFileToRemove = $exportPath

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
        throw 'Scan Agent header is not connected; connect to gateway before running SA-14.'
    }

    $sourceDriveUi = Get-DriveRootUiName -FolderPath $sourcePath
    $destDriveUi = Get-DriveRootUiName -FolderPath $destinationPath
    $sourceSegments = Get-FolderSegmentsFromDrive -FolderPath $sourcePath
    $destSegments = Get-FolderSegmentsFromDrive -FolderPath $destinationPath

    Write-TestStep "selectSource root '$sourceDriveUi'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceSegments -StepPrefix 'Source'

    Write-TestStep "selectDestination root '$destDriveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination'

    Invoke-NavigateDestinationSegments -Exe $exe -Segments $destSegments -StepPrefix 'Destination'

    Write-TestStep 'Return focus to source panel at CDR folder for selection'
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step 'selectSource (before selection)'

    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceSegments -StepPrefix 'Source (selection)'

    Write-TestStep 'clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    $uiSelectedCount = 0
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount

    Write-TestStep 'Recursive UI selection of all files under source folder'
    Select-SourceFilesRecursive -Exe $exe -DiskFolderPath $sourcePath -SelectedCount $selectedCountRef -SelectedNames $selectedNames

    if ($uiSelectedCount -ne $expectedFileCount) {
        throw "UI selection count ($uiSelectedCount) does not match on-disk file count ($expectedFileCount)."
    }

    Write-TestStep "Starting sanitization (selected $uiSelectedCount file(s))"
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
        throw "Sanitization did not reach state 'complete' within $SanitizePollSec seconds."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running
    $processed = $passed + $blocked

    Write-TestStep "Final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne $expectedFileCount) {
        throw "counts.selected ($selected) does not match on-disk file count ($expectedFileCount)."
    }

    if ($processed -ne $selected) {
        throw "Processed count (passed+blocked=$processed) does not match counts.selected ($selected)."
    }

    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }

    if (-not $finalStatus.files) {
        throw 'sanitization.status did not include files[] after completion (required for export matching).'
    }

    $outcomeCount = Get-CollectionCount (Get-SanitizationFileEntries -FilesProperty $finalStatus.files)
    Write-TestStep "Per-file outcomes in status: $outcomeCount"
    if ($outcomeCount -ne $selected) {
        throw "sanitization.status files array count ($outcomeCount) does not match counts.selected ($selected)."
    }

    Write-TestStep "exportReport -> '$exportPath'"
    $export = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'ui.invoke', '--action', 'exportReport', '--path', $exportPath
    )
    Assert-OkResponse -Response $export -Step 'exportReport'

    $exportItemCount = 0
    if ($export.PSObject.Properties['itemCount']) {
        $exportItemCount = [int]$export.itemCount
    }
    elseif ($export.PSObject.Properties['exportItemCount']) {
        $exportItemCount = [int]$export.exportItemCount
    }
    else {
        throw 'exportReport response did not include itemCount.'
    }

    $writtenPath = $exportPath
    if ($export.PSObject.Properties['exportPath'] -and -not [string]::IsNullOrWhiteSpace([string]$export.exportPath)) {
        $writtenPath = [System.IO.Path]::GetFullPath([string]$export.exportPath)
        $script:ExportFileToRemove = $writtenPath
    }

    Assert-ExportReportMatchesJob -CsvPath $writtenPath -ExportItemCount $exportItemCount -FinalStatus $finalStatus -OnDiskFiles $onDiskFiles

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
    if (-not $script:ScenarioPassed) {
        if ($destinationPath -and (Test-Path -LiteralPath $destinationPath)) { $evidenceOnFailure += $destinationPath }
        if ($script:ExportFileToRemove -and (Test-Path -LiteralPath $script:ExportFileToRemove)) { $evidenceOnFailure += $script:ExportFileToRemove }
    }
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-14' -TestTitle 'Results export after job' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:ScenarioPassed) {
        try {
            Remove-DestinationContents -DestinationFolderPath $destinationPath
            if ($script:ExportFileToRemove -and (Test-Path -LiteralPath $script:ExportFileToRemove)) {
                Write-TestStep "Teardown: removing export report '$($script:ExportFileToRemove)'"
                Remove-Item -LiteralPath $script:ExportFileToRemove -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
