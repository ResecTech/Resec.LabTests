#Requires -Version 5.1
<#
.SYNOPSIS
  SA-08: Abort mid-job  - status + activity bar.

.DESCRIPTION
  Starts a large local sanitization job (flat staging folder under C:\test), waits until the job is
  visibly in progress, invokes abortSanitization via ScanAgentDebug, then asserts:
    - sanitization.status reaches a terminal complete state with counts.running = 0
    - at least one per-file outcome is Aborted; no InProgress outcomes remain
    - ui.mainContent.activity.isProgressBarErrorOrAbortedOutcome is true (red error/abort bar)
    - activity panel Running counter is 0
    - rejected-items drawer lists every Aborted file (openRejectedDrawer; counts match activity.rejected)

  Default Core setup (unless -SkipCorePolicySetup): GET pushpolicystate, POST importpolicies (single lab policy
  **Test8-abort** with SMB **sa08-smb-in** / **sa08-smb-out** -> c:\test\SA-08-in / c:\test\SA-08-out),
  GET commdown (5s) / commup, policy.select Test8-abort; finally GET poppolicystate + commdown/commup and
  policy.select to restore the pre-test policy by name. Helper: Load-Sa08CorePolicy.ps1.

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled = true and gateway connected.
    - Core EnableDebugInterface for default policy import (or -SkipCorePolicySetup for ad-hoc local roots).
    - WebMC export XML with a Scan Agent template policy (see ScanAgentE2eCorePolicy.ps1 / SA-05).
    - Fixtures under SA-TestFiles or Resec.LabTests\Fixtures (Allowed files recommended).

.NOTES
  Test plan: SA-08  - Abort large job: remaining items Aborted; activity bar reflects abort; no stuck Running.
  Log format: numbered [STEP n] lines, ===== phase banners, and per-check EXPECTED / ACTUAL / RESULT.
  Exit 0 = passed; C:\test artifacts removed on success.
  Exit 1 = failed; destination/staging folders left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceFolder = '',
    [string] $TestFilesRoot = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $CorePolicyName = 'Test8-abort',
    [int] $PolicyId = 0,
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $AbortRunningWaitSec = 180,
    [int] $MaxFolderDepth = 5,
    [int] $MinJobFiles = 15,
    [int] $MaxJobFiles = 25
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

$exe = $null
$destinationPath = $null
$jobSourcePath = $null
$script:Sa08CorePolicyStackPushed = $false
$script:Sa08CoreDebugHookUrl = $null
$script:Sa08SmbLabMode = $false
$script:OriginalPolicyName = $null
# Must match ScanAgentE2eCorePolicy.ps1 New-Sa08CorePolicyImportBody defaults.
$script:Sa08SmbLabSource = 'c:\test\SA-08-in'
$script:Sa08SmbLabDest = 'c:\test\SA-08-out'
$script:Sa08SmbStoreSource = 'sa08-smb-in'
$script:Sa08SmbStoreDest = 'sa08-smb-out'
$script:TestFileMaxBytes = 5MB
$script:TestBlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.msp', '.hta', '.jar', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.ps1xml',
    '.vbs', '.vbe', '.js', '.jse', '.ws', '.wsf', '.wsh', '.sh', '.py', '.pyw', '.pl', '.rb', '.php', '.reg', '.inf', '.lnk', '.url'
)

$script:Sa08LogStepNumber = 0

function Write-TestPhase {
    param([string] $Title)
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host "  $Title"
    Write-Host ('=' * 72)
}

function Write-TestStep {
    param([string] $Message)
    $script:Sa08LogStepNumber++
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ''
    Write-Host "[$timestamp] [STEP $($script:Sa08LogStepNumber)] $Message"
}

function Write-TestExpected {
    param([string] $Label, $Value)
    Write-Host "  EXPECTED: $Label = $Value"
}

function Write-TestActual {
    param([string] $Label, $Value)
    Write-Host "  ACTUAL:   $Label = $Value"
}

function Write-TestCheckHeader {
    param([string] $Name, [string] $Context = '')
    $title = if ([string]::IsNullOrWhiteSpace($Context)) { $Name } else { "$Context  - $Name" }
    Write-Host "  CHECK:    $title"
}

function Write-TestCheckPass {
    Write-Host '  RESULT:   PASS'
}

function Assert-Sa08Check {
    param(
        [string] $Name,
        $Expected,
        $Actual,
        [ValidateSet('eq', 'ne', 'ge', 'le', 'gt', 'lt')]
        [string] $Operator = 'eq',
        [string] $Context = ''
    )

    Write-TestCheckHeader -Name $Name -Context $Context
    Write-TestExpected -Label $Name -Value $Expected
    Write-TestActual -Label $Name -Value $Actual

    $pass = $false
    switch ($Operator) {
        'eq' {
            if ($Expected -is [bool] -or $Actual -is [bool]) {
                $pass = [bool]$Expected -eq [bool]$Actual
            }
            elseif (($Expected -is [int] -or $Expected -is [long]) -and ($Actual -is [int] -or $Actual -is [long] -or $Actual -match '^\d+$')) {
                $pass = [long]$Actual -eq [long]$Expected
            }
            else {
                $pass = [string]$Actual -eq [string]$Expected
            }
        }
        'ne' { $pass = [string]$Actual -ne [string]$Expected }
        'ge' { $pass = [long]$Actual -ge [long]$Expected }
        'le' { $pass = [long]$Actual -le [long]$Expected }
        'gt' { $pass = [long]$Actual -gt [long]$Expected }
        'lt' { $pass = [long]$Actual -lt [long]$Expected }
    }

    if (-not $pass) {
        $prefix = if ([string]::IsNullOrWhiteSpace($Context)) { '' } else { "$Context  - " }
        throw "${prefix}${Name}: expected $($Operator) '$Expected', actual '$Actual'."
    }

    Write-TestCheckPass
}

function Test-DirectoryExists {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.Directory]::Exists([System.IO.Path]::GetFullPath($Path)) }
    catch { return $false }
}

function Assert-OkResponse {
    param(
        $Response,
        [string] $Step,
        [switch] $LogCheck
    )

    if ($LogCheck) {
        Write-TestCheckHeader -Name "$Step response.ok"
        Write-TestExpected -Label 'ok' -Value 'true'
        $actualOk = if ($Response.ok -eq $true) { 'true' } else { 'false' }
        Write-TestActual -Label 'ok' -Value $actualOk
    }

    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "${Step} failed: $err"
    }

    if ($LogCheck) {
        Write-TestCheckPass
    }
}

function Get-DriveRootUiName {
    param([string] $FolderPath)
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($FolderPath))
    $letter = $root.TrimEnd('\')
    if (-not $letter.EndsWith(':')) { throw "Unexpected path root: $root" }
    return $letter
}

function Get-FolderSegmentsFromDrive {
    param([string] $FolderPath)
    $full = [System.IO.Path]::GetFullPath($FolderPath)
    $driveRoot = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($driveRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) { return @() }
    return @($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
}

function Test-EligibleTestFile {
    param([System.IO.FileInfo] $File)
    if ($null -eq $File) { return $false }
    if ($File.Length -gt $script:TestFileMaxBytes) { return $false }
    if ($script:TestBlockedExtensions -contains $File.Extension.ToLowerInvariant()) { return $false }
    return $true
}

function Get-RelativeFolderDepthFromRoot {
    param([string] $RootFolder, [string] $FileFullPath)
    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not $root.EndsWith('\')) { $root += '\' }
    $full = [System.IO.Path]::GetFullPath($FileFullPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return [int]::MaxValue }
    $relative = $full.Substring($root.Length)
    $dirPart = [System.IO.Path]::GetDirectoryName($relative)
    if ([string]::IsNullOrWhiteSpace($dirPart)) { return 0 }
    return @($dirPart.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)).Count
}

function Get-EligibleFilesUnderFolder {
    param([string] $RootFolder, [int] $MaxFolderDepth = 5)
    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not (Test-DirectoryExists -Path $root)) { return [System.IO.FileInfo[]]@() }
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    try {
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            try {
                $file = New-Object System.IO.FileInfo $filePath
                if (-not (Test-EligibleTestFile -File $file)) { continue }
                if ((Get-RelativeFolderDepthFromRoot -RootFolder $root -FileFullPath $file.FullName) -gt $MaxFolderDepth) { continue }
                $list.Add($file)
            }
            catch { }
        }
    }
    catch { }
    return [System.IO.FileInfo[]]@($list | Sort-Object FullName)
}

function Resolve-Sa08FixturePoolRoot {
    param(
        [string] $SourceFolderOverride,
        [string] $TestFilesRootOverride,
        [int] $MinEligibleFiles = 1,
        [int] $MaxFolderDepth = 5
    )

    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRootOverride
    if (-not [string]::IsNullOrWhiteSpace($SourceFolderOverride)) {
        $sourceRoot = [System.IO.Path]::GetFullPath($SourceFolderOverride)
        if (-not (Test-DirectoryExists -Path $sourceRoot)) {
            throw "Source folder override does not exist on disk: $sourceRoot"
        }
        return $sourceRoot
    }

    $candidates = @(
        (Join-Path $saRoot 'Allowed\Passed'),
        (Join-Path $saRoot 'Allowed'),
        $saRoot
    )
    $firstExisting = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-DirectoryExists -Path $candidate)) {
            continue
        }
        $full = [System.IO.Path]::GetFullPath($candidate)
        if ($null -eq $firstExisting) {
            $firstExisting = $full
        }
        $eligibleCount = Get-CollectionCount (Get-EligibleFilesUnderFolder -RootFolder $full -MaxFolderDepth $MaxFolderDepth)
        if ($eligibleCount -ge $MinEligibleFiles) {
            return $full
        }
    }

    if ($null -ne $firstExisting) {
        return $firstExisting
    }

    throw "No fixture folder found under '$saRoot' (expected Allowed\Passed or Allowed)."
}

function Get-Sa08UiSelectedCountFromMainContent {
    param($MainContentResponse)

    if ($null -eq $MainContentResponse -or $null -eq $MainContentResponse.mainContent) {
        throw 'ui.mainContent missing mainContent object.'
    }
    if ($null -eq $MainContentResponse.mainContent.activity) {
        throw 'ui.mainContent missing activity object.'
    }

    return [int]$MainContentResponse.mainContent.activity.selected
}

function Get-RandomJobFileCount {
    param([int] $MinCount, [int] $MaxCount)
    if ($MinCount -gt $MaxCount) { throw "MinCount ($MinCount) cannot exceed MaxCount ($MaxCount)." }
    if ($MinCount -eq $MaxCount) { return $MinCount }
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

    $shuffled = @($all | Sort-Object { Get-Random })
    $picked = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $seenNames = @{}
    foreach ($candidate in $shuffled) {
        $leafName = $candidate.Name
        if ([string]::IsNullOrWhiteSpace($leafName) -or $seenNames.ContainsKey($leafName)) { continue }
        $seenNames[$leafName] = $true
        $picked.Add($candidate)
        if ($picked.Count -ge $Count) { break }
    }

    if ($picked.Count -lt $Count) {
        throw "Requested $Count job file(s) with unique names but pool only has $($picked.Count) distinct name(s)."
    }

    return ConvertTo-FileInfoArray @($picked | Sort-Object FullName)
}

function New-Sa08FlatJobSourceFolder {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]] $JobFiles
    )

    $parent = Ensure-ScanAgentE2eTestOutputRoot
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $folder = Join-Path $parent ("SA-08-in-$suffix")
    $null = [System.IO.Directory]::CreateDirectory($folder)

    foreach ($file in $JobFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $folder -Force
    }

    return [System.IO.Path]::GetFullPath($folder)
}

function Test-SanitizationQuiescent {
    param($Status)
    if ($null -eq $Status) { return $false }
    if ([string]$Status.state -eq 'idle') { return $true }
    if ([string]$Status.state -eq 'complete') {
        if ($Status.inProgress -eq $false -and $Status.sanitizationFinished -eq $true) {
            $running = 0
            if ($Status.counts) { $running = [int]$Status.counts.running }
            if ($running -eq 0) { return $true }
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

    Write-TestStep "Poll sanitization.status until quiescent ($Context), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'
        if (Test-SanitizationQuiescent -Status $status) {
            Write-TestStep "sanitization.status quiescent ($Context)"
            Write-TestExpected -Label 'quiescent' -Value 'true'
            Write-TestActual -Label 'state' -Value ([string]$status.state)
            Write-TestCheckPass
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "sanitization.status did not reach quiescent state within ${TimeoutSec}s ($Context)."
}

function Test-Sa08SanitizationAbortWindow {
    param($Status)

    if ($null -eq $Status) { return $false }
    if ([string]$Status.state -ne 'running') { return $false }

    $selected = 0
    $passed = 0
    $blocked = 0
    $running = 0
    if ($Status.counts) {
        $selected = [int]$Status.counts.selected
        $passed = [int]$Status.counts.passed
        $blocked = [int]$Status.counts.blocked
        $running = [int]$Status.counts.running
    }

    $processed = $passed + $blocked
    if ($running -gt 0) { return $true }
    if ($selected -gt 0 -and $processed -gt 0 -and $processed -lt $selected) { return $true }
    return $false
}

function Wait-SanitizationNotRunning {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [string] $Context
    )

    Write-TestStep "Poll sanitization.status until not running ($Context), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'
        if ([string]$status.state -ne 'running' -and $status.inProgress -ne $true) {
            Write-TestStep "sanitization.status ready ($Context)"
            Write-TestExpected -Label 'state' -Value 'not running'
            Write-TestActual -Label 'state' -Value ([string]$status.state)
            Write-TestActual -Label 'inProgress' -Value ([string]$status.inProgress)
            Write-TestCheckPass
            return $status
        }
        Start-Sleep -Milliseconds 500
    }

    throw "sanitization.status still running after ${TimeoutSec}s ($Context)."
}

function Invoke-Sa08SelectJobFilesInSourceUi {
    param(
        [string] $Exe,
        [System.IO.FileInfo[]] $JobFiles,
        [string] $StepLabel
    )

    $listInUi = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listInUi -Step "$StepLabel listSourceFiles"
    $uiNames = @{}
    foreach ($item in @($listInUi.items)) {
        if ($null -ne $item.name) {
            $uiNames[[string]$item.name] = $true
        }
    }

    $selected = 0
    foreach ($file in $JobFiles) {
        $leaf = $file.Name
        if (-not $uiNames.ContainsKey($leaf)) {
            Write-TestStep "Skip selection; not listed in source UI: '$leaf'"
            continue
        }
        Write-TestStep "Select source file '$leaf'"
        $pick = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--name', $leaf, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $pick -Step "selectSourceFile ($leaf)"
        $selected++
    }

    if ($selected -lt 2) {
        throw "Only $selected file(s) selected in source UI ($StepLabel); need at least 2 for abort mid-job."
    }

    return $selected
}

function Wait-SanitizationRunningForAbort {
    param(
        [string] $Exe,
        [int] $TimeoutSec
    )

    Write-TestStep "Poll sanitization.status until mid-job abort window (running or partial progress), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $lastLog = ''

    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if ([string]$status.state -eq 'complete') {
            throw 'Sanitization finished before abort could run. Increase -MinJobFiles / -MaxJobFiles or use a slower lab Core.'
        }

        if (Test-Sa08SanitizationAbortWindow -Status $status) {
            Write-TestStep 'Mid-job abort window reached'
            Write-TestExpected -Label 'sanitization.state' -Value 'running'
            Write-TestActual -Label 'sanitization.state' -Value ([string]$status.state)
            Write-TestExpected -Label 'abort window' -Value 'running>0 OR partial progress (passed+blocked < selected)'
            Write-TestActual -Label 'counts' -Value "selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
            Write-TestCheckPass
            return $status
        }

        $line = "state=$($status.state) selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
        if ($line -ne $lastLog) {
            Write-Host "  $line"
            $lastLog = $line
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Timed out after ${TimeoutSec}s waiting for a mid-job abort window (running>0 or partial progress)."
}

function Test-Sa08OutcomeIsAborted {
    param([string] $Outcome, [string] $OutcomeFriendly)

    if ($Outcome -match 'Aborted') { return $true }
    if (-not [string]::IsNullOrWhiteSpace($OutcomeFriendly) -and
        $OutcomeFriendly.Equals('Aborted', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Test-Sa08OutcomeIsInProgress {
    param([string] $Outcome)

    if ([string]::IsNullOrWhiteSpace($Outcome)) { return $false }
    if ($Outcome -match 'InProgress') { return $true }
    if ($Outcome.Equals('GlobalOutcomeUnknown', [StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-Sa08MainContentRoot {
    param($Payload)

    if ($null -eq $Payload) {
        throw 'ui.mainContent response is null.'
    }
    if ($Payload.PSObject.Properties['mainContent'] -and $null -ne $Payload.mainContent) {
        return $Payload.mainContent
    }
    return $Payload
}

function Get-Sa08SanitizationFileProperty {
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

function Get-Sa08StatusEntrySourceLeafName {
    param(
        $FileEntry,
        [System.IO.FileInfo[]] $OnDiskSourceFiles
    )

    $sourcePath = Get-Sa08SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @(
        'sourcePath', 'SourcePath', 'path', 'Path'
    )
    if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
        return [System.IO.Path]::GetFileName($sourcePath)
    }

    $name = Get-Sa08SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @('name', 'fileName', 'FileName')
    if (-not [string]::IsNullOrWhiteSpace($name) -and $name -notmatch '[\\/]') {
        return $name
    }

    if ($OnDiskSourceFiles) {
        foreach ($file in $OnDiskSourceFiles) {
            $entryName = Get-Sa08SanitizationFileProperty -FileEntry $FileEntry -PropertyNames @('name', 'fileName', 'FileName')
            if ($entryName -and $file.Name -ieq $entryName) {
                return $file.Name
            }
        }
    }

    return $name
}

function Find-Sa08RejectedDrawerItemForStatusEntry {
    param(
        $StatusEntry,
        [object[]] $DrawerItems,
        [System.IO.FileInfo[]] $OnDiskSourceFiles,
        [string] $SourceRootPath
    )

    $sourceLeaf = Get-Sa08StatusEntrySourceLeafName -FileEntry $StatusEntry -OnDiskSourceFiles $OnDiskSourceFiles
    $statusSourcePath = Get-Sa08SanitizationFileProperty -FileEntry $StatusEntry -PropertyNames @('sourcePath', 'SourcePath', 'path', 'Path')

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
        if (-not [string]::IsNullOrWhiteSpace($sourceLeaf) -and -not [string]::IsNullOrWhiteSpace($drawerSource)) {
            $candidate = Join-Path $SourceRootPath $sourceLeaf
            if (Test-Path -LiteralPath $candidate) {
                $candidateFull = [System.IO.Path]::GetFullPath($candidate)
                if ([System.IO.Path]::GetFullPath($drawerSource).Equals($candidateFull, [StringComparison]::OrdinalIgnoreCase)) {
                    return $item
                }
            }
        }
    }

    return $null
}

function Test-Sa08DrawerTextIndicatesAborted {
    param([string] $StatusText, [string] $Description)

    foreach ($raw in @($StatusText, $Description)) {
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }
        if ($raw -match 'abort') {
            return $true
        }
    }
    return $false
}

function Assert-Sa08RejectedDrawerShowsAbortedFiles {
    param(
        $FinalStatus,
        [string] $Exe,
        [System.IO.FileInfo[]] $JobFiles,
        [string] $SourceRootPath,
        [string] $StepLabel = 'SA-08 rejected drawer'
    )

    $abortedEntries = @()
    foreach ($entry in (Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)) {
        $outcome = Get-Sa08SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcome', 'Outcome')
        $friendly = Get-Sa08SanitizationFileProperty -FileEntry $entry -PropertyNames @('outcomeFriendly', 'OutcomeFriendly')
        if (Test-Sa08OutcomeIsAborted -Outcome $outcome -OutcomeFriendly $friendly) {
            $abortedEntries += $entry
        }
    }

    Write-TestPhase 'VERIFY  - Rejected drawer lists all Aborted files'

    $abortedCount = (Get-CollectionCount $abortedEntries)
    Assert-Sa08Check -Name 'Aborted per-file outcomes (sanitization.status)' -Expected 1 -Actual $abortedCount `
        -Operator ge -Context $StepLabel

    $blocked = [int]$FinalStatus.counts.blocked
    Write-TestStep 'Rejected counter vs Aborted per-file outcomes'
    Write-TestActual -Label 'counts.blocked / activity.rejected (all rejected UI items)' -Value $blocked
    Write-TestActual -Label 'Aborted per-file outcomes only' -Value $abortedCount

    Write-TestStep 'Invoke openRejectedDrawer'
    $openDrawer = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'openRejectedDrawer')
    Assert-OkResponse -Response $openDrawer -Step 'openRejectedDrawer' -LogCheck

    Write-TestStep 'Read ui.mainContent (rejected drawer open)'
    $mainPayload = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainPayload -Step 'ui.mainContent (rejected drawer)' -LogCheck
    $main = Get-Sa08MainContentRoot -Payload $mainPayload

    if ($null -eq $main.activity) {
        throw "${StepLabel}: mainContent.activity missing."
    }
    if ($null -eq $main.rejectedDrawer) {
        throw "${StepLabel}: mainContent.rejectedDrawer missing."
    }

    $activityRejected = [int]$main.activity.rejected
    Assert-Sa08Check -Name 'activity.rejected vs counts.blocked' -Expected $blocked -Actual $activityRejected -Context $StepLabel

    $drawerCount = [int]$main.rejectedDrawer.itemCount
    $drawerItems = @($main.rejectedDrawer.items)
    $itemsCount = Get-CollectionCount $drawerItems

    Assert-Sa08Check -Name 'rejectedDrawer.itemCount vs counts.blocked' -Expected $blocked -Actual $drawerCount -Context $StepLabel
    Assert-Sa08Check -Name 'rejectedDrawer.items.length vs counts.blocked' -Expected $blocked -Actual $itemsCount -Context $StepLabel
    Assert-Sa08Check -Name 'rejectedDrawer.items.length >= Aborted file count' -Expected $abortedCount -Actual $itemsCount `
        -Operator ge -Context $StepLabel

    $matched = 0
    foreach ($entry in $abortedEntries) {
        $sourceLeaf = Get-Sa08StatusEntrySourceLeafName -FileEntry $entry -OnDiskSourceFiles $JobFiles
        Write-TestStep "Match rejected drawer row for Aborted file '$sourceLeaf'"
        $drawerItem = Find-Sa08RejectedDrawerItemForStatusEntry -StatusEntry $entry -DrawerItems $drawerItems `
            -OnDiskSourceFiles $JobFiles -SourceRootPath $SourceRootPath
        Assert-Sa08Check -Name "drawer row present for '$sourceLeaf'" -Expected 'found' `
            -Actual $(if ($null -eq $drawerItem) { 'missing' } else { 'found' }) -Context $StepLabel

        $statusText = ''
        if ($null -ne $drawerItem.PSObject.Properties['statusText']) {
            $statusText = [string] $drawerItem.statusText
        }
        $description = ''
        if ($null -ne $drawerItem.PSObject.Properties['description']) {
            $description = [string] $drawerItem.description
        }
        $hasAbortText = Test-Sa08DrawerTextIndicatesAborted -StatusText $statusText -Description $description
        Assert-Sa08Check -Name "drawer status mentions abort ('$sourceLeaf')" -Expected 'true' `
            -Actual $(if ($hasAbortText) { 'true' } else { 'false' }) -Context $StepLabel
        Write-TestActual -Label 'statusText' -Value $statusText
        Write-TestActual -Label 'description' -Value $description

        $matched++
    }

    Assert-Sa08Check -Name 'Aborted files matched in drawer' -Expected $abortedCount -Actual $matched -Context $StepLabel

    Write-TestStep 'Invoke closeRejectedDrawer'
    $closeDrawer = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'closeRejectedDrawer')
    Assert-OkResponse -Response $closeDrawer -Step 'closeRejectedDrawer' -LogCheck
}

function Wait-SanitizationCompleteAfterAbort {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [int] $ExpectedSelected
    )

    Write-TestStep "Poll sanitization.status until complete after abort (selected=$ExpectedSelected), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $finalStatus = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 1
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if ([string]$status.state -eq 'complete') {
            $finalStatus = $status
            break
        }

        if ([string]$status.state -eq 'idle' -and $status.inProgress -eq $false -and $status.sanitizationFinished -eq $true) {
            $finalStatus = $status
            break
        }
    }

    if (-not $finalStatus) {
        throw "Sanitization did not reach complete within $TimeoutSec seconds after abort."
    }

    Write-TestStep 'Sanitization terminal after abort'
    Write-TestExpected -Label 'sanitization.state' -Value 'complete OR idle (finished)'
    Write-TestActual -Label 'sanitization.state' -Value ([string]$finalStatus.state)
    Write-TestActual -Label 'inProgress' -Value ([string]$finalStatus.inProgress)
    Write-TestActual -Label 'sanitizationFinished' -Value ([string]$finalStatus.sanitizationFinished)
    Write-TestCheckPass

    return $finalStatus
}

function Assert-Sa08AbortOutcomes {
    param(
        $FinalStatus,
        [string] $Exe,
        [int] $ExpectedSelected
    )

    Write-TestPhase 'VERIFY  - sanitization.status after abort'

    $selected = [int]$FinalStatus.counts.selected
    $passed = [int]$FinalStatus.counts.passed
    $blocked = [int]$FinalStatus.counts.blocked
    $running = [int]$FinalStatus.counts.running
    $processed = $passed + $blocked

    Write-TestStep 'Post-abort sanitization counters'
    Write-TestActual -Label 'counts' -Value "selected=$selected passed=$passed blocked=$blocked running=$running"

    Assert-Sa08Check -Name 'counts.selected' -Expected $ExpectedSelected -Actual $selected -Context 'SA-08 status'
    Assert-Sa08Check -Name 'counts.running' -Expected 0 -Actual $running -Context 'SA-08 status'
    Assert-Sa08Check -Name 'passed+blocked' -Expected $selected -Actual $processed -Context 'SA-08 status'

    if (-not $FinalStatus.files) {
        throw 'SA-08 status  - sanitization.status did not include files[] after abort completion.'
    }

    $entries = Get-SanitizationFileEntries -FilesProperty $FinalStatus.files
    $filesCount = Get-CollectionCount $entries
    Assert-Sa08Check -Name 'files[].length' -Expected $selected -Actual $filesCount -Context 'SA-08 status'

    $abortedCount = 0
    $inProgressCount = 0
    foreach ($entry in $entries) {
        $outcome = [string]$entry.outcome
        $friendly = [string]$entry.outcomeFriendly
        if (Test-Sa08OutcomeIsInProgress -Outcome $outcome) {
            $inProgressCount++
        }
        if (Test-Sa08OutcomeIsAborted -Outcome $outcome -OutcomeFriendly $friendly) {
            $abortedCount++
        }
    }

    Assert-Sa08Check -Name 'InProgress per-file outcomes' -Expected 0 -Actual $inProgressCount -Context 'SA-08 status'
    Assert-Sa08Check -Name 'Aborted per-file outcomes' -Expected 1 -Actual $abortedCount -Operator ge -Context 'SA-08 status'

    $otherTerminal = $selected - $abortedCount
    Write-TestStep 'Per-file outcome summary'
    Write-TestActual -Label 'Aborted' -Value $abortedCount
    Write-TestActual -Label 'Other terminal (e.g. Passed before abort)' -Value $otherTerminal

    Write-TestPhase 'VERIFY  - Activity bar after abort'

    Write-TestStep 'Read ui.mainContent (activity panel)'
    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent after abort' -LogCheck
    if ($null -eq $main.mainContent -or $null -eq $main.mainContent.activity) {
        throw 'SA-08 activity  - ui.mainContent.activity missing after abort.'
    }

    $activity = $main.mainContent.activity
    Assert-Sa08Check -Name 'activity.isProgressBarErrorOrAbortedOutcome' -Expected 'true' `
        -Actual $(if ($activity.isProgressBarErrorOrAbortedOutcome -eq $true) { 'true' } else { 'false' }) -Context 'SA-08 activity'
    Assert-Sa08Check -Name 'activity.running' -Expected 0 -Actual ([int]$activity.running) -Context 'SA-08 activity'
    Assert-Sa08Check -Name 'activity.sanitizationFinished' -Expected 'true' `
        -Actual $(if ($activity.sanitizationFinished -eq $true) { 'true' } else { 'false' }) -Context 'SA-08 activity'
}

function Invoke-Sa08NavigateSourceToPath {
    param(
        [string] $Exe,
        [string] $DiskPath,
        [string] $StepLabel
    )

    $driveUi = Get-DriveRootUiName -FolderPath $DiskPath
    $segments = Get-FolderSegmentsFromDrive -FolderPath $DiskPath

    Write-TestStep "$StepLabel selectSource '$driveUi'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $driveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "$StepLabel selectSource"

    Invoke-NavigateSourceSegments -Exe $Exe -Segments $segments -StepPrefix $StepLabel
    Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "$StepLabel refreshSourceContent"
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

function Resolve-Sa08LabPolicyId {
    param(
        [string] $Exe,
        [string] $PolicyName,
        [int] $OverridePolicyId
    )

    if ($OverridePolicyId -gt 0) {
        return $OverridePolicyId
    }

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list (resolve SA-08 policy id)'
    $match = @($policyList.policies | Where-Object { [string]$_.name -eq $PolicyName })
    if ($match.Count -lt 1) {
        throw "Policy '$PolicyName' not found in policy.list."
    }
    if ($match.Count -gt 1) {
        Write-TestStep "Multiple policies named '$PolicyName'; using lowest id."
    }

    return [int](@($match | Sort-Object { [int]$_.id })[0].id)
}

function Invoke-Sa08SelectCorePolicy {
    param(
        [string] $Exe,
        [string] $PolicyName,
        [string] $Label
    )

    Write-TestStep "policy.select --name '$PolicyName' ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--name', $PolicyName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $select -Step "policy.select ($Label)"

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy select '$PolicyName' (exit $($ready.ExitCode)): $($ready.StdOut)"
    }
}

function Clear-Sa08LabSourceFolder {
    param(
        [Parameter(Mandatory)]
        [string] $LabSourceFolder
    )

    if (-not (Test-DirectoryExists -Path $LabSourceFolder)) {
        return
    }

    foreach ($existing in @(Get-ChildItem -LiteralPath $LabSourceFolder -File -Force -ErrorAction SilentlyContinue)) {
        if ($existing.Name -like '*-lab-folder.txt') {
            continue
        }
        Remove-Item -LiteralPath $existing.FullName -Force
    }
}

function Copy-Sa08JobFilesToLabSource {
    param(
        [Parameter(Mandatory)]
        [string] $LabSourceFolder,
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]] $JobFiles
    )

    if (-not (Test-DirectoryExists -Path $LabSourceFolder)) {
        throw "SMB lab source folder does not exist: $LabSourceFolder"
    }

    Clear-Sa08LabSourceFolder -LabSourceFolder $LabSourceFolder
    foreach ($file in $JobFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $LabSourceFolder -Force
    }
}

function Invoke-Sa08NavigateSmbLabPanels {
    param(
        [string] $Exe,
        [string] $StepLabel
    )

    Write-TestStep "$StepLabel selectSource '$($script:Sa08SmbStoreSource)'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Sa08SmbStoreSource, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "$StepLabel selectSource"

    Write-TestStep "$StepLabel selectDestination '$($script:Sa08SmbStoreDest)'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $script:Sa08SmbStoreDest, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "$StepLabel selectDestination"

    Write-TestStep "$StepLabel return to source for selection"
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Sa08SmbStoreSource, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step "$StepLabel selectSource (selection)"
}

function Invoke-Sa08NavigateDestinationToPath {
    param(
        [string] $Exe,
        [string] $DiskPath,
        [string] $StepLabel
    )

    $driveUi = Get-DriveRootUiName -FolderPath $DiskPath
    $segments = Get-FolderSegmentsFromDrive -FolderPath $DiskPath

    Write-TestStep "$StepLabel selectDestination '$driveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $driveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "$StepLabel selectDestination"

    Invoke-NavigateDestinationSegments -Exe $Exe -Segments $segments -StepPrefix $StepLabel
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-08'

    Write-TestPhase 'SA-08  - Abort mid-job status + action bar'

    if ($MinJobFiles -lt 2) { throw '-MinJobFiles must be at least 2 for a meaningful abort mid-job test.' }
    if ($MaxJobFiles -lt $MinJobFiles) { throw "-MaxJobFiles ($MaxJobFiles) must be >= -MinJobFiles ($MinJobFiles)." }

    $fixturePoolRoot = Resolve-Sa08FixturePoolRoot -SourceFolderOverride $SourceFolder -TestFilesRootOverride $TestFilesRoot `
        -MinEligibleFiles $MinJobFiles -MaxFolderDepth $MaxFolderDepth
    $eligiblePool = Get-EligibleFilesUnderFolder -RootFolder $fixturePoolRoot -MaxFolderDepth $MaxFolderDepth
    $poolCount = Get-CollectionCount $eligiblePool
    if ($poolCount -lt $MinJobFiles) {
        throw "Fixture pool '$fixturePoolRoot' has $poolCount eligible file(s); need at least $MinJobFiles."
    }

    $jobCount = Get-RandomJobFileCount -MinCount $MinJobFiles -MaxCount $MaxJobFiles
    $jobFiles = Select-RandomJobFilesFromPool -Pool $eligiblePool -Count $jobCount

    Write-TestPhase 'SETUP  - Fixtures and agent connectivity'

    Write-TestStep 'Resolve job file set'
    Write-TestActual -Label 'fixture pool' -Value $fixturePoolRoot
    Write-TestActual -Label 'job file count' -Value $jobCount

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep 'Resolve ScanAgentDebug'
    Write-TestActual -Label 'ScanAgentDebug' -Value $exe

    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping' -LogCheck

    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info' -LogCheck
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) { Write-TestStep "Reporting componentVersion: $e2eVersion" }

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 120 -Context 'before SA-08 scenario' -NudgeReconnect

    $policyCurrentStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrentStart -Step 'policy.current (before Core setup)' -LogCheck
    $script:OriginalPolicyName = [string]$policyCurrentStart.policy.name
    Write-TestStep 'Record policy to restore after test'
    Write-TestActual -Label 'OriginalPolicyName' -Value $script:OriginalPolicyName

    if (-not $SkipCorePolicySetup) {
        Write-TestPhase 'SETUP  - Core lab policy (Test8-abort)'
        Write-TestStep 'Core pushpolicystate (snapshot policies and assignment rules)'
        $coreSetup = Initialize-ScanAgentSa08CoreTestPolicy -Exe $exe -CoreDebugHookUrl $CoreDebugHookUrl `
            -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
            -PolicyName $CorePolicyName -UiWaitMs $UiWaitMs
        $script:Sa08CorePolicyStackPushed = $true
        $script:Sa08CoreDebugHookUrl = $coreSetup.HookUrl
        $script:Sa08SmbLabMode = $true
        $jobSourcePath = $script:Sa08SmbLabSource
        $destinationPath = $script:Sa08SmbLabDest
        Write-TestStep "Core importpolicies OK (policy '$CorePolicyName'; SMB $($script:Sa08SmbStoreSource) -> $($script:Sa08SmbLabSource), $($script:Sa08SmbStoreDest) -> $($script:Sa08SmbLabDest))"

        $labPolicyId = Resolve-Sa08LabPolicyId -Exe $exe -PolicyName $CorePolicyName -OverridePolicyId $PolicyId
        if ($PolicyId -gt 0) {
            Write-TestStep "policy.select --policy-id $labPolicyId (SA-08 lab policy)"
            $selectLab = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
                'policy.select', '--policy-id', "$labPolicyId", '--wait-ms', "$UiWaitMs"
            )
            Assert-OkResponse -Response $selectLab -Step 'policy.select (SA-08 lab policy)'
            $readyLab = Invoke-ScanAgentDebug -Exe $exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
            if ($readyLab.ExitCode -ne 0) {
                throw "waitReady failed after SA-08 policy select (exit $($readyLab.ExitCode)): $($readyLab.StdOut)"
            }
        }
        else {
            Invoke-Sa08SelectCorePolicy -Exe $exe -PolicyName $CorePolicyName -Label 'SA-08 lab policy'
        }
        $null = Wait-ScanAgentSourceRootVisible -Exe $exe -RootName $script:Sa08SmbStoreSource
    }
    else {
        $destinationPath = New-ScanAgentE2eTestDestinationFolder
        $jobSourcePath = New-Sa08FlatJobSourceFolder -JobFiles $jobFiles
        Write-TestStep 'SkipCorePolicySetup: ad-hoc C:\test staging (no Core pop/restore)'
    }

    Write-TestPhase 'SETUP  - Job folders and UI navigation'

    Write-TestStep 'Job paths on disk'
    Write-TestActual -Label 'source' -Value $jobSourcePath
    Write-TestActual -Label 'destination' -Value $destinationPath

    $null = Wait-SanitizationNotRunning -Exe $exe -TimeoutSec 120 -Context 'pre-scenario'

    if ($script:Sa08SmbLabMode) {
        Copy-Sa08JobFilesToLabSource -LabSourceFolder $jobSourcePath -JobFiles $jobFiles
        Invoke-Sa08NavigateSmbLabPanels -Exe $exe -StepLabel 'SMB lab'
        Invoke-ScanAgentE2eRefreshSourceContent -Exe $exe -StepLabel 'refresh SMB source before selection'
    }
    else {
        Invoke-Sa08NavigateDestinationToPath -Exe $exe -DiskPath $destinationPath -StepLabel 'Destination setup'
        Invoke-Sa08NavigateSourceToPath -Exe $exe -DiskPath $jobSourcePath -StepLabel 'Source job folder'
    }

    Write-TestPhase 'RUN  - Select files and start job'

    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection' -LogCheck

    $uiSelectedCount = Invoke-Sa08SelectJobFilesInSourceUi -Exe $exe -JobFiles $jobFiles -StepLabel 'job folder'
    Assert-Sa08Check -Name 'UI selected file count' -Expected $MinJobFiles -Actual $uiSelectedCount -Operator ge `
        -Context 'pre-start'

    $mainBefore = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainBefore -Step 'ui.mainContent before start' -LogCheck
    Assert-Sa08Check -Name 'canStartSanitization' -Expected 'true' `
        -Actual $(if ($mainBefore.mainContent.canStartSanitization -eq $true) { 'true' } else { 'false' }) -Context 'pre-start'

    Write-TestPhase 'RUN  - Start sanitization, abort mid-job'

    Write-TestStep 'Invoke startSanitization'
    Write-TestActual -Label 'uiSelectedCount' -Value $uiSelectedCount
    $start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization' -LogCheck

    $runningSnapshot = Wait-SanitizationRunningForAbort -Exe $exe -TimeoutSec $AbortRunningWaitSec
    $expectedSelected = [int]$runningSnapshot.counts.selected
    Assert-Sa08Check -Name 'counts.selected (job queue)' -Expected 2 -Actual $expectedSelected -Operator ge -Context 'mid-job'

    Write-TestStep 'Invoke abortSanitization'
    $abort = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'abortSanitization')
    Assert-OkResponse -Response $abort -Step 'abortSanitization' -LogCheck

    Write-TestPhase 'WAIT  - Job completes after abort'
    $finalStatus = Wait-SanitizationCompleteAfterAbort -Exe $exe -TimeoutSec $SanitizePollSec -ExpectedSelected $expectedSelected
    Assert-Sa08AbortOutcomes -FinalStatus $finalStatus -Exe $exe -ExpectedSelected $expectedSelected
    Assert-Sa08RejectedDrawerShowsAbortedFiles -FinalStatus $finalStatus -Exe $exe -JobFiles $jobFiles -SourceRootPath $jobSourcePath

    Wait-SanitizationIdle -Exe $exe -TimeoutSec $SanitizePollSec -Context 'post-scenario'

    $script:ScenarioPassed = $true
    Write-TestPhase 'SA-08  - SCENARIO PASSED'
    exit 0
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($script:Sa08CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Sa08CoreDebugHookUrl) -and
        -not [string]::IsNullOrWhiteSpace($exe)) {
        try {
            Write-TestStep "Core: poppolicystate and restore agent policy '$($script:OriginalPolicyName)'"
            $null = Restore-ScanAgentCorePolicyLabAndAgent -HookUrl $script:Sa08CoreDebugHookUrl -Exe $exe `
                -OriginalPolicyName $script:OriginalPolicyName -UiWaitMs $UiWaitMs
        }
        catch {
            Write-Warning "Core policy restore failed: $($_.Exception.Message)"
        }
    }

    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed) {
        if ($destinationPath -and (Test-Path -LiteralPath $destinationPath)) { $evidenceOnFailure += $destinationPath }
        if ($jobSourcePath -and (Test-Path -LiteralPath $jobSourcePath)) { $evidenceOnFailure += $jobSourcePath }
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-08' -TestTitle 'Abort mid-job status action bar' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:ScenarioPassed) {
        try {
            if ($script:Sa08SmbLabMode) {
                Clear-Sa08LabSourceFolder -LabSourceFolder $script:Sa08SmbLabSource
            }
            else {
                if ($destinationPath) {
                    Remove-ScanAgentE2eTestDestinationFolder -DestinationFolderPath $destinationPath
                }
                if ($jobSourcePath -and (Test-Path -LiteralPath $jobSourcePath)) {
                    Remove-Item -LiteralPath $jobSourcePath -Recurse -Force -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
