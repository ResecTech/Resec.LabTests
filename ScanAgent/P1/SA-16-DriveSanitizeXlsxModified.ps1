#Requires -Version 5.1
<#
.SYNOPSIS
  End-to-end UI automation: D:\ source, D:\out destination, first .xlsx sanitized with OutcomeReconstructed.

.DESCRIPTION
  Uses ScanAgentDebug against a running desktop Scan Agent (DebugInterface.Enabled = true).
  Prerequisites on D:\:
    - At least one .xlsx file in the drive root (first in grid order is selected).
    - Folder D:\out exists (destination output).

  After sanitization, verifies OutcomeReconstructed and that the output file size is within
  ±SizeTolerancePercent of the source file (default 10%).

.NOTES
  Exit 0 = scenario passed; non-zero = failure (see Write-Error output).
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [string] $SourceRoot = 'D:',
    [string] $DestinationRoot = 'D:',
    [string] $DestinationSubfolder = 'out',
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 600,
    [int] $ExpectedReconstructedCount = 1,
    [double] $SizeTolerancePercent = 10
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
$script:Sa16DestinationFolder = $null

function Invoke-ScanAgentDebug {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
        $stderr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
            StdErr   = if ($stderr) { $stderr.Trim() } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ScanAgentDebugJson {
    param(
        [string] $Exe,
        [string[]] $Arguments
    )

    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $commandLine = $Arguments -join ' '
        $detailParts = @()
        if ($result.StdOut) { $detailParts += $result.StdOut.Trim() }
        if ($result.StdErr) { $detailParts += $result.StdErr.Trim() }
        $detail = ($detailParts -join [Environment]::NewLine)
        throw (Format-ScanAgentDebugInvokeFailure -ExitCode $result.ExitCode -CommandLine $commandLine -Detail $detail)
    }

    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        throw "ScanAgentDebug returned no stdout: $($Arguments -join ' ')"
    }

    try {
        return $result.StdOut | ConvertFrom-Json
    }
    catch {
        throw "ScanAgentDebug output was not JSON: $($Arguments -join ' ')`n$($result.StdOut)"
    }
}

function Assert-OkResponse {
    param($Response, [string] $Step)
    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "$Step failed: $err"
    }
}

function Get-ReconstructedFiles {
    param($SanitizationStatus)

    if (-not $SanitizationStatus.files) {
        return @()
    }

    return @($SanitizationStatus.files | Where-Object {
            $_.outcome -eq 'OutcomeReconstructed' -or
            $_.outcomeFriendly -eq 'Reconstructed'
        })
}

function Get-FileLengthBytes {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'File path is required for size check.'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found for size check: $Path"
    }

    return (Get-Item -LiteralPath $Path).Length
}

function Assert-DestinationSizeNearSource {
    param(
        [long] $SourceSizeBytes,
        [string] $DestinationPath,
        [double] $TolerancePercent
    )

    if ($SourceSizeBytes -le 0) {
        throw "Source file size must be positive; got $SourceSizeBytes bytes."
    }

    $destSize = Get-FileLengthBytes -Path $DestinationPath
    $minRatio = 1 - ($TolerancePercent / 100)
    $maxRatio = 1 + ($TolerancePercent / 100)
    $minBytes = [long][math]::Floor($SourceSizeBytes * $minRatio)
    $maxBytes = [long][math]::Ceiling($SourceSizeBytes * $maxRatio)

    Write-Host "Size check: source=$SourceSizeBytes bytes, destination=$destSize bytes (allowed $minBytes..$maxBytes, ±$TolerancePercent%)."

    if ($destSize -lt $minBytes -or $destSize -gt $maxBytes) {
        throw "Destination size $destSize bytes is outside ±$TolerancePercent% of source $SourceSizeBytes bytes ($DestinationPath)."
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-16'

    $destFolderPath = [System.IO.Path]::Combine($DestinationRoot.TrimEnd('\'), $DestinationSubfolder)
    $script:Sa16DestinationFolder = [System.IO.Path]::GetFullPath($destFolderPath)

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-Host "Using ScanAgentDebug: $exe"

# 0. Pipe reachable
$ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
Assert-OkResponse -Response $ping -Step 'ping'
Write-Host 'Agent debug pipe: OK'

$agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
Assert-OkResponse -Response $agentInfo -Step 'agent.info'
$e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
if ($e2eVersion) {
    Write-Host "Test Platform componentVersion: $e2eVersion"
}

# 1. Source = D:\
$selectSource = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
    'selectSource', '--name', $SourceRoot, '--wait-ms', "$UiWaitMs", '--wait-loaded'
)
Assert-OkResponse -Response $selectSource -Step 'selectSource'
Write-Host "Source root: $SourceRoot"

# 2. Destination = D:\
$selectDest = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
    'selectDestination', '--name', $DestinationRoot, '--wait-ms', "$UiWaitMs", '--wait-loaded'
)
Assert-OkResponse -Response $selectDest -Step 'selectDestination'
Write-Host "Destination root: $DestinationRoot"

# 3. Destination folder = D:\out
$openOut = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
    'ui.invoke', '--action', 'openFolder', '--panel', 'destination', '--name', $DestinationSubfolder, '--wait-ms', "$UiWaitMs"
)
Assert-OkResponse -Response $openOut -Step 'openFolder (destination)'
Write-Host "Destination folder: $DestinationRoot\$DestinationSubfolder"

# 4. First .xlsx in source grid (drive root)
$list = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSourceFiles')
Assert-OkResponse -Response $list -Step 'listSourceFiles'

$xlsx = @($list.items | Where-Object {
        $_.name -match '\.xlsx$'
    } | Select-Object -First 1)

if (-not $xlsx) {
    throw "No .xlsx file found on source $SourceRoot (current folder). Add a test file and retry."
}

$fileName = $xlsx.name
$sourceFilePath = $xlsx.path
if ([string]::IsNullOrWhiteSpace($sourceFilePath)) {
    $sourceRootPath = if ($SourceRoot.EndsWith('\')) { $SourceRoot } else { "$SourceRoot\" }
    $sourceFilePath = Join-Path $sourceRootPath $fileName
}

if ($null -ne $xlsx.sizeBytes -and [long]$xlsx.sizeBytes -gt 0) {
    $sourceSizeBytes = [long]$xlsx.sizeBytes
}
else {
    $sourceSizeBytes = Get-FileLengthBytes -Path $sourceFilePath
}

Write-Host "Selecting source file: $fileName ($sourceSizeBytes bytes, $sourceFilePath)"

Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection') | Out-Null

$selectFile = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
    'selectSourceFile', '--name', $fileName, '--wait-ms', "$UiWaitMs"
)
Assert-OkResponse -Response $selectFile -Step 'selectSourceFile'

# 5. Sanitize
$start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
Assert-OkResponse -Response $start -Step 'startSanitization'
Write-Host 'Sanitization started; waiting for completion...'

# 6. Wait for complete; reconstructed count = 1
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

$reconstructedFiles = Get-ReconstructedFiles -SanitizationStatus $finalStatus
$reconstructedCount = Get-CollectionCount $reconstructedFiles
Write-Host "Sanitization complete. Reconstructed outcomes: $reconstructedCount (expected $ExpectedReconstructedCount)."

if ($reconstructedCount -ne $ExpectedReconstructedCount) {
    $filesJson = $finalStatus.files | ConvertTo-Json -Depth 5 -Compress
    throw "Expected $ExpectedReconstructedCount file(s) with OutcomeReconstructed; got $reconstructedCount. files=$filesJson"
}

$sourceFullPath = [System.IO.Path]::GetFullPath($sourceFilePath)
$jobFile = $reconstructedFiles | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.sourcePath) -and
        ([System.IO.Path]::GetFullPath($_.sourcePath) -eq $sourceFullPath)
    } | Select-Object -First 1
if (-not $jobFile) {
    $jobFile = $reconstructedFiles | Select-Object -First 1
}

$destinationPath = $jobFile.destinationPath
if ([string]::IsNullOrWhiteSpace($destinationPath)) {
    throw 'sanitization.status did not include destinationPath for the reconstructed file.'
}

Assert-DestinationSizeNearSource -SourceSizeBytes $sourceSizeBytes -DestinationPath $destinationPath -TolerancePercent $SizeTolerancePercent

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
    if (-not $script:ScenarioPassed -and $script:Sa16DestinationFolder -and (Test-Path -LiteralPath $script:Sa16DestinationFolder)) {
        $evidenceOnFailure += $script:Sa16DestinationFolder
    }
    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:SaE2eReportScript `
        -TestId 'SA-16' -TestTitle 'Drive sanitize xlsx modified' -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure
}
