#Requires -Version 5.1
<#
.SYNOPSIS
  SA-01: Connect + sources/destinations load for the active policy.

.DESCRIPTION
  By default stops all Scan Agent processes, then first and second launch to open the UI. The test fails if
  stop or cold restart cannot complete (typical cause: run elevated, or close the agent first). Pass
  -SkipAgentRestart only for a deliberate warm-start run (no stop, no activations). Does not call
  ScanAgentDebug until after the second activation and a native UI window check (MainWindowHandle).
  Then uses ScanAgentDebug (ping, gateway, waitReady) for debug-pipe readiness.
  Verifies gateway connection, non-empty source/destination roots for the active policy, header
  connected, and incremental UI navigation reaches on-disk source (SA-TestFiles) and destination
  (C:\test\SA_TestDest_<guid>\) folders.

  After gateway connected and source/destination folders load, runs one sanitization smoke job
  (random MinJobFiles–MaxJobFiles files from anywhere under SA-TestFiles: any subfolder and file type).
  Use -SkipSanitization for connect/load only. Optional -MaxFolderDepth limits nesting (0 = no limit).

  Prerequisites:
    - DebugInterface.Enabled = true in agent appsettings.
    - Folder named SA-TestFiles on drive C:\ (optional -TestFilesRoot / -SourceFolder).

.NOTES
  Test plan: SA-01 — Agent connects; source/dest roots appear; header connected.
  See C:\Resec\Testing\SA-minimal-functional-testplan.htm
  Exit 0 = passed; C:\test destination folder removed on success.
  Exit 1 = failed; destination artifacts left intact.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $ScanAgentExe = 'C:\Program Files\Resec Technologies\Resec Scan Agent\Resec.Agent.ScanAgent.exe',
    [switch] $SkipAgentRestart,
    [switch] $SkipSanitization,
    [string] $SourceFolder = '',
    [string] $TestFilesRoot = '',
    [int] $AgentStartupTimeoutSec = 300,
    [int] $SecondActivationDelaySec = 3,
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $MaxFolderDepth = 0,
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
. (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot `
    -ScanAgentDebug $ScanAgentDebug -ScanAgentExe $ScanAgentExe
$script:TestFileMaxBytes = 5MB

$destinationPath = $null

function Write-TestStep {
    param([string] $Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [STEP] $Message"
}

function Get-CollectionCount {
    param([object] $Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Test-DirectoryExists {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [System.IO.Directory]::Exists([System.IO.Path]::GetFullPath($Path)) }
    catch { return $false }
}


function Resolve-TestSourceFolderPath {
    param(
        [string] $SourceFolderOverride = '',
        [string] $TestFilesRootOverride = ''
    )
    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRootOverride
    if (-not [string]::IsNullOrWhiteSpace($SourceFolderOverride)) {
        $sourceRoot = [System.IO.Path]::GetFullPath($SourceFolderOverride)
        if (-not (Test-DirectoryExists -Path $sourceRoot)) {
            throw "Source folder override does not exist on disk: $sourceRoot"
        }
        $saRootPrefix = $saRoot
        if (-not $saRootPrefix.EndsWith('\')) { $saRootPrefix += '\' }
        if (-not ($sourceRoot.Equals($saRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $sourceRoot.StartsWith($saRootPrefix, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Source folder '$sourceRoot' must be under SA-TestFiles root '$saRoot'."
        }
        return $sourceRoot
    }
    if (-not (Test-DirectoryExists -Path $saRoot)) {
        throw "SA-TestFiles root does not exist on disk: $saRoot"
    }
    return $saRoot
}

function Test-Sa01EligibleTestFile {
    param([System.IO.FileInfo] $File)
    if ($null -eq $File) { return $false }
    if ($File.Length -gt $script:TestFileMaxBytes) { return $false }
    return $true
}

function Test-Sa01ExceedsMaxFolderDepth {
    param(
        [string] $RootFolder,
        [string] $FileFullPath,
        [int] $MaxFolderDepth
    )
    if ($MaxFolderDepth -le 0) { return $false }
    return ((Get-RelativeFolderDepthFromRoot -RootFolder $RootFolder -FileFullPath $FileFullPath) -gt $MaxFolderDepth)
}

function Test-Sa01ShouldSkipSourceSubfolder {
    param([string] $SegmentName)
    if ([string]::IsNullOrWhiteSpace($SegmentName)) { return $true }
    return $SegmentName.StartsWith('.', [StringComparison]::Ordinal)
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
                if (-not (Test-Sa01EligibleTestFile -File $file)) { continue }
                if (Test-Sa01ExceedsMaxFolderDepth -RootFolder $root -FileFullPath $file.FullName -MaxFolderDepth $MaxFolderDepth) { continue }
                $list.Add($file)
            }
            catch { }
        }
    }
    catch { }
    return [System.IO.FileInfo[]]@($list | Sort-Object FullName)
}

function Format-ScanAgentDebugCommandLine {
    param([string[]] $Arguments)
    $parts = @()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) { continue }
        $text = [string] $arg
        if ($text -match '[\s"]') { $parts += '"' + ($text.Replace('"', '\"')) + '"' }
        else { $parts += $text }
    }
    return ($parts -join ' ')
}

function Invoke-ScanAgentDebug {
    param([string] $Exe, [string[]] $Arguments)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(& $Exe @Arguments 2>&1)
        foreach ($line in $lines) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $msg = $line.Exception.Message
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $line.ToString() }
                if ($msg.StartsWith('Wait:', [StringComparison]::Ordinal)) { Write-Host $msg -ForegroundColor DarkCyan }
                else { $stdoutLines.Add($msg) }
            }
            elseif ($line -is [string] -and $line.StartsWith('Wait:', [StringComparison]::Ordinal)) { Write-Host $line -ForegroundColor DarkCyan }
            else { $stdoutLines.Add([string] $line) }
        }
    }
    catch { $stdoutLines.Add($_.Exception.Message) }
    finally { $ErrorActionPreference = $savedEap }
    $exitCode = 0
    if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
    $stdout = ($stdoutLines -join [Environment]::NewLine).TrimEnd()
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = if ($stdout) { $stdout.Trim() } else { '' }; StdErr = '' }
}

function Invoke-ScanAgentDebugJson {
    param([string] $Exe, [string[]] $Arguments)
    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments $Arguments
    $commandLine = Format-ScanAgentDebugCommandLine -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdOut) { $result.StdOut } else { $result.StdErr }
        throw "ScanAgentDebug exited $($result.ExitCode): $commandLine`n$detail"
    }
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { throw "ScanAgentDebug returned no stdout: $commandLine" }
    $stdoutText = $result.StdOut.Trim()
    try { return ($stdoutText | ConvertFrom-Json) }
    catch {
        throw "ScanAgentDebug output was not JSON: $commandLine`n$stdoutText"
    }
}

function Assert-OkResponse {
    param($Response, [string] $Step)
    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "${Step} failed: $err"
    }
}

function Get-RunningScanAgentProcessSummary {
    param([string] $AgentExePath)
    $procName = Get-ScanAgentProcessName -AgentExePath $AgentExePath
    $ids = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    return [pscustomobject]@{
        Name = $procName
        Ids  = $ids
        Count = (Get-CollectionCount $ids)
    }
}

function Stop-ScanAgentProcesses {
    param([string] $AgentExePath)
    $procName = Get-ScanAgentProcessName -AgentExePath $AgentExePath
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ((Get-CollectionCount $procs) -eq 0) {
        Write-TestStep "No running '$procName' process (clean start)"
        return
    }
    Write-TestStep "Stopping $(Get-CollectionCount $procs) '$procName' process(es): $(@($procs | ForEach-Object { $_.Id }) -join ', ')"
    foreach ($proc in $procs) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        }
        catch {
            $summary = Get-RunningScanAgentProcessSummary -AgentExePath $AgentExePath
            throw @"
SA-01 Scan Agent restart failed: cannot stop process '$procName' (pid=$($proc.Id)): $($_.Exception.Message).
Still running: $($summary.Count) instance(s) [pids: $(@($summary.Ids) -join ', ')].
Cause: the test session usually lacks permission to terminate processes started elevated or in another session.
Fix: close Scan Agent from the tray, run this script from an elevated PowerShell, or use -SkipAgentRestart only when a warm start is intentional.
"@
        }
    }
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while ([datetime]::UtcNow -lt $deadline) {
        $left = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if ((Get-CollectionCount $left) -eq 0) {
            Write-TestStep "All '$procName' processes exited"
            return
        }
        Start-Sleep -Milliseconds 500
    }
    $summary = Get-RunningScanAgentProcessSummary -AgentExePath $AgentExePath
    throw "SA-01 Scan Agent restart failed: '$procName' did not exit within 45s (still running pids: $(@($summary.Ids) -join ', '))."
}

function Start-ScanAgentActivation {
    param(
        [string] $AgentExePath,
        [string] $Label
    )
    $agentFull = [System.IO.Path]::GetFullPath($AgentExePath)
    $workDir = [System.IO.Path]::GetDirectoryName($agentFull)
    Write-TestStep "Start Scan Agent ($Label): $agentFull"
    $null = Start-Process -FilePath $agentFull -WorkingDirectory $workDir -PassThru
}

function Get-ScanAgentProcessName {
    param([string] $AgentExePath)
    $agentFull = [System.IO.Path]::GetFullPath($AgentExePath)
    if (-not (Test-Path -LiteralPath $agentFull)) {
        throw "Scan Agent executable not found: $agentFull"
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($agentFull)
}

function Wait-ScanAgentProcessRunning {
    param(
        [string] $AgentExePath,
        [int] $TimeoutSec
    )
    $procName = Get-ScanAgentProcessName -AgentExePath $AgentExePath
    Write-TestStep "Wait for Scan Agent process '$procName' (no ScanAgentDebug), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
        if ((Get-CollectionCount $procs) -gt 0) {
            Write-TestStep "Scan Agent process running ($((Get-CollectionCount $procs)) instance(s))"
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Scan Agent process '$procName' did not start within ${TimeoutSec}s."
}

function Get-ScanAgentUiWindow {
    param([string] $AgentExePath)
    $procName = Get-ScanAgentProcessName -AgentExePath $AgentExePath
    foreach ($proc in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
        try {
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                return @{
                    ProcessId = $proc.Id
                    Title     = $proc.MainWindowTitle
                }
            }
        }
        catch { }
    }
    return $null
}

function Wait-ScanAgentUiWindowUp {
    param(
        [string] $AgentExePath,
        [int] $TimeoutSec,
        [string] $Context
    )
    Write-TestStep "Wait for Scan Agent UI window (no ScanAgentDebug; $Context), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $ui = Get-ScanAgentUiWindow -AgentExePath $AgentExePath
        if ($null -ne $ui) {
            $title = if ([string]::IsNullOrWhiteSpace($ui.Title)) { '(no title)' } else { $ui.Title }
            Write-TestStep "Scan Agent UI window up: pid=$($ui.ProcessId) title='$title'"
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Scan Agent UI window did not appear within ${TimeoutSec}s ($Context)."
}

function Wait-ScanAgentDebugPipeReady {
    param(
        [string] $DebugExe,
        [int] $TimeoutSec,
        [int] $WaitUiMs
    )
    Write-TestStep "Scan Agent UI is up; wait for debug pipe (ping, gateway, waitReady), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $ping = Invoke-ScanAgentDebugJson -Exe $DebugExe -Arguments @('ping')
            Assert-OkResponse -Response $ping -Step 'ping (startup wait)'
            if ($ping.message -and $ping.message -ne 'pong') {
                throw "Unexpected ping during startup: $($ping.message)"
            }
            $gateway = Invoke-ScanAgentDebugJson -Exe $DebugExe -Arguments @('gateway.status')
            Assert-OkResponse -Response $gateway -Step 'gateway.status (startup wait)'
            if ($gateway.isConnected -ne $true) {
                throw "gateway.status not connected during startup (status=$($gateway.connectionStatus))."
            }
            $ready = Invoke-ScanAgentDebug -Exe $DebugExe -Arguments @('waitReady', '--wait-ms', "$WaitUiMs", '--wait-loaded')
            if ($ready.ExitCode -ne 0) {
                throw "waitReady failed during startup (exit $($ready.ExitCode)): $($ready.StdOut)"
            }
            Write-TestStep 'Debug pipe ready (ping, gateway connected, waitReady OK)'
            return
        }
        catch {
            Write-TestStep "Debug pipe wait: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 3
    }
    throw "ScanAgentDebug did not become ready within ${TimeoutSec}s (UI window was already up)."
}

function Invoke-ScanAgentFirstAndSecondActivation {
    param(
        [string] $AgentExePath,
        [int] $SecondActivationDelaySec,
        [int] $TimeoutSec,
        [string] $Context
    )
    Start-ScanAgentActivation -AgentExePath $AgentExePath -Label 'first activation'
    Wait-ScanAgentProcessRunning -AgentExePath $AgentExePath -TimeoutSec $TimeoutSec
    if ($SecondActivationDelaySec -gt 0) {
        Write-TestStep "Pause ${SecondActivationDelaySec}s before second activation (UI)"
        Start-Sleep -Seconds $SecondActivationDelaySec
    }
    Start-ScanAgentActivation -AgentExePath $AgentExePath -Label 'second activation (UI)'
    Wait-ScanAgentUiWindowUp -AgentExePath $AgentExePath -TimeoutSec $TimeoutSec -Context $Context
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

function Invoke-NavigateSourceSegments {
    param([string] $Exe, [string[]] $Segments, [string] $StepPrefix)
    foreach ($segment in $Segments) {
        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'source', '--name', $segment, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}

function Assert-PanelRootsLoaded {
    param($ListPayload, [string] $PanelLabel)
    if ((Get-CollectionCount $ListPayload.roots) -lt 1) { throw "Empty $PanelLabel roots for active policy." }
    $accessible = @($ListPayload.roots | Where-Object { $_.isAccessible -eq $true })
    if ($accessible.Count -lt 1) { throw "No accessible $PanelLabel roots for active policy." }
    Write-TestStep "$PanelLabel roots: $(Get-CollectionCount $ListPayload.roots) total, $($accessible.Count) accessible"
}

function Assert-RootListIncludesDrive {
    param($ListPayload, [string] $DriveUiName, [string] $PanelLabel)
    $names = @($ListPayload.roots | ForEach-Object { [string] $_.name })
    if ($names -notcontains $DriveUiName) {
        throw "$PanelLabel roots do not include drive '$DriveUiName' required for on-disk test paths."
    }
}

function Assert-ListFolderPathMatches {
    param($ListPayload, [string] $ExpectedDiskPath, [string] $StepLabel)
    $folderPath = [string] $ListPayload.folder.path
    if ([string]::IsNullOrWhiteSpace($folderPath)) { throw "$StepLabel did not return folder.path." }
    $expected = [System.IO.Path]::GetFullPath($ExpectedDiskPath)
    $actual = [System.IO.Path]::GetFullPath($folderPath)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$StepLabel folder.path mismatch: expected '$expected', got '$actual'."
    }
    if ($ListPayload.folder.isLoaded -eq $false) { throw "$StepLabel folder not loaded at '$actual'." }
    Write-TestStep "$StepLabel folder loaded at '$actual' (grid items: $($ListPayload.itemCount))"
}

function Assert-PolicyAndHeaderAligned {
    param($MainContent, $PolicyCurrent, $PolicyList)
    if ($null -eq $MainContent.header) { throw 'ui.mainContent missing header object.' }
    if ($MainContent.header.isConnected -ne $true) { throw 'ui.mainContent.header.isConnected is not true.' }
    $headerPolicyId = [int]$MainContent.header.currentPolicyId
    $currentPolicyId = [int]$PolicyCurrent.policy.id
    if ($headerPolicyId -ne $currentPolicyId) {
        throw "Header currentPolicyId ($headerPolicyId) does not match policy.current id ($currentPolicyId)."
    }
    if ([int]$PolicyList.currentPolicyId -ne $currentPolicyId) {
        throw "policy.list currentPolicyId ($($PolicyList.currentPolicyId)) does not match policy.current id ($currentPolicyId)."
    }
    $currentInList = @($PolicyList.policies | Where-Object { $_.id -eq $currentPolicyId -and $_.isCurrent -eq $true })
    if ($currentInList.Count -lt 1) { throw 'Active policy is not marked isCurrent in policy.list.' }
    Write-TestStep "Active policy: id=$currentPolicyId name='$($PolicyCurrent.policy.name)'"
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
    param([string] $Exe, [int] $TimeoutSec, [string] $Context)
    Write-TestStep "Poll sanitization.status until quiescent ($Context), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $lastLoggedState = $null
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'
        if (Test-SanitizationQuiescent -Status $status) {
            Write-TestStep "sanitization.status quiescent: state=$($status.state) ($Context)"
            return
        }
        if ($status.state -eq 'running') { throw "Expected quiescent sanitization before $Context; job is running." }
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
    throw "sanitization.status did not reach quiescent state within ${TimeoutSec}s ($Context)."
}

function Get-RandomJobFileCount {
    param([int] $MinCount, [int] $MaxCount)
    if ($MinCount -gt $MaxCount) { throw "MinCount ($MinCount) cannot exceed MaxCount ($MaxCount)." }
    if ($MinCount -eq $MaxCount) { return $MinCount }
    return (Get-Random -Minimum $MinCount -Maximum ($MaxCount + 1))
}

function Select-RandomJobFilesFromPool {
    param([System.IO.FileInfo[]] $Pool, [int] $Count)
    $all = @($Pool)
    $available = Get-CollectionCount $all
    if ($Count -gt $available) { throw "Requested $Count job file(s) but only $available eligible file(s) in pool." }
    if ($Count -lt 1) { throw "Job file count must be at least 1; got $Count." }
    $shuffled = @($all | Sort-Object { Get-Random })
    return [System.IO.FileInfo[]]@($shuffled | Select-Object -First $Count | Sort-Object FullName)
}

function Wait-SanitizationComplete {
    param([string] $Exe, [int] $TimeoutSec, [int] $ExpectedSelected)
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
    if (-not $finalStatus) { throw "Sanitization did not reach complete within $TimeoutSec seconds." }
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
    if ($running -ne 0) { throw "Expected no running items after completion; running=$running" }
    if (-not $finalStatus.files) { throw 'sanitization.status did not include files[] after completion.' }
    if (@($finalStatus.files).Count -ne $selected) {
        throw "files[] count does not match counts.selected ($selected)."
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
        [int] $MaxFolderDepth,
        [int] $MaxJobFiles,
        [int] $CurrentDepth = 0
    )
    if ($SelectedCount.Value -ge $MaxJobFiles) { return }
    $diskFolderPath = [System.IO.Path]::GetFullPath($DiskFolderPath)
    $childFiles = @(Get-ChildItem -LiteralPath $diskFolderPath -File -Force -ErrorAction Stop | Sort-Object Name)
    $childDirs = @(Get-ChildItem -LiteralPath $diskFolderPath -Directory -Force -ErrorAction Stop | Sort-Object Name)
    foreach ($file in $childFiles) {
        if ($SelectedCount.Value -ge $MaxJobFiles) { return }
        if (-not $EligiblePathSet.ContainsKey($file.FullName.ToUpperInvariant())) { continue }
        if (Test-Sa01ExceedsMaxFolderDepth -RootFolder $SourceRootPath -FileFullPath $file.FullName -MaxFolderDepth $MaxFolderDepth) { continue }
        Write-TestStep "Select file '$($file.Name)' in '$diskFolderPath'"
        $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('selectSourceFile', '--name', $file.Name, '--wait-ms', "$UiWaitMs")
        Assert-OkResponse -Response $select -Step "selectSourceFile ($($file.Name))"
        $key = $file.FullName.ToUpperInvariant()
        if ($SelectedNames.ContainsKey($key)) { throw "Double-selection detected for file: $($file.FullName)" }
        $SelectedNames[$key] = $true
        $SelectedCount.Value++
    }
    if ($MaxFolderDepth -gt 0 -and $CurrentDepth -ge $MaxFolderDepth) { return }
    foreach ($dir in $childDirs) {
        if ($SelectedCount.Value -ge $MaxJobFiles) { return }
        if (Test-Sa01ShouldSkipSourceSubfolder -SegmentName $dir.Name) {
            Write-TestStep "Skip hidden subfolder '$($dir.Name)' under '$diskFolderPath'"
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
        $up = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'folderUp', '--panel', 'source', '--wait-ms', "$UiWaitMs")
        Assert-OkResponse -Response $up -Step "folderUp source ($($dir.Name))"
    }
}

function Invoke-Sa01SanitizationJob {
    param(
        [string] $Exe,
        [string] $SourcePath,
        [System.IO.FileInfo[]] $JobFiles,
        [string] $DestinationPath
    )
    $expectedFileCount = Get-CollectionCount $JobFiles
    $eligiblePathSet = @{}
    foreach ($f in $JobFiles) { $eligiblePathSet[$f.FullName.ToUpperInvariant()] = $true }
    $sourceDriveUi = Get-DriveRootUiName -FolderPath $SourcePath
    $destDriveUi = Get-DriveRootUiName -FolderPath $DestinationPath
    $sourceSegments = Get-FolderSegmentsFromDrive -FolderPath $SourcePath
    $destSegments = Get-FolderSegmentsFromDrive -FolderPath $DestinationPath
    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context 'before SA-01 sanitization job'
    Write-TestStep "selectSource root '$sourceDriveUi' (sanitization job)"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource (sanitization job)'
    Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix 'Source (job)'
    Write-TestStep "selectDestination root '$destDriveUi' (sanitization job)"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination (sanitization job)'
    Invoke-NavigateDestinationSegments -Exe $Exe -Segments $destSegments -StepPrefix 'Destination (job)'
    Write-TestStep 'Return to source folder for file selection'
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step 'selectSource before selection (job)'
    Invoke-NavigateSourceSegments -Exe $Exe -Segments $sourceSegments -StepPrefix 'Source selection (job)'
    $clear = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection (job)'
    $uiSelectedCount = 0
    $selectedNames = @{}
    $selectedCountRef = [ref] $uiSelectedCount
    Write-TestStep "Recursive UI selection (target=$expectedFileCount file(s))"
    Select-SourceFilesRecursive -Exe $Exe -DiskFolderPath $SourcePath -SourceRootPath $SourcePath `
        -SelectedCount $selectedCountRef -SelectedNames $selectedNames -EligiblePathSet $eligiblePathSet `
        -MaxFolderDepth $MaxFolderDepth -MaxJobFiles $expectedFileCount
    if ($uiSelectedCount -ne $expectedFileCount) {
        throw "UI selection count ($uiSelectedCount) does not match job file count ($expectedFileCount)."
    }
    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent before startSanitization'
    if ($main.mainContent.canStartSanitization -ne $true) {
        throw 'Start sanitization is not enabled (canStartSanitization is false).'
    }
    Write-TestStep "startSanitization (selected=$uiSelectedCount)"
    $start = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization'
    $finalStatus = Wait-SanitizationComplete -Exe $Exe -TimeoutSec $SanitizePollSec -ExpectedSelected $expectedFileCount
    Write-TestStep "Sanitization job complete (passed=$($finalStatus.counts.passed) blocked=$($finalStatus.counts.blocked))"
    if ([int]$finalStatus.counts.passed -lt 1) {
        throw "Expected at least one passed file in sanitization job; passed=$($finalStatus.counts.passed)."
    }
    Wait-SanitizationIdle -Exe $Exe -TimeoutSec $SanitizePollSec -Context 'after SA-01 sanitization job'
    return $finalStatus
}

function Get-RecursiveFileCountUnderFolder {
    param([string] $RootPath)
    $root = [System.IO.Path]::GetFullPath($RootPath)
    if (-not (Test-DirectoryExists -Path $root)) { return 0 }
    $count = 0
    try {
        foreach ($path in [System.IO.Directory]::EnumerateFiles($root, '*', [System.IO.SearchOption]::AllDirectories)) {
            $count++
        }
    }
    catch { }
    return $count
}

function Assert-DestinationTreeHasSanitizedFiles {
    param(
        [string] $DestinationRootPath,
        [int] $ExpectedPassedCount
    )
    $root = [System.IO.Path]::GetFullPath($DestinationRootPath)
    $rootOnly = @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue).Count
    $recursive = Get-RecursiveFileCountUnderFolder -RootPath $root
    $subdirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $subdirText = if ($subdirs.Count -gt 0) { ($subdirs -join ', ') } else { '(none)' }
    Write-TestStep "Destination on disk: $rootOnly file(s) at root, $recursive file(s) under tree; subfolders: $subdirText"
    if ($recursive -lt $ExpectedPassedCount) {
        throw "Expected at least $ExpectedPassedCount sanitized file(s) under destination tree '$root' (recursive count=$recursive)."
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-01'

    if ($MinJobFiles -lt 1) { throw '-MinJobFiles must be at least 1.' }
    if ($MaxJobFiles -lt $MinJobFiles) { throw "-MaxJobFiles must be >= -MinJobFiles." }
    $agentFull = [System.IO.Path]::GetFullPath($ScanAgentExe)
    if (-not (Test-Path -LiteralPath $agentFull)) {
        throw "Scan Agent executable not found: $agentFull"
    }

    if (-not $SkipAgentRestart) {
        Stop-ScanAgentProcesses -AgentExePath $ScanAgentExe
        Start-Sleep -Seconds 2
        Invoke-ScanAgentFirstAndSecondActivation -AgentExePath $ScanAgentExe `
            -SecondActivationDelaySec $SecondActivationDelaySec -TimeoutSec $AgentStartupTimeoutSec `
            -Context 'after stop; second activation'
    }
    else {
        Write-TestStep 'SkipAgentRestart: no stop and no activations'
        Wait-ScanAgentProcessRunning -AgentExePath $ScanAgentExe -TimeoutSec $AgentStartupTimeoutSec
        Wait-ScanAgentUiWindowUp -AgentExePath $ScanAgentExe -TimeoutSec $AgentStartupTimeoutSec -Context 'SkipAgentRestart'
    }

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"
    Wait-ScanAgentDebugPipeReady -DebugExe $exe -TimeoutSec $AgentStartupTimeoutSec -WaitUiMs $UiWaitMs

    Write-TestStep 'Resolve on-disk source path (SA-TestFiles)'
    $sourcePath = Resolve-TestSourceFolderPath -SourceFolderOverride $SourceFolder -TestFilesRootOverride $TestFilesRoot
    if (-not (Test-DirectoryExists -Path $sourcePath)) {
        throw "Source path does not exist on disk: $sourcePath"
    }

    $eligiblePool = Get-EligibleFilesUnderFolder -RootFolder $sourcePath -MaxFolderDepth $MaxFolderDepth
    $eligibleCount = Get-CollectionCount $eligiblePool
    $minEligible = if ($SkipSanitization) { $MinJobFiles } else { $MaxJobFiles }
    if ($eligibleCount -lt $minEligible) {
        throw "Source '$sourcePath' has $eligibleCount eligible file(s); need at least $minEligible."
    }
    Write-TestStep "Eligible fixture files under source: $eligibleCount (job sizing $MinJobFiles-$MaxJobFiles)"

    Write-TestStep 'Create destination folder under C:\test'
    $destinationPath = New-ScanAgentE2eTestDestinationFolder
    if (-not (Test-DirectoryExists -Path $destinationPath)) {
        throw "Destination path does not exist on disk: $destinationPath"
    }

    Write-TestStep "Source (on disk): '$sourcePath'"
    Write-TestStep "Destination (on disk): '$destinationPath'"

    Write-TestStep 'ping debug pipe'
    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    Write-TestStep 'agent.info (Test Platform componentVersion)'
    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info'
    Write-TestStep "Agent product=$($agentInfo.product) version=$($agentInfo.version)"
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) {
        Write-TestStep "Reporting componentVersion: $e2eVersion"
    }

    Write-TestStep 'gateway.status'
    $gateway = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('gateway.status')
    Assert-OkResponse -Response $gateway -Step 'gateway.status'
    if ($gateway.isConnected -ne $true) {
        throw "gateway.status isConnected is not true (status=$($gateway.connectionStatus))."
    }
    Write-TestStep 'Gateway connected OK'

    Write-TestStep 'ui.mainContent'
    $main = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent'

    Write-TestStep 'policy.current and policy.list'
    $policyCurrent = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrent -Step 'policy.current'
    $policyList = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list'
    Assert-PolicyAndHeaderAligned -MainContent $main -PolicyCurrent $policyCurrent -PolicyList $policyList

    if ($gateway.isConnected -ne $main.header.isConnected) {
        throw 'gateway.status.isConnected does not match ui.mainContent.header.isConnected.'
    }

    Write-TestStep 'listSources'
    $listSources = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSources')
    Assert-OkResponse -Response $listSources -Step 'listSources'
    Assert-PanelRootsLoaded -ListPayload $listSources -PanelLabel 'Source'

    Write-TestStep 'listDestinations'
    $listDestinations = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listDestinations')
    Assert-OkResponse -Response $listDestinations -Step 'listDestinations'
    Assert-PanelRootsLoaded -ListPayload $listDestinations -PanelLabel 'Destination'

    $sourceDriveUi = Get-DriveRootUiName -FolderPath $sourcePath
    $destDriveUi = Get-DriveRootUiName -FolderPath $destinationPath
    Assert-RootListIncludesDrive -ListPayload $listSources -DriveUiName $sourceDriveUi -PanelLabel 'Source'
    Assert-RootListIncludesDrive -ListPayload $listDestinations -DriveUiName $destDriveUi -PanelLabel 'Destination'

    $sourceSegments = Get-FolderSegmentsFromDrive -FolderPath $sourcePath
    $destSegments = Get-FolderSegmentsFromDrive -FolderPath $destinationPath

    Wait-SanitizationIdle -Exe $exe -TimeoutSec $SanitizePollSec -Context 'pre-navigation'

    Write-TestStep "selectSource root '$sourceDriveUi'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $sourceDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step 'selectSource'
    Invoke-NavigateSourceSegments -Exe $exe -Segments $sourceSegments -StepPrefix 'Source'

    Write-TestStep 'listSourceFiles at target source folder'
    $sourceFiles = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $sourceFiles -Step 'listSourceFiles'
    Assert-ListFolderPathMatches -ListPayload $sourceFiles -ExpectedDiskPath $sourcePath -StepLabel 'listSourceFiles'

    Write-TestStep "selectDestination root '$destDriveUi'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectDestination', '--name', $destDriveUi, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step 'selectDestination'
    Invoke-NavigateDestinationSegments -Exe $exe -Segments $destSegments -StepPrefix 'Destination'

    Write-TestStep 'listDestinationFiles at target destination folder'
    $destFiles = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listDestinationFiles')
    Assert-OkResponse -Response $destFiles -Step 'listDestinationFiles'
    Assert-ListFolderPathMatches -ListPayload $destFiles -ExpectedDiskPath $destinationPath -StepLabel 'listDestinationFiles'

    Write-TestStep 'waitReady after navigation'
    $ready = Invoke-ScanAgentDebug -Exe $exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed with exit $($ready.ExitCode): $($ready.StdOut)"
    }

    Wait-SanitizationIdle -Exe $exe -TimeoutSec $SanitizePollSec -Context 'post-navigation'

    if (-not $SkipSanitization) {
        Write-TestStep 'Connected and folders loaded; starting sanitization smoke job'
        $jobCount = Get-RandomJobFileCount -MinCount $MinJobFiles -MaxCount $MaxJobFiles
        $jobFiles = Select-RandomJobFilesFromPool -Pool $eligiblePool -Count $jobCount
        foreach ($jf in $jobFiles) {
            Write-TestStep "Job file: $($jf.FullName)"
        }
        Write-TestStep "Sanitization smoke job: $jobCount file(s) from pool of $eligibleCount (may include nested subfolders)"
        $jobStatus = Invoke-Sa01SanitizationJob -Exe $exe -SourcePath $sourcePath -JobFiles $jobFiles -DestinationPath $destinationPath
        $passedCount = [int]$jobStatus.counts.passed
        Assert-DestinationTreeHasSanitizedFiles -DestinationRootPath $destinationPath -ExpectedPassedCount $passedCount
    }
    else {
        Write-TestStep 'SkipSanitization set; connect/load only'
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
        -TestId 'SA-01' -TestTitle 'Connect sources destinations load' -Passed:$script:ScenarioPassed `
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
