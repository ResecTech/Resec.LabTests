#Requires -Version 5.1
<#
.SYNOPSIS
  SA-07: Encrypted file password dialog (single cancel, single submit + sanitize, multi-file dialog).

.DESCRIPTION
  Stages Resec.LabTests\Fixtures\Blocked\Encrypted under C:\test\SA-07-src (including a nested subfolder for
  recursive UI walks). Exercises password modal via ScanAgentDebug:
    - select encrypted file -> modal -> cancel -> observe sanitization.status (no job starts without password)
    - select all staged encrypted files (root + subfolders), submit per-file passwords, sanitize entire job folder

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled = true and gateway connected.
    - Core REST debug hooks enabled (EnableDebugInterface) for default policy lab setup.
    - WebMC export XML with a Scan Agent template policy (optional -PolicyTemplateXml; default is embedded lab policy in ScanAgentE2eEmbeddedPolicyBase.ps1).

  Default Core setup (unless -SkipCorePolicySetup): GET pushpolicystate (snapshot DB policies + rules),
  POST importpolicies (policy Test7-password with Local Source + Local Destination + scan_agent rule),
  GET commdown (disconnect all agents, 5s hold), GET commup, then GET poppolicystate in finally.
  See Core docs/core-debug-api.md.

.NOTES
  Test plan: SA-07 — encrypted file password dialog (single + multi).
  Exit 0 = passed; destination folder removed on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $TestFilesRoot = '',
    [string] $EncryptedFixtureFolder = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyBaseRaw = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $CorePolicyName = 'Test7-password',
    [int] $PolicyId = 0,
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $PasswordDialogWaitMs = 20000,
    [int] $MaxFolderDepth = 5
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

$script:Sa07JobSourceRoot = 'C:\test\SA-07-src'
$script:Sa07MultiSubfolder = 'multi'
$script:Sa07NestedSubfolder = 'nested\deep'
$script:Sa07CorePolicyStackPushed = $false
$script:Sa07CoreDebugHookUrl = $null
$script:OriginalPolicyId = $null
$script:Sa07LabPolicyId = $null
$script:TestFileMaxBytes = 5MB

$exe = $null
$destinationPath = $null
$jobSourcePath = $null

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

function Get-DriveRootUiName {
    param([string] $FolderPath)
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($FolderPath))
    return $root.TrimEnd('\')
}

function Get-FolderSegmentsFromDrive {
    param([string] $FolderPath)
    $full = [System.IO.Path]::GetFullPath($FolderPath)
    $driveRoot = [System.IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($driveRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) { return @() }
    return @($relative.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
}

function Invoke-NavigateSourceSegments {
    param(
        [string] $Exe,
        [string[]] $Segments,
        [string] $StepPrefix
    )

    foreach ($segment in @($Segments)) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $segment, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}

function Invoke-Sa07NavigateSourceToPath {
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

function Invoke-Sa07NavigateDestinationToPath {
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
    Invoke-ScanAgentE2eRefreshDestinationContent -Exe $Exe -StepLabel "$StepLabel refreshDestinationContent"
}

function Get-MainContentRoot {
    param($Payload)
    if ($null -eq $Payload) { throw 'ui.mainContent response is null.' }
    if ($Payload.PSObject.Properties['mainContent'] -and $null -ne $Payload.mainContent) {
        return $Payload.mainContent
    }
    return $Payload
}

function Get-CanStartSanitizationFromMain {
    param($MainPayload)
    $main = Get-MainContentRoot -Payload $MainPayload
    return ($main.canStartSanitization -eq $true)
}

function Invoke-PasswordDialogStatus {
    param([string] $Exe)
    return Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'passwordDialogStatus')
}

function Wait-PasswordDialogOpen {
    param(
        [string] $Exe,
        [string] $Context,
        [int] $ExpectedFileCount = 0,
        [int] $TimeoutMs = 20000
    )

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-PasswordDialogStatus -Exe $Exe
        Assert-OkResponse -Response $status -Step "passwordDialogStatus ($Context)"
        if ($status.isOpen -eq $true) {
            $count = if ($null -ne $status.fileCount) { [int]$status.fileCount } else { 0 }
            if ($ExpectedFileCount -gt 0 -and $count -ne $ExpectedFileCount) {
                Start-Sleep -Milliseconds 300
                continue
            }
            Write-TestStep "Password modal open ($Context); fileCount=$count"
            return $status
        }
        Start-Sleep -Milliseconds 300
    }

    throw "Password modal did not open within ${TimeoutMs}ms ($Context)."
}

function Invoke-CancelPasswordDialog {
    param([string] $Exe, [string] $Context)
    Write-TestStep "cancelPasswordDialog ($Context)"
    $cancel = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'cancelPasswordDialog', '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $cancel -Step "cancelPasswordDialog ($Context)"
    $after = Invoke-PasswordDialogStatus -Exe $Exe
    Assert-OkResponse -Response $after -Step "passwordDialogStatus after cancel ($Context)"
    if ($after.isOpen -eq $true) {
        throw "Password modal still open after cancel ($Context)."
    }
}

function Invoke-SubmitPasswordDialog {
    param(
        [string] $Exe,
        [string] $Password,
        [string] $Context
    )

    Write-TestStep "submitPasswordDialog ($Context) password length=$($Password.Length)"
    $submit = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'submitPasswordDialog', '--password', $Password, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $submit -Step "submitPasswordDialog ($Context)"
}

function Assert-CanStartSanitization {
    param(
        [string] $Exe,
        [bool] $Expected,
        [string] $Context
    )

    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step "ui.mainContent ($Context)"
    $actual = Get-CanStartSanitizationFromMain -MainPayload $main
    if ($actual -ne $Expected) {
        throw "${Context}: expected canStartSanitization=$Expected, got $actual."
    }
    Write-TestStep "${Context}: canStartSanitization=$actual (OK)"
}

function Assert-StartSanitizationBlocked {
    param([string] $Exe, [string] $Context)

    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
        try { $parsed = $result.StdOut.Trim() | ConvertFrom-Json } catch { }
    }
    if ($null -ne $parsed -and $parsed.ok -eq $true) {
        throw "${Context}: startSanitization succeeded but was expected to be blocked."
    }
    Write-TestStep "${Context}: startSanitization not available (OK)"
}

function Assert-Sa07PasswordCancelDoesNotStartSanitization {
    param(
        [string] $Exe,
        [string] $Context,
        [int] $SettleSec = 5
    )

    Write-TestStep "${Context}: after Cancel, sanitization must not run (observe status; no startSanitization probe)"
    $baseline = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
    Assert-OkResponse -Response $baseline -Step "sanitization.status ($Context baseline)"
    if ($baseline.inProgress -eq $true -or [int]$baseline.counts.running -gt 0 -or [string]$baseline.state -eq 'running') {
        throw "${Context}: job already running immediately after Cancel."
    }

    $passedBase = [int]$baseline.counts.passed
    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step "ui.mainContent ($Context after Cancel)"
    $canStart = Get-CanStartSanitizationFromMain -MainPayload $main
    if ($canStart) {
        Write-TestStep "${Context}: canStartSanitization=true after Cancel; still expect no job until password submit (poll only)."
    }
    else {
        Write-TestStep "${Context}: canStartSanitization=false after Cancel (OK)"
    }

    $deadline = [datetime]::UtcNow.AddSeconds($SettleSec)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step "sanitization.status ($Context settle poll)"

        if ($status.inProgress -eq $true -or [int]$status.counts.running -gt 0 -or [string]$status.state -eq 'running') {
            throw "${Context}: sanitization started after Cancel without password submit (inProgress/running)."
        }

        if ([int]$status.counts.passed -gt $passedBase) {
            throw "${Context}: counts.passed increased ($passedBase -> $($status.counts.passed)) after Cancel without submit."
        }
    }

    Write-TestStep "${Context}: no sanitization activity after Cancel within ${SettleSec}s (OK)"
    Invoke-Sa07ClearSourceSelection -Exe $Exe
}

function Get-Sa07PasswordForFileName {
    param([string] $FileName)
    if ($FileName -match 'password=([^.\s]+)') {
        return $Matches[1]
    }
    return '1111'
}

function Resolve-Sa07EncryptedFixtureFolder {
    if (-not [string]::IsNullOrWhiteSpace($EncryptedFixtureFolder)) {
        $explicit = [System.IO.Path]::GetFullPath($EncryptedFixtureFolder)
        if (-not (Test-Path -LiteralPath $explicit -PathType Container)) {
            throw "Encrypted fixture folder does not exist: $explicit"
        }
        return $explicit
    }

    $fixturesRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRoot
    foreach ($name in @('Encrypted', 'Enchrypted')) {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $fixturesRoot "Blocked\$name"))
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    throw "Could not find Blocked\Encrypted under fixture root '$fixturesRoot'. Pass -EncryptedFixtureFolder."
}

function Initialize-Sa07JobSourceTree {
    param(
        [string] $EncryptedSourceFolder,
        [string] $JobRoot
    )

    $jobRoot = [System.IO.Path]::GetFullPath($JobRoot)
    if (Test-Path -LiteralPath $jobRoot) {
        Remove-Item -LiteralPath $jobRoot -Recurse -Force
    }
    [void][System.IO.Directory]::CreateDirectory($jobRoot)

    $files = @(Get-ChildItem -LiteralPath $EncryptedSourceFolder -File -Force | Sort-Object Name)
    if ($files.Count -lt 2) {
        throw "SA-07 needs at least two encrypted fixtures under '$EncryptedSourceFolder'."
    }

    foreach ($file in $files) {
        if ($file.Length -gt $script:TestFileMaxBytes) { continue }
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $jobRoot $file.Name) -Force
    }

    $multiDir = Join-Path $jobRoot $script:Sa07MultiSubfolder
    [void][System.IO.Directory]::CreateDirectory($multiDir)
    $multiNames = @('1111.7z', '1111.rar')
    foreach ($name in $multiNames) {
        $src = Join-Path $EncryptedSourceFolder $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "SA-07 multi-file phase requires fixture '$name' under '$EncryptedSourceFolder'."
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $multiDir $name) -Force
    }

    $nestedDir = Join-Path $jobRoot $script:Sa07NestedSubfolder
    [void][System.IO.Directory]::CreateDirectory($nestedDir)
    $nestedSrc = $files | Where-Object { $_.Name -ne '1111.7z' -and $_.Name -ne '1111.rar' } | Select-Object -First 1
    if ($null -eq $nestedSrc) {
        $nestedSrc = $files[0]
    }
    Copy-Item -LiteralPath $nestedSrc.FullName -Destination (Join-Path $nestedDir $nestedSrc.Name) -Force

    $onDisk = @(Get-ChildItem -LiteralPath $jobRoot -File -Recurse -Force)
    Write-TestStep "Staged $($onDisk.Count) encrypted file(s) under '$jobRoot' (includes multi/ and nested/deep/)."
    return [pscustomobject]@{
        JobRoot     = $jobRoot
        OnDiskFiles = $onDisk
        CancelFile  = '1111.7z'
        MultiFolder = $multiDir
    }
}

function Invoke-Sa07SelectAllStagedFilesWithPasswords {
    param(
        [string] $Exe,
        [string] $JobRootPath,
        [array] $OnDiskFiles,
        [int] $MaxFolderDepth
    )

    $eligiblePathSet = @{}
    foreach ($f in @($OnDiskFiles)) {
        $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true
    }

    $selectedCount = 0
    $selectedNames = @{}
    Select-Sa07SourceFilesRecursiveWithPasswords -Exe $Exe -DiskFolderPath $JobRootPath -SourceRootPath $JobRootPath `
        -EligiblePathSet $eligiblePathSet -SelectedCount ([ref]$selectedCount) -SelectedNames $selectedNames `
        -MaxFolderDepth $MaxFolderDepth

    return [pscustomobject]@{
        ExpectedCount  = (Get-CollectionCount @($OnDiskFiles))
        SelectedCount  = $selectedCount
    }
}

function Invoke-Sa07ClearSourceSelection {
    param([string] $Exe)
    Write-TestStep 'clearSelection on source'
    $clear = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'
}

function Invoke-Sa07SelectSourceFileByName {
    param(
        [string] $Exe,
        [string] $FileName
    )

    Write-TestStep "selectSourceFile '$FileName'"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSourceFile', '--name', $FileName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $select -Step "selectSourceFile ($FileName)"
}

function Wait-SanitizationTerminal {
    param(
        [string] $Exe,
        [int] $ExpectedSelected,
        [string] $Context
    )

    Write-TestStep "Poll sanitization.status up to $SanitizePollSec seconds ($Context)"
    $deadline = [datetime]::UtcNow.AddSeconds($SanitizePollSec)
    $finalStatus = $null

    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        if ($status.state -eq 'complete' -or (
                $status.state -eq 'idle' -and $status.inProgress -eq $false -and $status.sanitizationFinished -eq $true)) {
            $finalStatus = $status
            break
        }

        Write-Host "  state=$($status.state) selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
    }

    if (-not $finalStatus) {
        throw "Sanitization did not complete within $SanitizePollSec seconds ($Context)."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running

    Write-TestStep "$Context final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne $ExpectedSelected) {
        throw "${Context}: counts.selected ($selected) != expected $ExpectedSelected."
    }
    if ($running -ne 0) {
        throw "${Context}: expected running=0 after completion; running=$running."
    }
    if ($passed -ne $ExpectedSelected) {
        throw "${Context}: expected counts.passed=$ExpectedSelected; passed=$passed blocked=$blocked."
    }

    return $finalStatus
}

function Assert-DestinationHasSanitizedFiles {
    param(
        [string] $DestinationRoot,
        [int] $MinimumFileCount
    )

    $destRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (-not (Test-Path -LiteralPath $destRoot -PathType Container)) {
        throw "Destination folder missing: $destRoot"
    }

    $files = @(Get-ChildItem -LiteralPath $destRoot -File -Recurse -Force)
    if ($files.Count -lt $MinimumFileCount) {
        throw "Expected at least $MinimumFileCount destination file(s) under '$destRoot'; found $($files.Count)."
    }

    foreach ($file in $files) {
        if ($file.Name -match '[\\/:*?"<>|]') {
            throw "Invalid destination file name on disk: '$($file.FullName)'"
        }
    }

    Write-TestStep "Destination has $($files.Count) on-disk file(s) under '$destRoot' with valid names."
}

function Resolve-Sa07LabPolicyId {
    param(
        [string] $Exe,
        [string] $PolicyName,
        [int] $OverridePolicyId
    )

    if ($OverridePolicyId -gt 0) {
        return $OverridePolicyId
    }

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list (resolve SA-07 lab policy)'
    $match = @($policyList.policies | Where-Object { [string]$_.name -eq $PolicyName })
    if ($match.Count -lt 1) {
        throw "Policy '$PolicyName' not found in policy.list."
    }

    return [int]$match[0].id
}

function Invoke-Sa07SelectCorePolicy {
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

    Write-TestStep "waitReady after policy select ($Label)"
    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy select '$Label' (exit $($ready.ExitCode)): $($ready.StdOut)"
    }

    $ping = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step "ping after policy select ($Label)"
    if ($ping.message -and $ping.message -ne 'pong') {
        throw "Unexpected ping after policy select ($Label): $($ping.message)"
    }
}

function Invoke-Sa07RunSanitizeJob {
    param(
        [string] $Exe,
        [int] $ExpectedFiles,
        [string] $Context
    )

    Assert-CanStartSanitization -Exe $Exe -Expected $true -Context "$Context pre-start"
    Write-TestStep "startSanitization ($Context, $ExpectedFiles file(s))"
    $start = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step "startSanitization ($Context)"

    $null = Wait-SanitizationTerminal -Exe $Exe -ExpectedSelected $ExpectedFiles -Context $Context
    return $true
}

function Get-RelativeFolderDepthFromRoot {
    param([string] $RootFolder, [string] $Path)
    $root = [System.IO.Path]::GetFullPath($RootFolder)
    if (-not $root.EndsWith('\')) { $root += '\' }
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return [int]::MaxValue }
    $relative = $full.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relative)) { return 0 }
    $dirPart = [System.IO.Path]::GetDirectoryName($relative)
    if ([string]::IsNullOrWhiteSpace($dirPart)) { return 0 }
    return @($dirPart.Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries)).Count
}

function Invoke-Sa07SubmitPasswordDialogIfOpen {
    param(
        [string] $Exe,
        [string] $FileName,
        [string] $Context
    )

    $status = Invoke-PasswordDialogStatus -Exe $Exe
    Assert-OkResponse -Response $status -Step "passwordDialogStatus ($Context)"
    if ($status.isOpen -ne $true) {
        return $false
    }

    $password = Get-Sa07PasswordForFileName -FileName $FileName
    Invoke-SubmitPasswordDialog -Exe $Exe -Password $password -Context "$Context '$FileName'"
    return $true
}

function Select-Sa07SourceFilesRecursiveWithPasswords {
    param(
        [string] $Exe,
        [string] $DiskFolderPath,
        [string] $SourceRootPath,
        [hashtable] $EligiblePathSet,
        [ref] $SelectedCount,
        [hashtable] $SelectedNames,
        [int] $MaxFolderDepth = 5
    )

    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $childFiles = @(Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop | Sort-Object Name)
    $childDirs = @(Get-ChildItem -LiteralPath $diskFolderPath -Directory -Force -ErrorAction Stop | Sort-Object Name)

    foreach ($file in $childFiles) {
        if (-not $EligiblePathSet.ContainsKey($file.FullName.ToUpperInvariant())) {
            Write-TestStep "Skip ineligible '$($file.Name)' in '$diskFolderPath'"
            continue
        }
        if ((Get-RelativeFolderDepthFromRoot -RootFolder $SourceRootPath -Path $file.FullName) -gt $MaxFolderDepth) {
            continue
        }

        Invoke-Sa07SelectSourceFileByName -Exe $Exe -FileName $file.Name
        $null = Invoke-Sa07SubmitPasswordDialogIfOpen -Exe $Exe -FileName $file.Name -Context 'recursive select'

        $key = $file.FullName.ToUpperInvariant()
        if ($SelectedNames.ContainsKey($key)) {
            throw "Double-selection detected: $($file.FullName)"
        }
        $SelectedNames[$key] = $true
        $SelectedCount.Value++
    }

    foreach ($dir in $childDirs) {
        if ($dir.Name.StartsWith('.', [StringComparison]::Ordinal)) {
            continue
        }
        $dirDepth = Get-RelativeFolderDepthFromRoot -RootFolder $SourceRootPath -Path $dir.FullName
        if ($dirDepth -gt $MaxFolderDepth) {
            continue
        }

        Write-TestStep "Enter subfolder '$($dir.Name)' under '$diskFolderPath'"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $dir.Name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "openFolder source ($($dir.Name))"

        Select-Sa07SourceFilesRecursiveWithPasswords -Exe $Exe -DiskFolderPath $dir.FullName -SourceRootPath $SourceRootPath `
            -EligiblePathSet $EligiblePathSet -SelectedCount $SelectedCount -SelectedNames $SelectedNames -MaxFolderDepth $MaxFolderDepth

        Write-TestStep "folderUp from '$($dir.Name)'"
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-07'

    $encryptedFixturePath = Resolve-Sa07EncryptedFixtureFolder
    Write-TestStep "Encrypted fixtures: '$encryptedFixturePath'"

    $staging = Initialize-Sa07JobSourceTree -EncryptedSourceFolder $encryptedFixturePath -JobRoot $script:Sa07JobSourceRoot
    $jobSourcePath = $staging.JobRoot

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    Write-TestStep 'ping debug pipe'
    Assert-OkResponse -Response (Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')) -Step 'ping'

    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info'
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) { Write-TestStep "Reporting componentVersion: $e2eVersion" }

    Write-TestStep 'gateway.status (poll Core connect; UI idle not required)'
    $gateway = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 120 -Context 'before SA-07 scenario' -NudgeReconnect
    Assert-OkResponse -Response $gateway -Step 'gateway.status'

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: pushpolicystate (snapshot current policies and assignment rules)'
        $corePush = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
        $script:Sa07CorePolicyStackPushed = $true
        $script:Sa07CoreDebugHookUrl = $corePush.HookUrl
        $depth = if ($corePush.PushResponse.PSObject.Properties.Name -contains 'policyStateStackDepth') {
            $corePush.PushResponse.policyStateStackDepth
        } else { '?' }
        Write-TestStep "Core pushpolicystate OK (policyStateStackDepth=$depth)"

        Write-TestStep "Core: importpolicies ($CorePolicyName + Local Source/Destination + scan_agent rule); then commdown 5s commup (disconnect all agents)"
        $coreImport = Import-ScanAgentSa07CoreDebugPolicy -HookUrl $script:Sa07CoreDebugHookUrl -Exe $exe `
            -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
            -PolicyName $CorePolicyName -UiWaitMs $UiWaitMs
        $importedCount = if ($coreImport.ImportResponse.PSObject.Properties.Name -contains 'importedPolicyCount') {
            $coreImport.ImportResponse.importedPolicyCount
        } else { '?' }
        Write-TestStep "Core importpolicies OK (policyBase='$($coreImport.PolicyBaseSource)', imported $importedCount policies; agent policy.list count=$($coreImport.AgentPolicyList.count))"
    }
    else {
        Write-TestStep 'SkipCorePolicySetup: using current agent policy (must expose local C: roots).'
    }

    $policyCurrentStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrentStart -Step 'policy.current (initial)'
    $script:OriginalPolicyId = [int]$policyCurrentStart.policy.id

    if (-not $SkipCorePolicySetup) {
        $script:Sa07LabPolicyId = Resolve-Sa07LabPolicyId -Exe $exe -PolicyName $CorePolicyName -OverridePolicyId $PolicyId
        Invoke-Sa07SelectCorePolicy -Exe $exe -PolicyId $script:Sa07LabPolicyId -Label "$CorePolicyName (SA-07 lab)"
    }

    $destinationPath = New-ScanAgentE2eTestDestinationFolder
    Write-TestStep "Destination job folder: '$destinationPath'"

    Invoke-Sa07NavigateDestinationToPath -Exe $exe -DiskPath $destinationPath -StepLabel 'Destination setup'
    Invoke-Sa07NavigateSourceToPath -Exe $exe -DiskPath $jobSourcePath -StepLabel 'Source job root'

    # --- Phase 1: cancel password on single file ---
    Write-TestStep '=== SA-07 Phase 1: select encrypted file -> password modal -> cancel -> not startable ==='
    Invoke-Sa07ClearSourceSelection -Exe $exe
    Invoke-Sa07SelectSourceFileByName -Exe $exe -FileName $staging.CancelFile
    $dialogSingle = Wait-PasswordDialogOpen -Exe $exe -Context 'single-file cancel' -ExpectedFileCount 1 -TimeoutMs $PasswordDialogWaitMs
    if ([int]$dialogSingle.fileCount -ne 1) {
        throw "Expected password dialog fileCount=1; got $($dialogSingle.fileCount)."
    }
    Invoke-CancelPasswordDialog -Exe $exe -Context 'single-file cancel'
    Assert-Sa07PasswordCancelDoesNotStartSanitization -Exe $exe -Context 'Phase 1 cancel'

    # --- Phase 2: positive — per-file passwords + sanitize all files under job source tree ---
    Write-TestStep '=== SA-07 Phase 2: submit passwords and sanitize all staged encrypted files ==='
    Invoke-Sa07ClearSourceSelection -Exe $exe
    Invoke-Sa07NavigateSourceToPath -Exe $exe -DiskPath $jobSourcePath -StepLabel 'Source job root (sanitize all)'

    $selection = Invoke-Sa07SelectAllStagedFilesWithPasswords -Exe $exe -JobRootPath $jobSourcePath `
        -OnDiskFiles @($staging.OnDiskFiles) -MaxFolderDepth $MaxFolderDepth
    if ($selection.SelectedCount -ne $selection.ExpectedCount) {
        throw "UI selected $($selection.SelectedCount) file(s); expected $($selection.ExpectedCount) under '$jobSourcePath'."
    }
    Write-TestStep "Selected $($selection.SelectedCount) encrypted file(s) with per-file password submit (matches on-disk tree)."

    Invoke-Sa07RunSanitizeJob -Exe $exe -ExpectedFiles $selection.ExpectedCount -Context 'all staged files'
    Assert-DestinationHasSanitizedFiles -DestinationRoot $destinationPath -MinimumFileCount $selection.ExpectedCount
    Invoke-Sa07ClearSourceSelection -Exe $exe

    if ($script:OriginalPolicyId -gt 0 -and $script:Sa07LabPolicyId -gt 0 -and
        $script:OriginalPolicyId -ne $script:Sa07LabPolicyId) {
        Write-TestStep "Restore original policy id $($script:OriginalPolicyId)"
        Invoke-Sa07SelectCorePolicy -Exe $exe -PolicyId $script:OriginalPolicyId -Label 'Original policy restore'
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
    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed -and $destinationPath -and (Test-Path -LiteralPath $destinationPath)) {
        $evidenceOnFailure += $destinationPath
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-07' -TestTitle 'Encrypted file password dialog single multi' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure

    if ($script:Sa07CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Sa07CoreDebugHookUrl)) {
        try {
            Write-TestStep 'Core: poppolicystate (restore pre-test policies and assignment rules)'
            Restore-ScanAgentSa05CorePolicyStack -HookUrl $script:Sa07CoreDebugHookUrl | Out-Null
        }
        catch {
            Write-Warning "Core poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed) {
        try {
            if ($destinationPath) {
                Remove-ScanAgentE2eTestDestinationFolder -DestinationFolderPath $destinationPath
            }
            if ($jobSourcePath -and (Test-Path -LiteralPath $jobSourcePath)) {
                Remove-Item -LiteralPath $jobSourcePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Error "Teardown failed after successful test: $($_.Exception.Message)"
            exit 1
        }
    }
}
