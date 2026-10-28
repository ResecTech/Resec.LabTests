#Requires -Version 5.1
<#
.SYNOPSIS
  SA-09: SMB local <-> SMB (same Core path) - Local->SMB, SMB->Local, SMB->SMB sanitization routes.

.DESCRIPTION
  Verifies a single Scan Agent policy with Local Source, SMB Source, Local Destination, and SMB Destination
  (SMB stores mapped to lab folders on the Core host) completes three sanitization jobs with Pass/Modified
  outcomes and no stuck Running items.

  Prerequisites:
    - Desktop Scan Agent running with DebugInterface.Enabled = true and gateway connected.
    - Core REST debug hooks enabled for default policy lab setup.
    - Eligible files under Resec.LabTests\Fixtures\Allowed (or legacy SA-TestFiles\Allowed).

  Default Core setup (unless -SkipCorePolicySetup): pushpolicystate, importpolicies (Test9-smb-local),
  commdown/commup, poppolicystate in finally.

.NOTES
  Test plan: SA-09 - Policy SMB root Local->SMB, SMB->Local, SMB->SMB complete with Pass/Modified; no stuck Running.
  Exit 0 = passed; destination folders purged on success.
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
    [string] $CorePolicyName = 'Test9-smb-local',
    [int] $PolicyId = 0,
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $MaxFolderDepth = 5,
    [int] $MinJobFiles = 1,
    [int] $MaxJobFiles = 3
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

$script:Sa09CorePolicyStackPushed = $false
$script:Sa09CoreDebugHookUrl = $null
$script:OriginalPolicyId = $null
$script:Sa09LabPolicyId = $null
$script:TestFileMaxBytes = 5MB
$script:TestBlockedExtensions = @(
    '.exe', '.dll', '.com', '.scr', '.msi', '.msp', '.hta', '.jar', '.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.ps1xml',
    '.vbs', '.vbe', '.js', '.jse', '.ws', '.wsf', '.wsh', '.sh', '.py', '.pyw', '.pl', '.rb', '.php', '.reg', '.inf', '.lnk', '.url'
)
$script:Sa09DestinationFolders = @()

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Assert-OkResponse {
    param($Response, [string] $Step)
    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "${Step} failed: $err"
    }
}

function Test-EligibleTestFile {
    param([System.IO.FileInfo] $File)
    if ($File.Length -gt $script:TestFileMaxBytes) { return $false }
    if ($script:TestBlockedExtensions -contains $File.Extension.ToLowerInvariant()) { return $false }
    return $true
}

function Get-DriveRootUiName {
    param([string] $FolderPath)
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($FolderPath))
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

    foreach ($segment in @($Segments)) {
        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $segment, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}

function Invoke-NavigateSourceToDiskPath {
    param(
        [string] $Exe,
        [string] $DiskPath,
        [string] $Label
    )

    $driveUi = Get-DriveRootUiName -FolderPath $DiskPath
    $segments = Get-FolderSegmentsFromDrive -FolderPath $DiskPath

    Write-TestStep "selectSource root '$driveUi' ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $driveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $select -Step "selectSource ($Label)"

    if ((Get-CollectionCount $segments) -gt 0) {
        Invoke-NavigateSourceSegments -Exe $Exe -Segments $segments -StepPrefix "Source ($Label)"
    }
}

function Invoke-NavigateDestinationToDiskPath {
    param(
        [string] $Exe,
        [string] $DiskPath,
        [string] $Label
    )

    $driveUi = Get-DriveRootUiName -FolderPath $DiskPath
    $segments = Get-FolderSegmentsFromDrive -FolderPath $DiskPath

    Write-TestStep "selectDestination root '$driveUi' ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $driveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $select -Step "selectDestination ($Label)"

    if ((Get-CollectionCount $segments) -gt 0) {
        Invoke-NavigateDestinationSegments -Exe $Exe -Segments $segments -StepPrefix "Destination ($Label)"
    }
}

function Select-SourceFilesRecursive {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceRootPath,
        [ref] $SelectedCount,
        [hashtable] $SelectedNames,
        [hashtable] $EligiblePathSet,
        [int] $MaxJobFiles,
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
        if ($SelectedCount.Value -ge $MaxJobFiles) { return }
        if (-not $EligiblePathSet.ContainsKey($file.FullName.ToUpperInvariant())) { continue }

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

    if ($CurrentDepth -ge $MaxFolderDepth) { return }

    foreach ($dir in $childDirs) {
        if ($SelectedCount.Value -ge $MaxJobFiles) { return }
        if ($dir.Name.StartsWith('.', [StringComparison]::Ordinal)) { continue }

        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $dir.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source ($($dir.Name))"

        Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $dir.FullName -SourceRootPath $SourceRootPath `
            -SelectedCount $SelectedCount -SelectedNames $SelectedNames -EligiblePathSet $EligiblePathSet `
            -MaxJobFiles $MaxJobFiles -CurrentDepth ($CurrentDepth + 1)

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

function Test-SanitizationQuiescent {
    param($Status)

    if ($null -eq $Status) { return $false }
    if ([string]$Status.state -eq 'idle') { return $true }
    if ([string]$Status.state -eq 'complete') {
        $running = 0
        if ($Status.counts -and $null -ne $Status.counts.PSObject.Properties['running']) {
            $running = [int]$Status.counts.running
        }
        if ($running -eq 0 -and $Status.sanitizationFinished -eq $true) {
            return $true
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
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "sanitization.status did not reach quiescent state within ${TimeoutSec}s ($Context)."
}

function Test-Sa09AcceptableOutcome {
    param($FileEntry)

    $outcome = if ($FileEntry.PSObject.Properties['outcome']) { [string]$FileEntry.outcome } else { '' }
    $friendly = if ($FileEntry.PSObject.Properties['outcomeFriendly']) { [string]$FileEntry.outcomeFriendly } else { '' }
    $tokens = @($outcome, $friendly) | ForEach-Object { $_.Trim().ToLowerInvariant() }

    foreach ($token in $tokens) {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        if ($token -match 'pass|passed|modified|reconstruct|reconstructed|outcomepass|outcomemodified|outcomereconstructed') {
            return $true
        }
    }
    return $false
}

function Assert-Sa09SanitizationJobComplete {
    param(
        [string] $Exe,
        $FinalStatus,
        [int] $ExpectedSelected,
        [string] $RouteLabel,
        [string] $DestinationDiskFolder,
        [ref] $SawPassOutcome,
        [ref] $SawModifiedOutcome
    )

    $selected = [int]$FinalStatus.counts.selected
    $passed = [int]$FinalStatus.counts.passed
    $blocked = [int]$FinalStatus.counts.blocked
    $running = [int]$FinalStatus.counts.running

    Write-TestStep "$RouteLabel final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne $ExpectedSelected) {
        throw "$RouteLabel counts.selected ($selected) does not match UI selection ($ExpectedSelected)."
    }
    if ($running -ne 0) {
        throw "$RouteLabel expected no running items after completion; running=$running"
    }
    if (($passed + $blocked) -ne $selected) {
        throw "$RouteLabel passed+blocked ($($passed + $blocked)) does not match selected ($selected)."
    }

    $files = @(Get-SanitizationFileEntries -FilesProperty $FinalStatus.files)
    $fileCount = Get-CollectionCount $files

    if ($blocked -gt 0) {
        $blockedNames = @($files | Where-Object {
                $o = if ($_.outcome) { [string]$_.outcome } else { '' }
                $f = if ($_.outcomeFriendly) { [string]$_.outcomeFriendly } else { '' }
                ($o + ' ' + $f) -match 'block|reject|fail'
            } | ForEach-Object { if ($_.name) { [string]$_.name } else { '(unknown)' } })
        $blockedList = if ($blockedNames.Count -gt 0) { ($blockedNames -join ', ') } else { '(names not in files[])' }
        throw "$RouteLabel had $blocked blocked file(s) (expected Pass/Modified only). blocked names: $blockedList"
    }

    if ($fileCount -ne $selected -and $fileCount -gt 0) {
        Write-TestStep "$RouteLabel sanitization.status files[] lists $fileCount of $selected selected file(s); counts passed=$passed blocked=$blocked."
    }
    if ($fileCount -gt 0 -and $fileCount -ne $selected) {
        if (($passed + $blocked) -ne $selected) {
            throw "$RouteLabel files[] count ($fileCount) does not match selected ($selected) and passed+blocked ($($passed + $blocked)) also mismatches."
        }
    }
    elseif ($fileCount -eq 0 -and $selected -gt 0) {
        if ($passed -gt 0) {
            Write-TestStep "$RouteLabel sanitization.status has empty files[] but counts show passed=$passed (accepting counts)."
            $SawPassOutcome.Value = $true
        }
        else {
            throw "$RouteLabel sanitization.status did not include files[] after completion (selected=$selected)."
        }
    }

    foreach ($entry in $files) {
        if (-not (Test-Sa09AcceptableOutcome -FileEntry $entry)) {
            if ($blocked -eq 0 -and $passed -eq $selected) {
                Write-TestStep "$RouteLabel files[] entry missing outcome detail; counts show all passed ($passed/$selected)."
                $SawPassOutcome.Value = $true
                continue
            }
            $name = '(unknown)'
            if ($null -ne $entry -and $entry.PSObject.Properties['name']) {
                $name = [string]$entry.name
            }
            $outcome = if ($entry.PSObject.Properties['outcome']) { [string]$entry.outcome } else { '' }
            $friendly = if ($entry.PSObject.Properties['outcomeFriendly']) { [string]$entry.outcomeFriendly } else { '' }
            throw "$RouteLabel file '$name' has unacceptable outcome outcome='$outcome' friendly='$friendly'."
        }

        $outcomeText = ''
        if ($entry.PSObject.Properties['outcome']) { $outcomeText += [string]$entry.outcome }
        if ($entry.PSObject.Properties['outcomeFriendly']) { $outcomeText += ' ' + [string]$entry.outcomeFriendly }
        $outcomeText = $outcomeText.ToLowerInvariant()
        if ($outcomeText -match 'pass|passed|outcomepass') {
            $SawPassOutcome.Value = $true
        }
        if ($outcomeText -match 'modif|reconstruct') {
            $SawModifiedOutcome.Value = $true
        }
    }

    if (-not $SawPassOutcome.Value -and $passed -gt 0) {
        $SawPassOutcome.Value = $true
    }

    $destRoot = [System.IO.Path]::GetFullPath($DestinationDiskFolder)
    $destFiles = @(Get-ChildItem -LiteralPath $destRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*-lab-folder.txt' })
    if ((Get-CollectionCount $destFiles) -lt $passed) {
        throw "$RouteLabel destination '$destRoot' has $(Get-CollectionCount $destFiles) file(s) but passed=$passed."
    }

    Write-TestStep "$RouteLabel destination verification OK under '$destRoot'"
}

function Wait-Sa09SanitizationComplete {
    param(
        [string] $Exe,
        [int] $TimeoutSec,
        [int] $ExpectedSelected,
        [string] $RouteLabel,
        [string] $DestinationDiskFolder,
        [ref] $SawPassOutcome,
        [ref] $SawModifiedOutcome
    )

    Write-TestStep "Poll sanitization.status until complete ($RouteLabel), expected selected=$ExpectedSelected"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $finalStatus = $null
    $lastLoggedState = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if (Test-SanitizationQuiescent -Status $status) {
            Write-TestStep "sanitization.status quiescent ($RouteLabel): state=$($status.state)"
            $finalStatus = $status
            break
        }

        $state = [string]$status.state
        if ($state -ne $lastLoggedState) {
            $selected = ''
            $running = ''
            if ($status.counts) {
                $selected = [string]$status.counts.selected
                $running = [string]$status.counts.running
            }
            Write-TestStep "sanitization.status waiting ($RouteLabel): state=$state selected=$selected running=$running"
            $lastLoggedState = $state
        }
    }

    if (-not $finalStatus) {
        throw "$RouteLabel sanitization did not complete within $TimeoutSec seconds."
    }

    Assert-Sa09SanitizationJobComplete -Exe $Exe -FinalStatus $finalStatus -ExpectedSelected $ExpectedSelected `
        -RouteLabel $RouteLabel -DestinationDiskFolder $DestinationDiskFolder `
        -SawPassOutcome $SawPassOutcome -SawModifiedOutcome $SawModifiedOutcome

    return $finalStatus
}

function Clear-Sa09FolderContents {
    param([string] $FolderPath)

    $full = [System.IO.Path]::GetFullPath($FolderPath)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return
    }

    Write-TestStep "Clear folder contents: '$full'"
    Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -like '*-lab-folder.txt') { return }
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Copy-Sa09JobFilesToFolder {
    param(
        [string] $TargetFolder,
        [System.IO.FileInfo[]] $JobFiles
    )

    Clear-Sa09FolderContents -FolderPath $TargetFolder
    foreach ($file in $JobFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination $TargetFolder -Force
    }
}

function Get-Sa09EligibleFilesUnderAllowed {
    param(
        [string] $OverrideSource,
        [string] $FixtureRoot
    )

    $fixturesRoot = Resolve-SaTestFilesRootFolder -OverridePath $FixtureRoot
    $allowedRoot = if ([string]::IsNullOrWhiteSpace($OverrideSource)) {
        Join-Path $fixturesRoot 'Allowed'
    }
    else {
        [System.IO.Path]::GetFullPath($OverrideSource)
    }

    if (-not (Test-Path -LiteralPath $allowedRoot -PathType Container)) {
        throw "Allowed fixture folder does not exist: $allowedRoot"
    }

    $passedRoot = Join-Path $allowedRoot 'Passed'
    if (Test-Path -LiteralPath $passedRoot -PathType Container) {
        $allowedRoot = $passedRoot
        Write-TestStep "Using Allowed\Passed fixtures only for SA-09 job files (CDR-disabled pass-through lab)"
    }

    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($filePath in [System.IO.Directory]::EnumerateFiles($allowedRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $file = New-Object System.IO.FileInfo $filePath
        if (-not (Test-EligibleTestFile -File $file)) { continue }
        $list.Add($file)
    }

    $files = [System.IO.FileInfo[]]@($list | Sort-Object FullName)
    if ((Get-CollectionCount $files) -lt $MinJobFiles) {
        throw "Allowed fixtures under '$allowedRoot' have $(Get-CollectionCount $files) eligible file(s); need at least $MinJobFiles."
    }

    Write-TestStep "Fixture pool: '$allowedRoot' ($(Get-CollectionCount $files) eligible file(s))"
    return [pscustomobject]@{
        AllowedRoot = $allowedRoot
        Pool        = $files
    }
}

function Select-Sa09JobFiles {
    param([System.IO.FileInfo[]] $Pool)

    $count = if ($MaxJobFiles -le $MinJobFiles) { $MinJobFiles } else {
        Get-Random -Minimum $MinJobFiles -Maximum ($MaxJobFiles + 1)
    }
    $available = Get-CollectionCount $Pool
    if ($count -gt $available) { $count = $available }

    return @($Pool | Sort-Object { Get-Random } | Select-Object -First $count | Sort-Object FullName)
}

function Resolve-Sa09LabPolicyId {
    param(
        [string] $Exe,
        [string] $PolicyName,
        [int] $OverridePolicyId
    )

    if ($OverridePolicyId -gt 0) {
        return $OverridePolicyId
    }

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list (resolve SA-09 lab policy)'
    $match = @($policyList.policies | Where-Object { [string]$_.name -eq $PolicyName })
    if ((Get-CollectionCount $match) -lt 1) {
        throw "Policy '$PolicyName' not found in policy.list."
    }
    return [int]$match[0].id
}

function Invoke-Sa09SelectCorePolicy {
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

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy select ($Label): $($ready.StdOut)"
    }
}

function Invoke-Sa09SanitizeRoute {
    param(
        [string] $Exe,
        [string] $RouteLabel,
        [string] $SourceRootUi,
        [string] $SourceDiskPath,
        [string] $DestRootUi,
        [string] $DestDiskPath,
        [string] $DestinationOnDiskFolder,
        [System.IO.FileInfo[]] $JobFiles,
        [ref] $SawPassOutcome,
        [ref] $SawModifiedOutcome
    )

    $expectedCount = Get-CollectionCount $JobFiles
    $eligiblePathSet = @{}
    $sourceDiskRoot = [System.IO.Path]::GetFullPath($SourceDiskPath)
    foreach ($f in $JobFiles) {
        $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
        $stagedPath = [System.IO.Path]::GetFullPath((Join-Path $sourceDiskRoot $f.Name))
        $eligiblePathSet[$stagedPath.ToUpperInvariant()] = $true
    }

    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context "before $RouteLabel"

    $sourceSegments = @()
    if ($SourceRootUi -match '^[A-Za-z]:$') {
        $sourceSegments = Get-FolderSegmentsFromDrive -FolderPath $SourceDiskPath
    }

    $destSegments = @()
    if ($DestRootUi -match '^[A-Za-z]:$') {
        $destSegments = Get-FolderSegmentsFromDrive -FolderPath $DestDiskPath
    }

    Write-TestStep "selectSource root '$SourceRootUi' ($RouteLabel)"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $SourceRootUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "selectSource ($RouteLabel)"
    if ((Get-CollectionCount $sourceSegments) -gt 0) {
        Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix "Source ($RouteLabel)"
    }
    elseif ($SourceRootUi -notmatch '^[A-Za-z]:$') {
        Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "refresh SMB source ($RouteLabel)"
    }

    Write-TestStep "selectDestination root '$DestRootUi' ($RouteLabel)"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $DestRootUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "selectDestination ($RouteLabel)"
    if ((Get-CollectionCount $destSegments) -gt 0) {
        Invoke-NavigateDestinationSegments -Exe $Exe -Segments $destSegments -StepPrefix "Destination ($RouteLabel)"
    }

    Write-TestStep "Return to source for selection ($RouteLabel)"
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $SourceRootUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step "selectSource before selection ($RouteLabel)"
    if ((Get-CollectionCount $sourceSegments) -gt 0) {
        Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix "Source selection ($RouteLabel)"
    }
    elseif ($SourceRootUi -notmatch '^[A-Za-z]:$') {
        Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "refresh SMB source before selection ($RouteLabel)"
    }

    Write-TestStep "clearSelection ($RouteLabel)"
    $clear = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step "clearSelection ($RouteLabel)"

    $uiSelectedCount = 0
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount

    Write-TestStep "Recursive UI selection ($RouteLabel, target=$expectedCount file(s))"
    Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $SourceDiskPath -SourceRootPath $SourceDiskPath `
        -SelectedCount $selectedCountRef -SelectedNames $selectedNames -EligiblePathSet $eligiblePathSet `
        -MaxJobFiles $expectedCount

    if ($uiSelectedCount -ne $expectedCount) {
        throw "$RouteLabel UI selection count ($uiSelectedCount) does not match job file count ($expectedCount)."
    }

    Write-TestStep "startSanitization ($RouteLabel, selected=$uiSelectedCount)"
    $start = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step "startSanitization ($RouteLabel)"

    $null = Wait-Sa09SanitizationComplete -Exe $Exe -TimeoutSec $SanitizePollSec -ExpectedSelected $expectedCount `
        -RouteLabel $RouteLabel -DestinationDiskFolder $DestinationOnDiskFolder `
        -SawPassOutcome $SawPassOutcome -SawModifiedOutcome $SawModifiedOutcome

    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context "after $RouteLabel"
}

function Remove-Sa09DestinationArtifacts {
    param([string[]] $Folders)

    foreach ($folder in @($Folders | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        try {
            Clear-Sa09FolderContents -FolderPath $folder
        }
        catch {
            Write-Warning "Teardown could not clear '$folder': $($_.Exception.Message)"
        }
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-09'

    if ($MinJobFiles -lt 1) { throw '-MinJobFiles must be at least 1.' }
    if ($MaxJobFiles -lt $MinJobFiles) {
        throw "-MaxJobFiles ($MaxJobFiles) must be >= -MinJobFiles ($MinJobFiles)."
    }

    $fixturePick = Get-Sa09EligibleFilesUnderAllowed -OverrideSource $SourceFolder -FixtureRoot $TestFilesRoot
    $jobFiles = Select-Sa09JobFiles -Pool $fixturePick.Pool
    Write-TestStep "Job file set: $(Get-CollectionCount $jobFiles) file(s) from Allowed fixtures"

    $smbIn = $script:Sa09SmbInFolder
    $smbOut = $script:Sa09SmbOutFolder
    $localOut = $script:Sa09LocalOutFolder
    $smbStoreIn = $script:Sa09SmbStoreIn
    $smbStoreOut = $script:Sa09SmbStoreOut
    $script:Sa09DestinationFolders = @($smbOut, $localOut)

    Clear-Sa09FolderContents -FolderPath $smbIn
    Clear-Sa09FolderContents -FolderPath $smbOut
    Clear-Sa09FolderContents -FolderPath $localOut

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    Write-TestStep 'ping debug pipe'
    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    Write-TestStep 'gateway.status (poll Core connect)'
    $gateway = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 120 -Context 'before SA-09 scenario' -NudgeReconnect
    Assert-OkResponse -Response $gateway -Step 'gateway.status'

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: pushpolicystate (snapshot current policies and assignment rules)'
        $corePush = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
        $script:Sa09CorePolicyStackPushed = $true
        $script:Sa09CoreDebugHookUrl = $corePush.HookUrl

        Write-TestStep "Core: importpolicies ($CorePolicyName - Local+SMB source/destination); commdown/commup"
        $coreImport = Import-ScanAgentSa09CoreDebugPolicy -HookUrl $script:Sa09CoreDebugHookUrl -Exe $exe `
            -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
            -PolicyName $CorePolicyName -UiWaitMs $UiWaitMs
        Write-TestStep "Core importpolicies OK (policyBase='$($coreImport.PolicyBaseSource)'; lab policy: all file types allowed, CDR/transformations disabled)"
    }

    $policyCurrentStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrentStart -Step 'policy.current (initial)'
    $script:OriginalPolicyId = [int]$policyCurrentStart.policy.id

    $script:Sa09LabPolicyId = Resolve-Sa09LabPolicyId -Exe $exe -PolicyName $CorePolicyName -OverridePolicyId $PolicyId
    Invoke-Sa09SelectCorePolicy -Exe $exe -PolicyId $script:Sa09LabPolicyId -Label "$CorePolicyName (SA-09 lab)"

    $listSources = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSources')
    Assert-OkResponse -Response $listSources -Step 'listSources (SA-09 policy roots)'
    $sourceRootNames = @($listSources.roots | ForEach-Object { [string]$_.name })
    Write-TestStep "Policy source roots: $($sourceRootNames -join ', ')"

    $listDestinations = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listDestinations')
    Assert-OkResponse -Response $listDestinations -Step 'listDestinations (SA-09 policy roots)'
    $destRootNames = @($listDestinations.roots | ForEach-Object { [string]$_.name })
    Write-TestStep "Policy destination roots: $($destRootNames -join ', ')"

    if ($sourceRootNames -notcontains $smbStoreIn) {
        throw "listSources missing SMB store '$smbStoreIn' required for SA-09."
    }
    if ($destRootNames -notcontains $smbStoreOut) {
        throw "listDestinations missing SMB store '$smbStoreOut' required for SA-09."
    }

    $localDriveUi = Get-DriveRootUiName -FolderPath $fixturePick.AllowedRoot
    if ($sourceRootNames -notcontains $localDriveUi) {
        throw "listSources missing local drive '$localDriveUi' required for Local->SMB route."
    }
    if ($destRootNames -notcontains $localDriveUi) {
        throw "listDestinations missing local drive '$localDriveUi' required for SMB->Local route."
    }

    $sawPass = $false
    $sawModified = $false
    $sawPassRef = [ref] $sawPass
    $sawModifiedRef = [ref] $sawModified

    Write-TestStep '=== SA-09 Route 1: Local->SMB ==='
    Invoke-Sa09SanitizeRoute -Exe $exe -RouteLabel 'Local->SMB' `
        -SourceRootUi $localDriveUi -SourceDiskPath $fixturePick.AllowedRoot `
        -DestRootUi $smbStoreOut -DestDiskPath $smbOut -DestinationOnDiskFolder $smbOut `
        -JobFiles $jobFiles -SawPassOutcome $sawPassRef -SawModifiedOutcome $sawModifiedRef

    Write-TestStep '=== SA-09 Route 2: SMB->Local ==='
    Copy-Sa09JobFilesToFolder -TargetFolder $smbIn -JobFiles $jobFiles
    Clear-Sa09FolderContents -FolderPath $localOut
    Invoke-Sa09SanitizeRoute -Exe $exe -RouteLabel 'SMB->Local' `
        -SourceRootUi $smbStoreIn -SourceDiskPath $smbIn `
        -DestRootUi $localDriveUi -DestDiskPath $localOut -DestinationOnDiskFolder $localOut `
        -JobFiles $jobFiles -SawPassOutcome $sawPassRef -SawModifiedOutcome $sawModifiedRef

    Write-TestStep '=== SA-09 Route 3: SMB->SMB ==='
    Copy-Sa09JobFilesToFolder -TargetFolder $smbIn -JobFiles $jobFiles
    Clear-Sa09FolderContents -FolderPath $smbOut
    Invoke-Sa09SanitizeRoute -Exe $exe -RouteLabel 'SMB->SMB' `
        -SourceRootUi $smbStoreIn -SourceDiskPath $smbIn `
        -DestRootUi $smbStoreOut -DestDiskPath $smbOut -DestinationOnDiskFolder $smbOut `
        -JobFiles $jobFiles -SawPassOutcome $sawPassRef -SawModifiedOutcome $sawModifiedRef

    if (-not $sawPass) {
        Write-TestStep 'Note: no explicit Pass outcome token seen; Pass/Modified assertion satisfied if Modified/Reconstructed only.'
    }
    if (-not $sawModified -and -not $sawPass) {
        throw 'SA-09 expected at least Pass or Modified/Reconstructed outcomes across the three routes; none were recorded.'
    }

    if ($script:OriginalPolicyId -ne $script:Sa09LabPolicyId) {
        Write-TestStep "Restore original policy id $($script:OriginalPolicyId)"
        Invoke-Sa09SelectCorePolicy -Exe $exe -PolicyId $script:OriginalPolicyId -Label 'Original policy restore'
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
    if ($script:Sa09CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Sa09CoreDebugHookUrl)) {
        try {
            Write-TestStep 'Core: poppolicystate (restore pre-test policies and assignment rules)'
            Restore-ScanAgentSa05CorePolicyStack -HookUrl $script:Sa09CoreDebugHookUrl | Out-Null
        }
        catch {
            Write-Warning "Core poppolicystate failed: $($_.Exception.Message)"
        }
    }

    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed) {
        foreach ($folder in $script:Sa09DestinationFolders) {
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                $evidenceOnFailure += $folder
            }
        }
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-09' -TestTitle 'SMB local same Core path Local SMB routes' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:ScenarioPassed) {
        try {
            Remove-Sa09DestinationArtifacts -Folders $script:Sa09DestinationFolders
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
