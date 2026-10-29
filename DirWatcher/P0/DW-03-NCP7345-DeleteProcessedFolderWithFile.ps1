#Requires -Version 5.1
<#
.SYNOPSIS
  DW-03 / NCP-7345: Delete processed incoming subfolder after file sanitization (folder + file drop).

.DESCRIPTION
  Regression for NCP-7345 (Bezeq): copy a folder containing a file into incoming; the file is sanitized,
  leaves the source tree (move to temp), and the incoming subfolder becomes empty. With
  "Delete processed folders after X minutes" and periodic file check enabled, DW should remove that
  empty subfolder after the policy threshold (plus up to 1 minute test slack).

  Lab setup:
    - Core with EnableDebugInterface=True (https://localhost:4504/debug/hook).
    - DirWatcher registered to Core and running (restart after policy import unless -SkipDirWatcherRestart).

.PARAMETER DeleteProcessedFoldersAfterMinutes
  Policy value (default 1).

.PARAMETER SkipPolicyImport
  Use when paths and policy already match (-WorkRoot required).

.EXAMPLE
  .\DW-03-NCP7345-DeleteProcessedFolderWithFile.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $WorkRoot = '',
    [string] $FixturePath = '',
    [string] $DirWatcherExe = '',
    [switch] $SkipPolicyImport,
    [switch] $SkipDirWatcherRestart,
    [switch] $UseAgentCommNudge,
    [int] $SourceClearedTimeoutSec = 60,
    [int] $CleanOutputTimeoutSec = 120,
    [int] $DeleteProcessedFoldersAfterMinutes = 1,
    [int] $PostReconnectSettleSec = 10,
    [int] $EmptyFolderVerifyTimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return (Get-CoreDeployRequirements) + (Get-DirWatcherDeployRequirements)
}

$script:DwE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:DwE2eCommonRoot 'DirWatcherE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$layout = $null
$script:TestId = 'DW-NCP7345'
$script:TestTitle = 'DirWatcher deletes empty processed subfolder after file sanitize (NCP-7345)'
$script:DwE2eReportScript = Join-Path $script:DwE2eCommonRoot 'Report-DirWatcherTestPlatformResult.ps1'

function Test-DwNcp7345IncomingFolderEmpty {
    param(
        [Parameter(Mandatory)]
        [string] $FolderPath
    )

    $full = [System.IO.Path]::GetFullPath($FolderPath)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return $false
    }

    $children = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
    return ($children.Count -eq 0)
}

function Wait-DwNcp7345IncomingFolderEmpty {
    param(
        [Parameter(Mandatory)]
        [string] $FolderPath,
        [int] $TimeoutSec = 30,
        [int] $PollMs = 500
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetFullPath($FolderPath)) -PathType Container)) {
            return $true
        }
        if (Test-DwNcp7345IncomingFolderEmpty -FolderPath $FolderPath) {
            return $true
        }
        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

function Import-DwNcp7345PolicyAndApply {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        $Layout,
        [string] $StepLabel
    )

    if ($SkipPolicyImport) {
        Write-DwTestStep "$StepLabel (SkipPolicyImport — using existing Core/DW policy)"
        return
    }

    Write-DwTestStep $StepLabel
    Write-DwTestStep "  Delete processed folders after X minutes: $DeleteProcessedFoldersAfterMinutes"
    Write-DwTestStep '  Enable periodic file check: True'
    Write-DwTestStep '  Process empty folders: True (NCP-7343 lab policy base)'

    if (-not $script:PolicyStackPushed) {
        Write-DwTestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $HookUrl | Out-Null
        $script:PolicyStackPushed = $true
    }

    Import-DwNcp7343LabPolicy -HookUrl $HookUrl `
        -IncomingRoot $Layout.Incoming -TempRoot $Layout.Temp `
        -RejectedRoot $Layout.Rejected -CleanRoot $Layout.Clean `
        -PolicyName 'NCP7345-dw-lab' `
        -DeleteProcessedFoldersAfterMinutes $DeleteProcessedFoldersAfterMinutes `
        -EnablePeriodicFileCheck:$true | Out-Null

    if (-not $SkipDirWatcherRestart) {
        $dwExe = Resolve-DirWatcherE2eExePath -Override $DirWatcherExe
        $monitorNotBefore = Get-Date
        Stop-DirWatcherE2eProcesses
        Start-DirWatcherE2eProcess -ExePath $dwExe
        if (-not (Test-DirWatcherE2eProcessRunning)) {
            throw 'DirWatcher failed to start after restart.'
        }
        Set-DirWatcherE2eComponentVersionFromExe -ExePath $dwExe
        Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $Layout.Incoming -TimeoutSec 90 `
            -NotBeforeLocal $monitorNotBefore | Out-Null
    }
    elseif ($UseAgentCommNudge) {
        $monitorNotBefore = Get-Date
        Invoke-DirWatcherE2eAgentCommReconnectNudge -HookUrl $HookUrl -SettleSeconds $PostReconnectSettleSec
        Wait-DirWatcherE2eMonitoringIncoming -IncomingRoot $Layout.Incoming -TimeoutSec 90 `
            -NotBeforeLocal $monitorNotBefore | Out-Null
    }
    else {
        Start-Sleep -Seconds $PostReconnectSettleSec
    }
}

function New-DwNcp7345IncomingFolderWithFile {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $FixturePath
    )

    $fixtureFull = [System.IO.Path]::GetFullPath($FixturePath)
    if (-not (Test-Path -LiteralPath $fixtureFull -PathType Leaf)) {
        throw "Fixture not found: $fixtureFull"
    }

    $folderName = 'ncp7345-' + [Guid]::NewGuid().ToString('N')
    $folderPath = Join-Path $IncomingRoot $folderName
    $fileName = 'payload' + [System.IO.Path]::GetExtension($fixtureFull)
    $filePath = Join-Path $folderPath $fileName

    New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    Copy-Item -LiteralPath $fixtureFull -Destination $filePath -Force

    $createdAt = (Get-Item -LiteralPath $folderPath).CreationTime

    return [pscustomobject]@{
        FolderName = $folderName
        FolderPath = $folderPath
        FileName   = $fileName
        FilePath   = $filePath
        CreatedAt  = $createdAt
    }
}

try {
    if ($DeleteProcessedFoldersAfterMinutes -le 0) {
        throw 'DeleteProcessedFoldersAfterMinutes must be > 0.'
    }

    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    Ensure-DirWatcherE2eProcessRunning -DirWatcherExe $DirWatcherExe

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-DwTestStep "Hook: $hookUrl"

    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-DwTestStep "Core version: $($versionInfo.version)"
    }

    if ([string]::IsNullOrWhiteSpace($WorkRoot) -and -not $SkipPolicyImport) {
        $WorkRoot = Join-Path 'C:\test' ('DW-NCP7345-' + [Guid]::NewGuid().ToString('N'))
    }

    $layout = New-DirWatcherE2eWorkLayout -WorkRoot $WorkRoot
    Write-DwTestStep "WorkRoot: $($layout.WorkRoot)"
    Write-DwTestStep "  incoming: $($layout.Incoming)"
    Write-DwTestStep "  temp:     $($layout.Temp)"
    Write-DwTestStep "  clean:    $($layout.Clean)"

    if ($SkipPolicyImport -and [string]::IsNullOrWhiteSpace($WorkRoot)) {
        throw 'SkipPolicyImport requires -WorkRoot pointing at folders that match the active DW policy.'
    }

    Import-DwNcp7345PolicyAndApply -HookUrl $hookUrl -Layout $layout `
        -StepLabel 'importpolicies (delete processed folders + periodic + process empty folders)'

    if ([string]::IsNullOrWhiteSpace($FixturePath)) {
        $FixturePath = Join-Path (Get-LabFixturesRoot) 'FileTypeDetection\sample.txt'
    }

    $drop = New-DwNcp7345IncomingFolderWithFile -IncomingRoot $layout.Incoming -FixturePath $FixturePath
    Write-DwTestStep "Drop folder+file -> $($drop.FolderPath)\$($drop.FileName) (folder CreatedAt $($drop.CreatedAt))"

    Write-DwTestStep 'Wait for source file to leave incoming subfolder (move to temp on sanitize start)'
    $sourceCleared = Wait-DirWatcherE2eFileLeavesPath -FilePath $drop.FilePath -TimeoutSec $SourceClearedTimeoutSec
    if (-not $sourceCleared) {
        throw "File still under incoming after ${SourceClearedTimeoutSec}s: $($drop.FilePath)"
    }
    Write-DwTestStep 'OK — source file cleared from incoming subfolder'

    Write-DwTestStep 'Wait for sanitized file on SMB clean destination'
    $outputPath = Wait-DirWatcherE2eCleanOutput -CleanRoot $layout.Clean -FileName $drop.FileName `
        -TimeoutSec $CleanOutputTimeoutSec
    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        throw "Timed out waiting for clean output '$($drop.FileName)' under $($layout.Clean) (${CleanOutputTimeoutSec}s)."
    }
    Write-DwTestStep "OK — clean output: $outputPath"

    Write-DwTestStep 'Assert incoming subfolder is empty (directory may still exist before periodic delete)'
    $empty = Wait-DwNcp7345IncomingFolderEmpty -FolderPath $drop.FolderPath -TimeoutSec $EmptyFolderVerifyTimeoutSec
    if (-not $empty) {
        $listing = @(Get-ChildItem -LiteralPath $drop.FolderPath -Force -ErrorAction SilentlyContinue) |
            ForEach-Object { $_.FullName }
        throw "Incoming subfolder not empty within ${EmptyFolderVerifyTimeoutSec}s: $($drop.FolderPath). Items: $($listing -join '; ')"
    }
    if (Test-Path -LiteralPath $drop.FolderPath) {
        Write-DwTestStep "OK — incoming subfolder exists and is empty: $($drop.FolderPath)"
        # Align with DW delete age (folder CreationTime on disk, same as drop time here).
        $folderAgeAnchor = $drop.CreatedAt
    }
    else {
        Write-DwTestStep 'Incoming subfolder already removed before periodic wait (acceptable if delete ran early)'
    }

    if (Test-Path -LiteralPath $drop.FolderPath) {
        Write-DwTestStep "Wait for periodic cleanup (policy ${DeleteProcessedFoldersAfterMinutes} min + slack, from folder create)"
        $deleted = Wait-DirWatcherE2eIncomingFolderDeletedByPolicy `
            -IncomingFolderPath $drop.FolderPath `
            -FolderCreatedAtLocal $folderAgeAnchor `
            -DeleteAfterMinutes $DeleteProcessedFoldersAfterMinutes
        if (-not $deleted) {
            throw "Empty incoming subfolder was not removed by periodic delete within expected window: $($drop.FolderPath)"
        }
        Write-DwTestStep 'OK — empty incoming subfolder removed by Delete processed folders policy'
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
    if (-not $script:ScenarioPassed) {
        if ($layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
            $evidenceOnFailure += $layout.WorkRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
            $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
            if ($coreLog) {
                $evidenceOnFailure += $coreLog
                Write-DwTestStep "Core log for evidence: $coreLog"
            }
        }
        $dwLogDir = Get-DirWatcherE2eLogDirectory
        if ($dwLogDir) {
            $evidenceOnFailure += $dwLogDir
        }
        if (@($evidenceOnFailure).Count -gt 0) {
            try {
                $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'DW-NCP7345'
                if ($script:EvidenceZipPath) {
                    Write-DwTestStep "Evidence zip: $($script:EvidenceZipPath)"
                }
            }
            catch {
                Write-Warning "Could not create failure evidence zip: $($_.Exception.Message)"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DIRWATCHER_COMPONENT_VERSION)) {
        $env:TESTPLATFORM_COMPONENT_VERSION = $env:DIRWATCHER_COMPONENT_VERSION
    }
    $prevComponent = $env:TESTPLATFORM_COMPONENT_NAME
    if ([string]::IsNullOrWhiteSpace($prevComponent)) {
        $env:TESTPLATFORM_COMPONENT_NAME = 'DirWatcher'
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:DwE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure `
        -EvidenceZipPath $script:EvidenceZipPath

    if ($script:PolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-DwTestStep 'poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed -and $layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
        try {
            Remove-Item -LiteralPath $layout.WorkRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove work folder '$($layout.WorkRoot)': $($_.Exception.Message)"
        }
    }
    elseif (-not $script:ScenarioPassed -and $layout -and $layout.WorkRoot -and (Test-Path -LiteralPath $layout.WorkRoot)) {
        Write-Host "Work artifacts left at: $($layout.WorkRoot)"
    }
}
