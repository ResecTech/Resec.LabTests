#Requires -Version 5.1
<#
.SYNOPSIS
  SA-35 / NCP-7381: Mid-job sanitization survives a short Core comm drop (NCP-7255 continuation window).

.DESCRIPTION
  Stages a large SMB lab job (Test8-abort policy with throttled upload), pads each staged file to a lab minimum size,
  waits until sanitization has active uploads (running > 0), drops agent sessions via Core agentcommblockon for a short
  hold (default 5s, within the 30s NCP-7255 window), then re-enables admissions. Asserts the job does not terminate
  instantly with mass abort/communication failures; waits for gateway reconnect and job completion with passed outcomes
  for all selected files.

  Regression target: NCP-7381 — Scan Agent 26.2 aborts the whole job immediately on disconnect instead of
  continuing through the hidden reconnect window described in NCP-7255.

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled and gateway connected.
    - Core EnableDebugInterface (port 4504).
    - Shared Allowed fixtures (SA-TestFiles or Resec.LabTests\Fixtures).
    - Optional WebMC template XML (same as SA-05 / SA-08).

.NOTES
  Jira: NCP-7381 (related: NCP-7255).
  Exit 0 = passed; poppolicystate in finally when this script pushed policy state.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $CorePolicyName = 'Test8-abort',
    [string] $TestFilesRoot = '',
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 3600,
    [int] $MidJobWaitSec = 180,
    [int] $MinStagedJobFiles = 8,
    [long] $StagedFileMinBytes = 0,
    [int] $CommunicationUploadLimitKbps = 0,
    [int] $CoreSanitizationDelaySeconds = 15,
    [int] $CommHoldSeconds = 5,
    [int] $PostCommObserveSec = 10,
    [int] $GatewayReconnectTimeoutSec = 120,
    [int] $MaxFolderDepth = 5,
    [int] $MinSeedFiles = 5
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

$script:Ncp7381CorePolicyStackPushed = $false
$script:Ncp7381CoreDebugHookUrl = $null
$script:OriginalPolicyName = $null
$script:Sa08SmbLabSource = 'c:\test\SA-08-in'
$script:Sa08SmbLabDest = 'c:\test\SA-08-out'
$script:Sa08SmbStoreSource = 'sa08-smb-in'
$script:Sa08SmbStoreDest = 'sa08-smb-out'
$script:Sa08LocalRefreshPolicyName = 'Test8-local-refresh'
$script:TestFileMaxBytes = 5MB
$exe = $null
$jobSourcePath = $script:Sa08SmbLabSource
$destinationPath = $script:Sa08SmbLabDest

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

function Test-EligibleTestFile {
    param([System.IO.FileInfo] $File)
    if ($null -eq $File) { return $false }
    if ($File.Length -le 0 -or $File.Length -gt $script:TestFileMaxBytes) { return $false }
    $ext = $File.Extension
    if ([string]::IsNullOrWhiteSpace($ext)) { return $true }
    $blocked = @(
        '.exe', '.dll', '.com', '.scr', '.msi', '.msp', '.hta', '.jar', '.bat', '.cmd', '.ps1', '.psm1', '.psd1',
        '.ps1xml', '.vbs', '.vbe', '.js', '.jse', '.ws', '.wsf', '.wsh', '.sh', '.py', '.pyw', '.pl', '.rb', '.php',
        '.reg', '.inf', '.lnk', '.url'
    )
    return $blocked -notcontains $ext.ToLowerInvariant()
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
                $relative = $file.FullName.Substring($root.Length).TrimStart('\')
                $depth = if ([string]::IsNullOrWhiteSpace($relative)) { 0 } else {
                    @($relative.Split('\')).Count - 1
                }
                if ($depth -gt $MaxFolderDepth) { continue }
                $list.Add($file)
            }
            catch { }
        }
    }
    catch { }
    return [System.IO.FileInfo[]]@($list | Sort-Object FullName)
}

function Resolve-Ncp7381FixturePool {
    param([string] $TestFilesRootOverride, [int] $MinFiles)
    $saRoot = Resolve-SaTestFilesRootFolder -OverridePath $TestFilesRootOverride
    $candidates = @(
        (Join-Path $saRoot 'Allowed\Passed'),
        (Join-Path $saRoot 'Allowed'),
        $saRoot
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-DirectoryExists -Path $candidate)) { continue }
        $full = [System.IO.Path]::GetFullPath($candidate)
        $eligible = Get-EligibleFilesUnderFolder -RootFolder $full -MaxFolderDepth $MaxFolderDepth
        if ((Get-CollectionCount $eligible) -ge $MinFiles) {
            return @{ PoolRoot = $full; SeedFiles = $eligible }
        }
    }
    throw "No fixture folder with at least $MinFiles eligible file(s) under '$saRoot'."
}

function Clear-Ncp7381LabSourceFolder {
    param([Parameter(Mandatory)][string] $LabSourceFolder)
    if (-not (Test-DirectoryExists -Path $LabSourceFolder)) { return }
    foreach ($existing in @(Get-ChildItem -LiteralPath $LabSourceFolder -File -Force -ErrorAction SilentlyContinue)) {
        if ($existing.Name -like '*-lab-folder.txt') { continue }
        Remove-Item -LiteralPath $existing.FullName -Force
    }
}

function Expand-Ncp7381StagedFileToMinBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $MinBytes
    )

    if ($MinBytes -le 0) { return }
    if ($MinBytes -gt $script:TestFileMaxBytes) {
        throw "StagedFileMinBytes ($MinBytes) exceeds TestFileMaxBytes ($($script:TestFileMaxBytes))."
    }

    $info = Get-Item -LiteralPath $Path
    if ($info.Length -ge $MinBytes) { return }

    $remaining = $MinBytes - $info.Length
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] 65536
        while ($remaining -gt 0) {
            $chunk = [Math]::Min($remaining, $buffer.Length)
            $stream.Write($buffer, 0, [int]$chunk)
            $remaining -= $chunk
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-Ncp7381JobFilesToLabSource {
    param(
        [Parameter(Mandatory)][string] $LabSourceFolder,
        [Parameter(Mandatory)][System.IO.FileInfo[]] $SeedFiles,
        [int] $MinimumStagedFiles = 16,
        [long] $MinBytesPerFile = 1048576
    )
    if ($MinimumStagedFiles -lt 2) { throw 'MinimumStagedFiles must be at least 2.' }
    Clear-Ncp7381LabSourceFolder -LabSourceFolder $LabSourceFolder
    $staged = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $copyIndex = 0
    while ($staged.Count -lt $MinimumStagedFiles) {
        foreach ($file in $SeedFiles) {
            $extension = $file.Extension
            $baseName = if ([string]::IsNullOrEmpty($extension)) { $file.Name } else {
                [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            }
            $destName = if ($copyIndex -eq 0) { $file.Name } else { "$baseName-ncp7381-$copyIndex$extension" }
            $destPath = Join-Path $LabSourceFolder $destName
            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
            Expand-Ncp7381StagedFileToMinBytes -Path $destPath -MinBytes $MinBytesPerFile
            $staged.Add((Get-Item -LiteralPath $destPath))
            $copyIndex++
            if ($staged.Count -ge $MinimumStagedFiles) { break }
        }
    }
    Write-TestStep "Staged $($staged.Count) file(s) (min ${MinBytesPerFile} bytes each) under '$LabSourceFolder'"
    return [System.IO.FileInfo[]]$staged.ToArray()
}

function Invoke-Ncp7381EnsureSmbLabRootsVisible {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $LabPolicyId
    )

    try {
        $null = Wait-ScanAgentSourceRootVisible -Exe $Exe -RootName $script:Sa08SmbStoreSource -TimeoutSec 60
        return
    }
    catch {
        Write-TestStep "SMB source root '$($script:Sa08SmbStoreSource)' not visible within 60s: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($script:Ncp7381CoreDebugHookUrl)) {
        throw "SMB source root '$($script:Sa08SmbStoreSource)' missing and Core debug hook URL is unset."
    }

    Write-TestStep 'SMB lab: commdown/commup and policy round-trip retry (refresh SMB roots)'
    Disconnect-AllCoreAgentsForRefresh -HookUrl $script:Ncp7381CoreDebugHookUrl -Exe $Exe
    Invoke-Ncp7381RefreshLocationsAfterCoreImport -Exe $Exe -LabPolicyId $LabPolicyId
    $null = Wait-ScanAgentSourceRootVisible -Exe $Exe -RootName $script:Sa08SmbStoreSource -TimeoutSec 120
}

function Invoke-Ncp7381NavigateSmbPanels {
    param([Parameter(Mandatory)][string] $Exe, [string] $StepLabel)
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Sa08SmbStoreSource, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "$StepLabel selectSource"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $script:Sa08SmbStoreDest, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "$StepLabel selectDestination"
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Sa08SmbStoreSource, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step "$StepLabel selectSource (selection)"
    Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "$StepLabel refresh source"
}

function Get-Ncp7381ListSourceFileCount {
    param($ListPayload)
    if ($null -eq $ListPayload) { return 0 }
    if ($ListPayload.PSObject.Properties['itemCount']) {
        return [int]$ListPayload.itemCount
    }
    if ($null -ne $ListPayload.items) {
        return Get-CollectionCount $ListPayload.items
    }
    return 0
}

function Get-Ncp7381UiSelectedFileCount {
    param([Parameter(Mandatory)][string] $Exe)
    $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $list -Step 'listSourceFiles (read selection)'
    $fromList = 0
    foreach ($item in @($list.items)) {
        if ($null -ne $item -and $item.PSObject.Properties['selection'] -and [string]$item.selection -eq 'All') {
            $fromList++
        }
    }
    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step 'ui.mainContent (read activity.selected)'
    $fromActivity = 0
    if ($null -ne $main.mainContent -and $null -ne $main.mainContent.activity) {
        $fromActivity = [int]$main.mainContent.activity.selected
    }
    return [Math]::Max($fromActivity, $fromList)
}

function Wait-Ncp7381SourceGridListedFileCount {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $MinimumFileCount,
        [int] $TimeoutSec = 120
    )
    Write-TestStep "Wait for source grid to list at least $MinimumFileCount file(s) (timeout ${TimeoutSec}s)"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $lastCount = -1
    while ([datetime]::UtcNow -lt $deadline) {
        Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel 'refresh source (wait for grid)'
        $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
        Assert-OkResponse -Response $list -Step 'listSourceFiles (wait for grid)'
        $count = Get-Ncp7381ListSourceFileCount -ListPayload $list
        if ($count -ge $MinimumFileCount) {
            Write-TestStep "Source grid lists $count file(s)"
            return $count
        }
        if ($count -ne $lastCount) {
            Write-Host "  listSourceFiles count=$count (need >= $MinimumFileCount)"
            $lastCount = $count
        }
        Start-Sleep -Milliseconds 400
    }
    throw "Timed out after ${TimeoutSec}s waiting for source grid; lastCount=$lastCount need >= $MinimumFileCount."
}

function Invoke-Ncp7381SelectListedSourceFilesUntilMinimum {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $MinimumSelected,
        [string] $StepLabel
    )
    $listInUi = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listInUi -Step "$StepLabel listSourceFiles"
    $selected = 0
    foreach ($item in @($listInUi.items)) {
        if ($selected -ge $MinimumSelected) { break }
        $name = if ($null -ne $item.name) { [string]$item.name } else { '' }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $pick = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'selectSourceFile', '--name', $name, '--wait-ms', "$UiWaitMs"
        )
        Assert-OkResponse -Response $pick -Step "selectSourceFile ($name)"
        $selected++
    }
    if ($selected -lt $MinimumSelected) {
        throw "$StepLabel bulk select chose $selected file(s); need at least $MinimumSelected."
    }
    return $selected
}

function Invoke-Ncp7381SelectStagedFilesInSourceUi {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][System.IO.FileInfo[]] $JobFiles,
        [int] $MinimumSelected,
        [string] $StepLabel
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-TestStep "$StepLabel ui.invoke selectAll (attempt $attempt)"
        $selectAll = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'selectAll')
        Assert-OkResponse -Response $selectAll -Step "$StepLabel selectAll"
        Invoke-ScanAgentE2eWaitUiReady -Exe $Exe -Context "$StepLabel after selectAll"
        $selected = Get-Ncp7381UiSelectedFileCount -Exe $Exe
        if ($selected -ge $MinimumSelected) {
            Write-TestStep "selectAll selected $selected file(s)"
            return $selected
        }
        Write-TestStep "selectAll selected $selected file(s); retry after refresh"
        if ($attempt -lt 3) {
            Invoke-ScanAgentE2eRefreshSourceContent -Exe $Exe -StepLabel "$StepLabel refresh before selectAll retry"
        }
    }

    Write-TestStep "$StepLabel selectAll below $MinimumSelected; select each listed source file"
    $bulkSelected = Invoke-Ncp7381SelectListedSourceFilesUntilMinimum -Exe $Exe -MinimumSelected $MinimumSelected `
        -StepLabel $StepLabel
    return [Math]::Max($bulkSelected, (Get-Ncp7381UiSelectedFileCount -Exe $Exe))
}

function Resolve-Ncp7381PolicyIdByName {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][string] $PolicyName
    )
    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    Assert-OkResponse -Response $policyList -Step 'policy.list'
    $match = @($policyList.policies | Where-Object { [string]$_.name -eq $PolicyName })
    if ($match.Count -lt 1) {
        throw "Policy '$PolicyName' not found in policy.list."
    }
    return [int](@($match | Sort-Object { [int]$_.id })[0].id)
}

function Invoke-Ncp7381RefreshLocationsAfterCoreImport {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $LabPolicyId
    )
    $refreshId = Resolve-Ncp7381PolicyIdByName -Exe $Exe -PolicyName $script:Sa08LocalRefreshPolicyName
    Write-TestStep "policy.select --policy-id $refreshId (post-import refresh)"
    $refresh = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--policy-id', "$refreshId", '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $refresh -Step 'policy.select (refresh)'
    Write-TestStep "policy.select --policy-id $LabPolicyId (lab policy)"
    $lab = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--policy-id', "$LabPolicyId", '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $lab -Step 'policy.select (lab)'
    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy round-trip (exit $($ready.ExitCode)): $($ready.StdOut)"
    }
}

function Test-Ncp7381ReadyForCommPulse {
    param($Status)
    if ($null -eq $Status) { return $false }
    if ($Status.inProgress -eq $true) { return $true }
    if ([string]$Status.state -eq 'running') { return $true }
    $running = 0
    $selected = 0
    $passed = 0
    $blocked = 0
    if ($Status.counts) {
        $running = [int]$Status.counts.running
        $selected = [int]$Status.counts.selected
        $passed = [int]$Status.counts.passed
        $blocked = [int]$Status.counts.blocked
    }
    if ($running -gt 0) { return $true }
    $processed = $passed + $blocked
    return ($selected -gt 1 -and $processed -gt 0 -and $processed -lt $selected)
}

function Test-Ncp7381SanitizationTerminated {
    param($Status)
    if ($null -eq $Status) { return $false }
    if ([string]$Status.state -eq 'complete') { return $true }
    if ($Status.sanitizationFinished -eq $true -and $Status.inProgress -eq $false) { return $true }
    return $false
}

function Invoke-Ncp7381ThrowIfJobEndedBeforeCommPulse {
    param(
        [Parameter(Mandatory)]$Status,
        [int] $ExpectedSelected
    )
    $selected = if ($Status.counts) { [int]$Status.counts.selected } else { 0 }
    $passed = if ($Status.counts) { [int]$Status.counts.passed } else { 0 }
    $blocked = if ($Status.counts) { [int]$Status.counts.blocked } else { 0 }
    $running = if ($Status.counts) { [int]$Status.counts.running } else { 0 }
    $terminal = $passed + $blocked

    if ($terminal -ge $ExpectedSelected -and $passed -ge $ExpectedSelected -and $running -eq 0) {
        throw 'Job completed successfully before comm drop could run. Lower -CommunicationUploadLimitKbps or raise -StagedFileMinBytes.'
    }

    $main = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    $abortBar = $false
    if ($main.ok -eq $true -and $main.mainContent -and $main.mainContent.activity) {
        $abortBar = $main.mainContent.activity.isProgressBarErrorOrAbortedOutcome -eq $true
    }

    throw "NCP-7381: job ended before agentcommblockon (instant disconnect handling). state=$($Status.state) selected=$selected passed=$passed blocked=$blocked running=$running inProgress=$($Status.inProgress) abortBar=$abortBar"
}

function Wait-Ncp7381MidJobAndPulseComm {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][string] $HookUrl,
        [int] $TimeoutSec,
        [int] $HoldSeconds = 5,
        [int] $ExpectedSelected = 2
    )
    Write-TestStep "Wait for inProgress/running then agentcommblockon, timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'
        if (Test-Ncp7381SanitizationTerminated -Status $status) {
            Invoke-Ncp7381ThrowIfJobEndedBeforeCommPulse -Status $status -ExpectedSelected $ExpectedSelected
        }
        if (Test-Ncp7381ReadyForCommPulse -Status $status) {
            Write-TestStep "Comm pulse window: selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running) inProgress=$($status.inProgress)"
            Invoke-Ncp7381CoreCommPulseDuringJob -HookUrl $HookUrl -Exe $Exe -HoldSeconds $HoldSeconds
            return $status
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out after ${TimeoutSec}s waiting to pulse comm during an in-progress job."
}

function Invoke-Ncp7381CoreCommPulseDuringJob {
    param(
        [Parameter(Mandatory)][string] $HookUrl,
        [Parameter(Mandatory)][string] $Exe,
        [int] $HoldSeconds = 5
    )
    Write-TestStep "Core agentcommblockon (mid-job disconnect, hold ${HoldSeconds}s)"
    $on = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'agentcommblockon'
    Assert-ScanAgentCoreDebugHookResponse -Response $on -Step 'agentcommblockon'
    $null = Wait-ScanAgentGatewayDisconnected -Exe $Exe -IdleQuietSec 0 -VerifyTimeoutSec 30 `
        -Context 'NCP-7381 mid-job'
    Start-Sleep -Seconds $HoldSeconds
    Write-TestStep 'Core agentcommblockoff (reconnect allowed)'
    $off = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'agentcommblockoff'
    Assert-ScanAgentCoreDebugHookResponse -Response $off -Step 'agentcommblockoff'
}

function Test-Ncp7381OutcomeIsAbortOrCommFailure {
    param([string] $Outcome, [string] $OutcomeFriendly)
    if ($Outcome -match 'Aborted|Communication') { return $true }
    if (-not [string]::IsNullOrWhiteSpace($OutcomeFriendly)) {
        if ($OutcomeFriendly -match 'Aborted|Communication error|communication') { return $true }
    }
    return $false
}

function Assert-Ncp7381NoInstantJobTermination {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $ExpectedSelected,
        [int] $ObserveSec = 10
    )
    Write-TestStep "Observe sanitization.status for ${ObserveSec}s after comm drop (no instant mass abort)"
    $deadline = [datetime]::UtcNow.AddSeconds($ObserveSec)
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status (post-comm)'
        $selected = [int]$status.counts.selected
        $passed = [int]$status.counts.passed
        $blocked = [int]$status.counts.blocked
        $running = [int]$status.counts.running
        $terminal = $passed + $blocked
        $jobFinished = ($status.sanitizationFinished -eq $true) -or ([string]$status.state -eq 'complete')

        if ($jobFinished -and $running -eq 0 -and $terminal -ge 1 -and $terminal -lt $ExpectedSelected) {
            throw "NCP-7381: job finished early after disconnect (terminal=$terminal expected selected=$ExpectedSelected; passed=$passed blocked=$blocked)."
        }

        if ($jobFinished -and $running -eq 0 -and $terminal -ge $ExpectedSelected -and $passed -eq 0) {
            $policyBlocks = 0
            if ($null -ne $status.files) {
                foreach ($entry in @($status.files)) {
                    if ([string]$entry.outcome -match 'BlockedByPolicy') { $policyBlocks++ }
                }
            }
            if ($policyBlocks -ge $ExpectedSelected) {
                throw "SA-35 lab: all $policyBlocks file(s) OutcomeBlockedByPolicy (Core allowedFileTypes on Test8-abort — check SA-08 import uses modern StrPropType_AllowedFileTypes)."
            }
            throw "NCP-7381: job completed with zero passed outcomes after disconnect (instant abort / comm failure regression)."
        }

        if ($jobFinished -and $running -eq 0 -and $null -ne $status.files) {
            $bad = 0
            foreach ($entry in @($status.files)) {
                if (Test-Ncp7381OutcomeIsAbortOrCommFailure -Outcome ([string]$entry.outcome) -OutcomeFriendly ([string]$entry.outcomeFriendly)) {
                    $bad++
                }
            }
            if ($bad -gt 0 -and $passed -eq 0) {
                throw "NCP-7381: $($bad) abort/communication outcome(s) with no passed files after disconnect."
            }
        }

        $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
        if ($main.ok -eq $true -and $main.mainContent -and $main.mainContent.activity) {
            $abortBar = $main.mainContent.activity.isProgressBarErrorOrAbortedOutcome -eq $true
            if ($abortBar -and $jobFinished -and $running -eq 0 -and $passed -lt $ExpectedSelected) {
                throw 'NCP-7381: activity bar shows error/abort and job finished before expected passes (instant abort on disconnect).'
            }
        }

        Start-Sleep -Milliseconds 500
    }
}

function Wait-Ncp7381SanitizationSuccessAfterReconnect {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $TimeoutSec,
        [int] $ExpectedSelected
    )
    Write-TestStep "Poll until job completes with all selected files passed/blocked (expected selected=$ExpectedSelected)"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $finalStatus = $null
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'
        if ([string]$status.state -eq 'complete' -or ($status.sanitizationFinished -eq $true -and $status.inProgress -eq $false)) {
            $finalStatus = $status
            break
        }
        Write-Host "  state=$($status.state) selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
    }

    if (-not $finalStatus) {
        throw "Sanitization did not complete within ${TimeoutSec}s after reconnect."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running
    if ($selected -ne $ExpectedSelected) {
        throw "counts.selected ($selected) does not match UI selection ($ExpectedSelected)."
    }
    if ($running -ne 0) {
        throw "Expected running=0 after completion; running=$running"
    }
    if (($passed + $blocked) -ne $selected) {
        throw "passed+blocked ($($passed + $blocked)) does not match selected ($selected); unfinished items or instant comm failures."
    }
    if ($passed -lt 1) {
        throw "Expected at least one passed file after reconnect; passed=$passed"
    }

    if ($null -ne $finalStatus.files) {
        $bad = 0
        foreach ($entry in @($finalStatus.files)) {
            if (Test-Ncp7381OutcomeIsAbortOrCommFailure -Outcome ([string]$entry.outcome) -OutcomeFriendly ([string]$entry.outcomeFriendly)) {
                $bad++
            }
        }
        if ($bad -gt 0) {
            throw "NCP-7381: final job has $bad abort/communication failure outcome(s); expected continuation per NCP-7255."
        }
    }

    Write-TestStep "Job completed after reconnect: passed=$passed blocked=$blocked selected=$selected"
    return $finalStatus
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-35'

    if ($SkipCorePolicySetup) {
        throw '-SkipCorePolicySetup is not supported for SA-35; Test8-abort SMB lab policy is required.'
    }

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info'
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) { Write-TestStep "Test Platform componentVersion: $e2eVersion" }

    $script:OriginalPolicyName = Register-ScanAgentE2eOriginalPolicyName -Exe $exe `
        -GatewayWaitSec 120 -GatewayWaitContext 'before SA-35 Core policy setup'

    if ($CoreSanitizationDelaySeconds -lt 1) {
        throw 'CoreSanitizationDelaySeconds must be >= 1 (Core /debug/hook sanitizationdelay). Rebuild Core with the lab hook enabled.'
    }

    $uploadLimitLabel = if ($CommunicationUploadLimitKbps -gt 0) { "; upload limit ${CommunicationUploadLimitKbps} Kbps" } else { '' }
    Write-TestStep "Core lab policy: $CorePolicyName SMB$uploadLimitLabel"
    $sa08Params = @{
        Exe                  = $exe
        CoreDebugHookUrl     = $CoreDebugHookUrl
        PolicyTemplateXml    = $PolicyTemplateXml
        TemplatePolicyName   = $TemplatePolicyName
        PolicyName           = $CorePolicyName
        UiWaitMs             = $UiWaitMs
    }
    if ($CommunicationUploadLimitKbps -gt 0) {
        $sa08Params.CommunicationUploadLimitKbps = $CommunicationUploadLimitKbps
    }
    $coreSetup = Initialize-ScanAgentSa08CoreTestPolicy @sa08Params
    $script:Ncp7381CorePolicyStackPushed = $true
    $script:Ncp7381CoreDebugHookUrl = $coreSetup.HookUrl

    Write-TestStep "Core sanitizationdelay ${CoreSanitizationDelaySeconds}s (per-file MQ processing)"
    $delayOn = Invoke-ScanAgentCoreDebugHook -HookUrl $script:Ncp7381CoreDebugHookUrl -Command 'sanitizationdelay' `
        -BodyObject @{ delaySeconds = $CoreSanitizationDelaySeconds }
    Assert-ScanAgentCoreDebugHookResponse -Response $delayOn -Step 'sanitizationdelay'

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 180 -Context 'after SA-35 Core import' -NudgeReconnect

    $labPolicyId = Resolve-Ncp7381PolicyIdByName -Exe $exe -PolicyName $CorePolicyName
    Invoke-Ncp7381RefreshLocationsAfterCoreImport -Exe $exe -LabPolicyId $labPolicyId
    Invoke-Ncp7381EnsureSmbLabRootsVisible -Exe $exe -LabPolicyId $labPolicyId

    $fixtureInfo = Resolve-Ncp7381FixturePool -TestFilesRootOverride $TestFilesRoot -MinFiles $MinSeedFiles

    Invoke-Ncp7381NavigateSmbPanels -Exe $exe -StepLabel 'NCP-7381'

    $stagedFiles = Copy-Ncp7381JobFilesToLabSource -LabSourceFolder $jobSourcePath -SeedFiles $fixtureInfo.SeedFiles `
        -MinimumStagedFiles $MinStagedJobFiles -MinBytesPerFile $StagedFileMinBytes

    $null = Wait-Ncp7381SourceGridListedFileCount -Exe $exe -MinimumFileCount $MinStagedJobFiles -TimeoutSec 120

    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    $minSelect = [Math]::Min(2, $MinStagedJobFiles)
    $uiSelectedCount = Invoke-Ncp7381SelectStagedFilesInSourceUi -Exe $exe -JobFiles $stagedFiles `
        -MinimumSelected $minSelect -StepLabel 'NCP-7381'
    $expectedSelected = $uiSelectedCount

    $mainBefore = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainBefore -Step 'ui.mainContent before start'
    if ($mainBefore.mainContent.canStartSanitization -ne $true) {
        throw 'canStartSanitization is false before startSanitization.'
    }
    if ($null -ne $mainBefore.mainContent.activity) {
        $activitySelected = [int]$mainBefore.mainContent.activity.selected
        if ($activitySelected -gt $expectedSelected) {
            $expectedSelected = $activitySelected
        }
    }
    Write-TestStep "UI selected $expectedSelected file(s) for sanitization"

    Write-TestStep 'startSanitization'
    $start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization'

    $midStatus = Wait-Ncp7381MidJobAndPulseComm -Exe $exe -HookUrl $script:Ncp7381CoreDebugHookUrl `
        -TimeoutSec $MidJobWaitSec -HoldSeconds $CommHoldSeconds -ExpectedSelected $expectedSelected
    if ([int]$midStatus.counts.selected -gt 0) {
        $expectedSelected = [int]$midStatus.counts.selected
    }
    Assert-Ncp7381NoInstantJobTermination -Exe $exe -ExpectedSelected $expectedSelected -ObserveSec $PostCommObserveSec

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec $GatewayReconnectTimeoutSec `
        -Context 'NCP-7381 after comm pulse' -NudgeReconnect

    $null = Wait-Ncp7381SanitizationSuccessAfterReconnect -Exe $exe -TimeoutSec $SanitizePollSec -ExpectedSelected $expectedSelected

    $script:ScenarioPassed = $true
    Write-TestStep 'SA-35 / NCP-7381 scenario passed.'
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
}
finally {
    if ($script:Ncp7381CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Ncp7381CoreDebugHookUrl) -and
        -not [string]::IsNullOrWhiteSpace($exe)) {
        try {
            Write-TestStep 'Core: sanitizationdelayoff'
            $delayOff = Invoke-ScanAgentCoreDebugHook -HookUrl $script:Ncp7381CoreDebugHookUrl -Command 'sanitizationdelayoff'
            Assert-ScanAgentCoreDebugHookResponse -Response $delayOff -Step 'sanitizationdelayoff'
        }
        catch {
            Write-Warning "Core sanitizationdelayoff failed: $($_.Exception.Message)"
        }

        try {
            Write-TestStep "Core: poppolicystate and restore agent policy '$($script:OriginalPolicyName)'"
            $null = Restore-ScanAgentCorePolicyLabAndAgent -HookUrl $script:Ncp7381CoreDebugHookUrl -Exe $exe `
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

    if ($script:ScenarioPassed) {
        try {
            Clear-Ncp7381LabSourceFolder -LabSourceFolder $jobSourcePath
        }
        catch {
            $script:ScenarioPassed = $false
            $script:ScenarioFailureMessage = "Teardown failed after successful test: $($_.Exception.Message)"
            Write-Error $script:ScenarioFailureMessage
        }
    }
}

Report-ScanAgentE2eScenarioToTestPlatform -ReportScriptPath $script:SaE2eReportScript `
    -TestId 'SA-35' -TestTitle 'NCP-7381 mid-job continues after short comm drop (NCP-7255)' `
    -EvidencePathsOnFailure $evidenceOnFailure

Exit-ScanAgentE2eScenario