#Requires -Version 5.1
<#
.SYNOPSIS
  Shared UI navigation helpers for Scan Agent E2E scripts (refresh + openFolder).
#>
Set-StrictMode -Version Latest

function Invoke-ScanAgentE2eRefreshDestinationContent {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $StepLabel = 'refreshDestinationContent'
    )

    if (Get-Command -Name Write-TestStep -ErrorAction SilentlyContinue) {
        Write-TestStep $StepLabel
    }

    $refresh = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'refreshDestinationContent'
    )
    Assert-OkResponse -Response $refresh -Step $StepLabel
    Invoke-ScanAgentE2eWaitUiReady -Exe $Exe -Context $StepLabel
}

function Invoke-ScanAgentE2eRefreshSourceContent {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $StepLabel = 'refreshSourceContent'
    )

    if (Get-Command -Name Write-TestStep -ErrorAction SilentlyContinue) {
        Write-TestStep $StepLabel
    }

    $refresh = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'refreshSourceContent'
    )
    Assert-OkResponse -Response $refresh -Step $StepLabel
    Invoke-ScanAgentE2eWaitUiReady -Exe $Exe -Context $StepLabel
}

function Invoke-ScanAgentE2eWaitUiReady {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $Context = 'waitReady'
    )

    if (-not (Get-Command -Name Invoke-ScanAgentDebug -ErrorAction SilentlyContinue)) {
        return
    }

    $uiWaitMs = 120000
    if (Get-Variable -Name UiWaitMs -Scope Script -ErrorAction SilentlyContinue) {
        $uiWaitMs = [int]$script:UiWaitMs
    }

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$uiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        $detail = if ($ready.StdOut) { $ready.StdOut } else { $ready.StdErr }
        throw "waitReady failed ($Context): exit $($ready.ExitCode) $detail"
    }
}

function Invoke-NavigateDestinationSegments {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string[]] $Segments,
        [Parameter(Mandatory)]
        [string] $StepPrefix
    )

    foreach ($segment in @($Segments)) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        Invoke-ScanAgentE2eRefreshDestinationContent -Exe $Exe `
            -StepLabel "$StepPrefix refresh destination before openFolder -> $segment"

        $uiWaitMs = 120000
        if (Get-Variable -Name UiWaitMs -Scope Script -ErrorAction SilentlyContinue) {
            $uiWaitMs = [int]$script:UiWaitMs
        }

        Write-TestStep "$StepPrefix openFolder -> $segment"
        $open = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            'ui.invoke', '--action', 'openFolder', '--panel', 'destination', '--name', $segment, '--wait-ms', "$uiWaitMs"
        )
        Assert-OkResponse -Response $open -Step "$StepPrefix openFolder ($segment)"
    }
}
