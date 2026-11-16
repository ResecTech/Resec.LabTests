#Requires -Version 5.1
<#
.SYNOPSIS
  SA-34 / NCP-7379: Source selection on Desktop after cached root soft-refresh.

.DESCRIPTION
  Reopens Desktop (cached root) so PanelVMBase runs background force-refresh, then selects a file
  and asserts listSourceFiles and ui.mainContent grid report Selection=All (NCP-7379 stale row VMs).

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled = true; gateway connected.
    - Policy allows Desktop source (default lab policy is fine).

.NOTES
  Jira: NCP-7379.
  Exit 0 = passed.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [int] $UiWaitMs = 45000,
    [int] $GatewayWaitSec = 60,
    [int] $SelectionSyncMaxWaitMs = 10000,
    [int] $SelectionSyncPollMs = 250,
    [string] $PivotRootName = 'Documents'
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
$script:UiWaitMs = $UiWaitMs
. (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot -ScanAgentDebug $ScanAgentDebug

$exe = $null

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Assert-OkResponse {
    param($Response, [string] $Step)
    if (-not $Response.ok) {
        $err = if ($Response.error) { $Response.error } else { 'unknown error' }
        throw "$Step failed: $err"
    }
}

function Get-FirstSelectableFileName {
    param($ListSourceFilesPayload)
    if ($null -eq $ListSourceFilesPayload -or -not $ListSourceFilesPayload.items) {
        return $null
    }

    foreach ($item in @($ListSourceFilesPayload.items)) {
        if ([string]$item.type -eq 'File' -and [string]$item.selection -ne 'All') {
            return [string]$item.name
        }
    }

    return $null
}

function Get-GridItemSelection {
    param(
        [Parameter(Mandatory)]
        $MainContentPayload,
        [Parameter(Mandatory)]
        [string] $FileName
    )

    $items = $MainContentPayload.mainContent.source.grid.items
    if (-not $items) {
        throw 'ui.mainContent source grid has no items.'
    }

    foreach ($item in @($items)) {
        if ([string]$item.name -eq $FileName) {
            return [string]$item.selection
        }
    }

    throw "File '$FileName' not found in ui.mainContent source grid."
}

function Test-FileSelectedInUi {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string] $FileName
    )

    $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSourceFiles')
    if (-not $list.ok) { return $false }

    $row = @($list.items | Where-Object { [string]$_.name -eq $FileName } | Select-Object -First 1)
    if ($row.Count -eq 0 -or [string]$row[0].selection -ne 'All') {
        return $false
    }

    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    if (-not $main.ok) { return $false }

    try {
        return (Get-GridItemSelection -MainContentPayload $main -FileName $FileName) -eq 'All'
    }
    catch {
        return $false
    }
}

function Assert-FileSelectedInUi {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string] $FileName,
        [Parameter(Mandatory)]
        [string] $Step,
        [int] $MaxWaitMs = 0,
        [int] $PollMs = 250
    )

    if ($MaxWaitMs -le 0) {
        $MaxWaitMs = $SelectionSyncMaxWaitMs
    }

    $deadline = [datetime]::UtcNow.AddMilliseconds($MaxWaitMs)
    do {
        if (Test-FileSelectedInUi -Exe $Exe -FileName $FileName) {
            return
        }

        Start-Sleep -Milliseconds $PollMs
    } while ([datetime]::UtcNow -lt $deadline)

    throw "Selection for '$FileName' did not sync between listSourceFiles and ui.mainContent within ${MaxWaitMs}ms ($Step)."
}

function Resolve-SourceRootName {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string] $PreferredName
    )

    $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('listSources')
    Assert-OkResponse -Response $list -Step 'listSources'

    foreach ($root in @($list.roots)) {
        if ([string]$root.name -eq $PreferredName) {
            return $PreferredName
        }
    }

    foreach ($root in @($list.roots)) {
        $name = [string]$root.name
        if ($name -and $name -ne 'Desktop') {
            return $name
        }
    }

    throw "listSources has no pivot root other than Desktop for soft-refresh test."
}

try {
    Initialize-ScanAgentE2eScenarioState -TestId 'SA-34'

    $exe = Resolve-ScanAgentDebugPath -CallingScriptRoot $PSScriptRoot -Path $ScanAgentDebug
    Write-TestStep "ScanAgentDebug: $exe"

    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec $GatewayWaitSec -Context 'SA-34 startup' -NudgeReconnect
    Invoke-ScanAgentE2eWaitUiReady -Exe $exe -Context 'SA-34 after gateway'

    $pivotRoot = Resolve-SourceRootName -Exe $exe -PreferredName $PivotRootName
    Write-TestStep "Pivot root for cache bust: $pivotRoot"

    Write-TestStep 'Prime Desktop (first load)'
    $selectDesktop1 = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', 'Desktop', '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDesktop1 -Step 'selectSource Desktop (prime)'

    $listPrime = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listPrime -Step 'listSourceFiles (prime)'

    $targetFile = Get-FirstSelectableFileName -ListSourceFilesPayload $listPrime
    if ([string]::IsNullOrWhiteSpace($targetFile)) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $marker = Join-Path $desktop 'ncp7379-selection-marker.txt'
        Set-Content -LiteralPath $marker -Value "NCP-7379 marker $(Get-Date -Format o)" -Encoding UTF8
        Write-TestStep "Created marker file on Desktop: $marker"

        $selectDesktopRefresh = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
            'selectSource', '--name', 'Desktop', '--wait-ms', "$UiWaitMs", '--wait-loaded'
        )
        Assert-OkResponse -Response $selectDesktopRefresh -Step 'selectSource Desktop (after marker)'

        $listPrime = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSourceFiles')
        Assert-OkResponse -Response $listPrime -Step 'listSourceFiles (after marker)'
        $targetFile = Get-FirstSelectableFileName -ListSourceFilesPayload $listPrime
    }

    if ([string]::IsNullOrWhiteSpace($targetFile)) {
        throw 'No selectable file on Desktop for selection test.'
    }

    Write-TestStep "Target file: $targetFile"

    Write-TestStep "Leave Desktop to $pivotRoot"
    $selectPivot = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', $pivotRoot, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectPivot -Step "selectSource $pivotRoot"

    Write-TestStep 'Return to Desktop (cached root + background soft refresh)'
    $selectDesktop2 = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSource', '--name', 'Desktop', '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDesktop2 -Step 'selectSource Desktop (cached)'
    # Background soft refresh has no spinner; assert below retries until grid and folder VMs match.

    $clear = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection')
    Assert-OkResponse -Response $clear -Step 'clearSelection'

    Write-TestStep "selectSourceFile '$targetFile'"
    $selectFile = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSourceFile', '--name', $targetFile, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $selectFile -Step 'selectSourceFile'

    Assert-FileSelectedInUi -Exe $exe -FileName $targetFile -Step 'after selectSourceFile' `
        -MaxWaitMs $SelectionSyncMaxWaitMs -PollMs $SelectionSyncPollMs

    Write-TestStep "toggleSelection '$targetFile'"
    $toggle = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'ui.invoke', '--action', 'toggleSelection', '--name', $targetFile, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $toggle -Step 'toggleSelection (off)'

    $listAfterToggleOff = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('listSourceFiles')
    Assert-OkResponse -Response $listAfterToggleOff -Step 'listSourceFiles (toggle off)'
    $rowOff = @($listAfterToggleOff.items | Where-Object { [string]$_.name -eq $targetFile } | Select-Object -First 1)
    if ($rowOff.Count -eq 0 -or [string]$rowOff[0].selection -ne 'None') {
        throw "Expected selection None after toggle off for '$targetFile'."
    }

    $toggleOn = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'ui.invoke', '--action', 'toggleSelection', '--name', $targetFile, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $toggleOn -Step 'toggleSelection (on)'

    Assert-FileSelectedInUi -Exe $exe -FileName $targetFile -Step 'after toggle on' `
        -MaxWaitMs $SelectionSyncMaxWaitMs -PollMs $SelectionSyncPollMs

    $script:ScenarioPassed = $true
    Write-TestStep 'SA-34 / NCP-7379 scenario passed.'
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
}

Report-ScanAgentE2eScenarioToTestPlatform -ReportScriptPath $script:SaE2eReportScript `
    -TestId 'SA-34' -TestTitle 'NCP-7379 Desktop selection after soft refresh'

Exit-ScanAgentE2eScenario