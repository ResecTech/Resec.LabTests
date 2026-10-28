#Requires -Version 5.1
<#
.SYNOPSIS
  SA-32 (P3) / NCP-7328: Source and destination drive dropdown — 0 / 1 / many policy roots.

.DESCRIPTION
  Imports lab policies via Core debug hooks (same push/import/commdown pattern as SA-05):
    NCP7328-one   — one SMB source + one SMB destination (chevron disabled)
    NCP7328-multi — two SMB sources + two SMB destinations (chevron enabled)

  Note: a policy with all location facets stripped still gets default local roots from Core on this
  agent build, so this script does not assert a literal "zero roots" case. Use one vs multi for
  disabled vs enabled drive dropdown.

  For each policy, asserts navbar drive-switcher state through ScanAgentDebug:
    ui.mainContent (canOpenRootLocationList, hasRootLocationFlyoutContent, rootLocations)
    listSources / listDestinations
    ui.invoke rootLocationFlyoutPreview (flyout list matches navbar; NCP-7328 regression target)

  Multi-root policies also select each root via selectSource / selectDestination.

  NCP-7335 (multi-root): after the first manual root pick, rootLocationFlyoutPreview is invoked
  twice per panel (simulates opening the drive dropdown again) and must stay enabled with list content.

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled = true and gateway connected to Core.
    - Core EnableDebugInterface for /debug/hook.
    - WebMC export XML with Scan Agent template (SCANAGENT_SA05_POLICY_TEMPLATE_XML or C:\resec\ImportExport).

.NOTES
  Jira: NCP-7328 — drive dropdown empty / chevron state vs policy roots.
  Jira: NCP-7335 — drive dropdown does not reopen after first manual root selection.
  Exit 0 = passed. Core poppolicystate in finally when this script pushed policy state.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [int] $UiWaitMs = 120000
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
. (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eNcp7328Policy.ps1')

$script:Ncp7328CorePolicyStackPushed = $false
$script:Ncp7328CoreDebugHookUrl = $null
$script:OriginalPolicyName = $null
$exe = $null

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

function Get-SelectableRootNamesFromListPayload {
    param($ListPayload)

    return @(
        $ListPayload.roots |
            Where-Object {
                $_.isAccessible -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$_.name)
            } |
            ForEach-Object { [string]$_.name }
    )
}

function Get-NavbarFromMainContent {
    param(
        $MainContent,
        [ValidateSet('source', 'destination')]
        [string] $Panel
    )

    $panelObj = if ($Panel -eq 'source') { $MainContent.mainContent.source } else { $MainContent.mainContent.destination }
    if ($null -eq $panelObj) {
        throw "ui.mainContent missing panel '$Panel'."
    }
    return $panelObj.navbar
}

function Invoke-SelectPolicyByName {
    param(
        [string] $Exe,
        [Parameter(Mandatory)]
        [string] $PolicyName,
        [string] $Label
    )

    Write-TestStep "policy.select '$PolicyName' ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--name', $PolicyName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $select -Step "policy.select ($Label)"
    $current = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.current')
    Assert-OkResponse -Response $current -Step "policy.current ($Label)"
    if (-not [string]$current.policy.name.Equals($PolicyName, [StringComparison]::Ordinal)) {
        throw "policy.current name '$($current.policy.name)' does not match '$PolicyName' ($Label)."
    }
}

function Invoke-RootLocationFlyoutPreview {
    param(
        [string] $Exe,
        [ValidateSet('source', 'destination')]
        [string] $Panel
    )

    return Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'ui.invoke', '--action', 'rootLocationFlyoutPreview', '--panel', $Panel
    )
}

function Assert-RootDropdownScenario {
    param(
        [string] $Exe,
        [string] $ScenarioLabel,
        [int] $ExpectedSelectableRootCount,
        [string[]] $ExpectedSourceRootNames,
        [string[]] $ExpectedDestinationRootNames,
        [bool] $ExpectCanOpenRootList
    )

    Write-TestStep "Assert root dropdown scenario: $ScenarioLabel"

    $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $main -Step "ui.mainContent ($ScenarioLabel)"

    foreach ($panel in @('source', 'destination')) {
        $navbar = Get-NavbarFromMainContent -MainContent $main -Panel $panel
        $expectedNames = if ($panel -eq 'source') { @($ExpectedSourceRootNames) } else { @($ExpectedDestinationRootNames) }

        if ([int]$navbar.selectableRootLocationCount -ne $ExpectedSelectableRootCount) {
            throw "$ScenarioLabel / $panel navbar.selectableRootLocationCount expected $ExpectedSelectableRootCount, got $($navbar.selectableRootLocationCount)."
        }
        if ([bool]$navbar.canOpenRootLocationList -ne $ExpectCanOpenRootList) {
            throw "$ScenarioLabel / $panel canOpenRootLocationList expected $ExpectCanOpenRootList, got $($navbar.canOpenRootLocationList)."
        }

        $expectFlyoutContent = $ExpectedSelectableRootCount -gt 0
        if ([bool]$navbar.hasRootLocationFlyoutContent -ne $expectFlyoutContent) {
            throw "$ScenarioLabel / $panel hasRootLocationFlyoutContent expected $expectFlyoutContent, got $($navbar.hasRootLocationFlyoutContent)."
        }

        $listOp = if ($panel -eq 'source') { 'listSources' } else { 'listDestinations' }
        $listPayload = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @($listOp)
        Assert-OkResponse -Response $listPayload -Step "$listOp ($ScenarioLabel)"

        $listedNames = @(Get-SelectableRootNamesFromListPayload -ListPayload $listPayload)
        $expectedSorted = @($expectedNames | Sort-Object)
        $listedSorted = @($listedNames | Sort-Object)
        if (($expectedSorted -join '|') -ne ($listedSorted -join '|')) {
            throw "$ScenarioLabel / $listOp root names mismatch. Expected: [$($expectedSorted -join ', ')]. Actual: [$($listedSorted -join ', ')]."
        }

        $flyout = Invoke-RootLocationFlyoutPreview -Exe $Exe -Panel $panel
        Assert-OkResponse -Response $flyout -Step "rootLocationFlyoutPreview ($ScenarioLabel / $panel)"

        if ([bool]$flyout.canOpenRootLocationList -ne $ExpectCanOpenRootList) {
            throw "$ScenarioLabel / $panel flyout preview canOpenRootLocationList expected $ExpectCanOpenRootList."
        }
        if ([bool]$flyout.hasRootLocationFlyoutContent -ne $expectFlyoutContent) {
            throw "$ScenarioLabel / $panel flyout preview hasRootLocationFlyoutContent expected $expectFlyoutContent."
        }
        if ($expectFlyoutContent) {
            if ($flyout.hasListContent -ne $true) {
                throw "$ScenarioLabel / $panel flyout preview hasListContent expected true when roots exist."
            }
            if ($flyout.emptyStateVisible -eq $true) {
                throw "$ScenarioLabel / $panel flyout preview should not show empty state when roots exist (NCP-7328)."
            }
        }
        else {
            if ($flyout.hasListContent -eq $true) {
                throw "$ScenarioLabel / $panel flyout preview hasListContent expected false when no roots."
            }
            if ($flyout.emptyStateVisible -ne $true) {
                throw "$ScenarioLabel / $panel flyout preview should show empty state when no selectable roots."
            }
        }

        $flyoutNames = @($flyout.rootNames | ForEach-Object { [string]$_ } | Sort-Object)
        if (($flyoutNames -join '|') -ne ($expectedSorted -join '|')) {
            throw "$ScenarioLabel / $panel flyout rootNames mismatch. Expected: [$($expectedSorted -join ', ')]. Actual: [$($flyoutNames -join ', ')]."
        }

        if ($ExpectCanOpenRootList -and $listedNames.Count -gt 1) {
            $firstRoot = $expectedNames[0]
            Assert-FlyoutReopensAfterRootSelection -Exe $Exe -Panel $panel -SelectedRootName $firstRoot -ScenarioLabel $ScenarioLabel
            Assert-CanSelectEachRoot -Exe $Exe -Panel $panel -RootNames $listedNames -ScenarioLabel $ScenarioLabel
        }
    }
}

function Assert-FlyoutReopensAfterRootSelection {
    param(
        [string] $Exe,
        [ValidateSet('source', 'destination')]
        [string] $Panel,
        [string] $SelectedRootName,
        [string] $ScenarioLabel
    )

    $selectVerb = if ($Panel -eq 'source') { 'selectSource' } else { 'selectDestination' }

    Write-TestStep "$ScenarioLabel - NCP-7335 $selectVerb '$SelectedRootName' then flyout preview x2 ($Panel)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        $selectVerb, '--name', $SelectedRootName, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $select -Step "$selectVerb $SelectedRootName ($ScenarioLabel / NCP-7335)"

    foreach ($openAttempt in 1..2) {
        $flyout = Invoke-RootLocationFlyoutPreview -Exe $Exe -Panel $Panel
        Assert-OkResponse -Response $flyout -Step "rootLocationFlyoutPreview reopen $openAttempt ($ScenarioLabel / $Panel / NCP-7335)"

        if ($flyout.canOpenRootLocationList -ne $true) {
            throw "NCP-7335: after first root selection, canOpenRootLocationList must stay true on $Panel (open attempt $openAttempt)."
        }
        if ($flyout.hasListContent -ne $true) {
            throw "NCP-7335: flyout preview must still list roots on $Panel (open attempt $openAttempt)."
        }
        if ($flyout.wouldNavigateOnCurrentRootReselect -eq $true) {
            throw "NCP-7335: flyout must not treat current-root reselect as navigation on $Panel (open attempt $openAttempt)."
        }
    }
}

function Assert-CanSelectEachRoot {
    param(
        [string] $Exe,
        [ValidateSet('source', 'destination')]
        [string] $Panel,
        [string[]] $RootNames,
        [string] $ScenarioLabel
    )

    $selectVerb = if ($Panel -eq 'source') { 'selectSource' } else { 'selectDestination' }
    $listOp = if ($Panel -eq 'source') { 'listSources' } else { 'listDestinations' }

    foreach ($rootName in $RootNames) {
        Write-TestStep "$ScenarioLabel - $selectVerb '$rootName'"
        $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
            $selectVerb, '--name', $rootName, '--wait-ms', "$UiWaitMs", '--wait-loaded'
        )
        Assert-OkResponse -Response $select -Step "$selectVerb $rootName ($ScenarioLabel)"

        $listAfter = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @($listOp)
        Assert-OkResponse -Response $listAfter -Step "$listOp after $selectVerb ($ScenarioLabel)"
        $selected = @($listAfter.roots | Where-Object { $_.isSelected -eq $true })
        if ((Get-CollectionCount $selected) -ne 1) {
            throw "Expected one selected root on $Panel after $selectVerb '$rootName'."
        }
        if (-not [string]$selected[0].name.Equals($rootName, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Selected $Panel root '$($selected[0].name)' does not match '$rootName' ($ScenarioLabel)."
        }
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-32'

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 120 -Context 'before NCP7328 scenario' -NudgeReconnect

    $policyCurrentStart = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.current')
    Assert-OkResponse -Response $policyCurrentStart -Step 'policy.current (initial)'
    $script:OriginalPolicyName = [string]$policyCurrentStart.policy.name

    if (-not $SkipCorePolicySetup) {
        Write-TestStep 'Core: pushpolicystate + import NCP7328-one / NCP7328-multi policies'
        $coreSetup = Initialize-ScanAgentNcp7328CoreTestPolicies -Exe $exe -CoreDebugHookUrl $CoreDebugHookUrl `
            -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName -UiWaitMs $UiWaitMs
        $script:Ncp7328CorePolicyStackPushed = $true
        $script:Ncp7328CoreDebugHookUrl = $coreSetup.HookUrl
        Write-TestStep "Core lab policies imported (policyBase='$($coreSetup.PolicyBaseSource)')"
    }
    else {
        Write-TestStep 'SkipCorePolicySetup: assuming NCP7328-one and NCP7328-multi already on Core'
        $null = Wait-ScanAgentPolicyListContainsNames -Exe $exe -PolicyNames @(
            $script:Ncp7328PolicyOne,
            $script:Ncp7328PolicyMulti
        ) -UiWaitMs $UiWaitMs
    }

    $scenarios = @(
        @{
            PolicyName                     = $script:Ncp7328PolicyOne
            Label                          = 'one source and one destination'
            ExpectedSelectableRootCount    = 1
            ExpectedSourceRootNames        = @($script:Ncp7328StoreInA)
            ExpectedDestinationRootNames   = @($script:Ncp7328StoreOutA)
            ExpectCanOpenRootList          = $false
        },
        @{
            PolicyName                     = $script:Ncp7328PolicyMulti
            Label                          = 'two sources and two destinations'
            ExpectedSelectableRootCount    = 2
            ExpectedSourceRootNames        = @($script:Ncp7328StoreInA, $script:Ncp7328StoreInB)
            ExpectedDestinationRootNames   = @($script:Ncp7328StoreOutA, $script:Ncp7328StoreOutB)
            ExpectCanOpenRootList          = $true
        }
    )

    foreach ($scenario in $scenarios) {
        Invoke-SelectPolicyByName -Exe $exe -PolicyName $scenario.PolicyName -Label $scenario.Label
        Assert-RootDropdownScenario -Exe $exe -ScenarioLabel $scenario.Label `
            -ExpectedSelectableRootCount $scenario.ExpectedSelectableRootCount `
            -ExpectedSourceRootNames $scenario.ExpectedSourceRootNames `
            -ExpectedDestinationRootNames $scenario.ExpectedDestinationRootNames `
            -ExpectCanOpenRootList $scenario.ExpectCanOpenRootList
    }

    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    throw
}
finally {
    try {
        Complete-ScanAgentE2eTest -TestId 'SA-32' -TestTitle 'NCP7328 root location drive dropdown (0/1/many)' `
            -Passed:$script:ScenarioPassed -FailureMessage $script:ScenarioFailureMessage `
            -StartedAtUtc $script:TestStartedAtUtc -RunLogPath $script:E2eRunLogPath
    }
    finally {
        Stop-ScanAgentE2eRunLog
    }

    if ($script:Ncp7328CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Ncp7328CoreDebugHookUrl)) {
        try {
            Write-TestStep 'Core: poppolicystate + agent reconnect + restore pre-test policy selection'
            if ($null -ne $exe) {
                Restore-ScanAgentCorePolicyLabAndAgent -HookUrl $script:Ncp7328CoreDebugHookUrl -Exe $exe `
                    -OriginalPolicyName $script:OriginalPolicyName -UiWaitMs $UiWaitMs | Out-Null
            }
            else {
                Restore-ScanAgentSa05CorePolicyStack -HookUrl $script:Ncp7328CoreDebugHookUrl | Out-Null
            }
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }
}

if ($script:ScenarioPassed) {
    Write-Host ''
    Write-Host 'SA-32 (NCP-7328) PASSED' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host 'SA-32 (NCP-7328) FAILED' -ForegroundColor Red
exit 1
