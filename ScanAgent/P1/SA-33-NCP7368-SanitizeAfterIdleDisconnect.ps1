#Requires -Version 5.1
<#
.SYNOPSIS
  SA-33 / NCP-7368: First sanitization after idle gateway disconnect (Remain connected off).

.DESCRIPTION
  Imports lab policy NCP7368-idle with NumPropType_AutoReconnect=False, stages one allowed fixture file,
  navigates SMB source/destination in the UI, keeps the session quiet so the gateway idle-timer disconnects,
  then starts sanitization once and asserts the job completes with counts.selected=1 and counts.passed=1.

  Regression target: StartSanitization must reconnect and process on the first try while the gateway is down
  (Remain connected off). Default disconnect is Core commdown (not auto-reconnect); pass -UseIdleDisconnectTimer to
  wait for the 30s idle timer instead.

  Prerequisites:
    - Desktop Scan Agent with DebugInterface.Enabled = true and Core EnableDebugInterface.
    - Shared Fixtures (Allowed/*) or legacy SA-TestFiles.
    - WebMC template XML optional (same as SA-05 / SCANAGENT_SA05_POLICY_TEMPLATE_XML).

.NOTES
  Jira: NCP-7368.
  Exit 0 = passed; poppolicystate in finally when this script pushed policy state.
#>
[CmdletBinding()]
param(
    [string] $ScanAgentDebug = '',
    [switch] $SkipCorePolicySetup,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyTemplateXml = '',
    [string] $TemplatePolicyName = '',
    [string] $CorePolicyName = 'NCP7368-idle',
    [string] $TestFilesRoot = '',
    [int] $UiWaitMs = 120000,
    [int] $SanitizePollSec = 300,
    [int] $JobStartTimeoutSec = 30,
    [int] $JobStartStalledIdleSec = 20,
    [int] $GatewayReconnectAfterStartSec = 45,
    [switch] $UseIdleDisconnectTimer,
    [int] $IdleQuietSec = 40,
    [int] $IdleVerifyTimeoutSec = 45
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
. (Join-Path $script:SaE2eCommonRoot 'ScanAgentE2eNcp7368Policy.ps1')

$script:Ncp7368CorePolicyStackPushed = $false
$script:Ncp7368CoreDebugHookUrl = $null
$script:OriginalPolicyName = $null
$script:StagedSourceFileName = $null
$exe = $null
$labSourceRoot = $script:Ncp7368FolderIn
$labDestRoot = $script:Ncp7368FolderOut

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

function Wait-ScanAgentSanitizationJobStarted {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $TimeoutSec = 30,
        [int] $StalledIdleSec = 20
    )

    Write-TestStep "Wait for sanitization job to start (inProgress, running>0, or fast complete with selected>=1), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $stalledIdleSince = $null
    while ([datetime]::UtcNow -lt $deadline) {
        $status = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('sanitization.status')
        Assert-OkResponse -Response $status -Step 'sanitization.status'

        $running = [int]$status.counts.running
        $selected = [int]$status.counts.selected
        if ($status.inProgress -eq $true -or $status.state -eq 'running' -or $running -gt 0) {
            return $status
        }

        if ($status.state -eq 'complete' -and $status.sanitizationFinished -eq $true -and $selected -ge 1) {
            return $status
        }

        if ($status.state -eq 'complete' -and $status.sanitizationFinished -eq $true -and $selected -eq 0) {
            throw 'Sanitization finished with selected=0 (selection lost after reconnect?).'
        }

        if ($status.state -eq 'idle' -and $status.sanitizationFinished -eq $true -and $status.inProgress -eq $false -and $selected -eq 0) {
            throw 'Sanitization finished immediately without running (selection lost after reconnect?).'
        }

        if ($status.state -eq 'idle' -and $status.inProgress -eq $false -and $status.sanitizationFinished -ne $true) {
            if (-not $stalledIdleSince) {
                $stalledIdleSince = [datetime]::UtcNow
            }
            elseif (([datetime]::UtcNow - $stalledIdleSince).TotalSeconds -ge $StalledIdleSec) {
                $main = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.mainContent')
                $canStart = if ($main.ok -eq $true -and $main.mainContent) { $main.mainContent.canStartSanitization } else { '?' }
                throw "Job never left idle within ${StalledIdleSec}s after startSanitization (canStartSanitization=$canStart, selected=$($status.counts.selected))."
            }
        }
        else {
            $stalledIdleSince = $null
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Sanitization did not start within ${TimeoutSec}s (still idle / inProgress=false)."
}

function Wait-SanitizationComplete {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [int] $TimeoutSec,
        [int] $ExpectedSelected,
        [int] $StalledIdleSec = 90
    )

    Write-TestStep "Poll sanitization.status until complete (expected selected=$ExpectedSelected), timeout ${TimeoutSec}s"
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    $finalStatus = $null
    $stalledIdleSince = $null
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

        if ($status.state -eq 'idle' -and $status.inProgress -eq $false -and $status.sanitizationFinished -ne $true) {
            if (-not $stalledIdleSince) {
                $stalledIdleSince = [datetime]::UtcNow
            }
            elseif (([datetime]::UtcNow - $stalledIdleSince).TotalSeconds -ge $StalledIdleSec) {
                $sel = [int]$status.counts.selected
                throw "Sanitization stuck idle without starting within ${StalledIdleSec}s (selected=$sel, sanitizationFinished=$($status.sanitizationFinished))."
            }
        }
        else {
            $stalledIdleSince = $null
        }

        Write-Host "  state=$($status.state) selected=$($status.counts.selected) passed=$($status.counts.passed) blocked=$($status.counts.blocked) running=$($status.counts.running)"
    }

    if (-not $finalStatus) {
        throw "Sanitization did not reach complete within $TimeoutSec seconds."
    }

    $selected = [int]$finalStatus.counts.selected
    $passed = [int]$finalStatus.counts.passed
    $blocked = [int]$finalStatus.counts.blocked
    $running = [int]$finalStatus.counts.running
    Write-TestStep "Final counts: selected=$selected passed=$passed blocked=$blocked running=$running"

    if ($selected -ne $ExpectedSelected) {
        throw "counts.selected ($selected) does not match expected UI selection ($ExpectedSelected)."
    }

    if (($passed + $blocked) -ne $selected) {
        throw "passed+blocked ($($passed + $blocked)) does not match counts.selected ($selected)."
    }

    if ($running -ne 0) {
        throw "Expected no running items after completion; running=$running"
    }

    if ($passed -lt 1) {
        throw "Expected at least one passed outcome after idle-disconnect sanitize; passed=$passed selected=$selected"
    }

    return $finalStatus
}

function Clear-Ncp7368LabSourceFolder {
    param([Parameter(Mandatory)][string] $Folder)

    if (-not (Test-Path -LiteralPath $Folder)) {
        return
    }

    foreach ($existing in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue)) {
        if ($existing.Name -like '*-lab-folder.txt') {
            continue
        }
        Remove-Item -LiteralPath $existing.FullName -Force
    }
}

function Invoke-Ncp7368SelectCorePolicy {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][string] $PolicyName,
        [string] $Label
    )

    Write-TestStep "policy.select '$PolicyName' ($Label)"
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--name', $PolicyName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $select -Step "policy.select ($Label)"

    $ready = Invoke-ScanAgentDebug -Exe $Exe -Arguments @('waitReady', '--wait-ms', "$UiWaitMs", '--wait-loaded')
    if ($ready.ExitCode -ne 0) {
        throw "waitReady failed after policy select '$PolicyName' (exit $($ready.ExitCode)): $($ready.StdOut)"
    }
}

function Invoke-Ncp7368NavigateSmbPanels {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [string] $StepLabel
    )

    Write-TestStep "$StepLabel selectSource '$($script:Ncp7368StoreIn)'"
    $selectSource = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Ncp7368StoreIn, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSource -Step "$StepLabel selectSource"

    Write-TestStep "$StepLabel selectDestination '$($script:Ncp7368StoreOut)'"
    $selectDest = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectDestination', '--name', $script:Ncp7368StoreOut, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectDest -Step "$StepLabel selectDestination"

    Write-TestStep "$StepLabel return to source for file selection"
    $selectSourceAgain = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'selectSource', '--name', $script:Ncp7368StoreIn, '--wait-ms', "$UiWaitMs", '--wait-loaded'
    )
    Assert-OkResponse -Response $selectSourceAgain -Step "$StepLabel selectSource (selection)"
}

function Get-Ncp7368FixtureSourceFile {
    param([string] $OverrideRoot)

    $fixturesRoot = Resolve-SaTestFilesRootFolder -OverridePath $OverrideRoot
    $allowedRoot = Join-Path $fixturesRoot 'Allowed'
    if (-not (Test-Path -LiteralPath $allowedRoot)) {
        throw "Fixture Allowed folder not found under '$fixturesRoot'."
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $allowedRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -match '^\.(txt|csv|xml|json|pdf)$' -and
                $_.Name -notmatch '\.password\.' -and
                $_.Length -gt 0 -and $_.Length -lt 5MB
            } |
            Sort-Object FullName
    )

    if ($candidates.Count -lt 1) {
        throw "No suitable Allowed fixture file under '$allowedRoot'."
    }

    return $candidates[0]
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-33'

    $exe = Resolve-ScanAgentDebugPath -Path $ScanAgentDebug -CallingScriptRoot $PSScriptRoot
    Write-TestStep "Using ScanAgentDebug: $exe"

    $ping = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ping')
    Assert-OkResponse -Response $ping -Step 'ping'

    $agentInfo = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('agent.info')
    Assert-OkResponse -Response $agentInfo -Step 'agent.info'
    $e2eVersion = Register-ScanAgentE2eVersionFromAgentInfo -AgentInfo $agentInfo
    if ($e2eVersion) {
        Write-TestStep "Test Platform componentVersion: $e2eVersion"
    }

    $script:OriginalPolicyName = Register-ScanAgentE2eOriginalPolicyName -Exe $exe `
        -GatewayWaitSec 120 -GatewayWaitContext 'before SA-33 Core policy setup'

    if (-not $SkipCorePolicySetup) {
        Write-TestStep "Core lab policy setup: exportpolicystate → pushpolicystate → importpolicies ($CorePolicyName, Remain connected off)"
        $coreSetup = Initialize-ScanAgentNcp7368CoreTestPolicy -Exe $exe -CoreDebugHookUrl $CoreDebugHookUrl `
            -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
            -PolicyName $CorePolicyName -UiWaitMs $UiWaitMs
        $script:Ncp7368CorePolicyStackPushed = $true
        $script:Ncp7368CoreDebugHookUrl = $coreSetup.HookUrl
        $labSourceRoot = $coreSetup.SourceRoot
        $labDestRoot = $coreSetup.DestRoot

        $depth = if ($coreSetup.PushResponse.PSObject.Properties.Name -contains 'policyStateStackDepth') {
            $coreSetup.PushResponse.policyStateStackDepth
        } else { '?' }
        Write-TestStep "Core pushpolicystate OK (policyStateStackDepth=$depth); import base='$($coreSetup.PolicyBaseSource)'"

        $postExport = Export-ScanAgentCorePolicyState -CoreDebugHookUrl $script:Ncp7368CoreDebugHookUrl
        Write-ScanAgentCorePolicyHookJson -StepLabel 'Core exportpolicystate (after importpolicies; verify lab policy on Core)' -HookResponse $postExport

        $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec 180 -Context 'after NCP7368 Core import' -NudgeReconnect

        Invoke-Ncp7368SelectCorePolicy -Exe $exe -PolicyName $CorePolicyName -Label 'NCP7368 idle policy'
    }
    else {
        throw '-SkipCorePolicySetup is not supported for SA-33; policy must set NumPropType_AutoReconnect=False.'
    }

    $fixtureFile = Get-Ncp7368FixtureSourceFile -OverrideRoot $TestFilesRoot
    $script:StagedSourceFileName = $fixtureFile.Name
    Write-TestStep "Stage fixture '$($fixtureFile.FullName)' -> '$labSourceRoot'"
    Clear-Ncp7368LabSourceFolder -Folder $labSourceRoot
    Copy-Item -LiteralPath $fixtureFile.FullName -Destination (Join-Path $labSourceRoot $script:StagedSourceFileName) -Force

    Invoke-Ncp7368NavigateSmbPanels -Exe $exe -StepLabel 'NCP7368 SMB roots'
    Invoke-ScanAgentE2eRefreshSourceContent -Exe $exe -StepLabel 'refresh SMB source before selection'

    Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'clearSelection') | Out-Null
    $selectFile = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @(
        'selectSourceFile', '--name', $script:StagedSourceFileName, '--wait-ms', "$UiWaitMs"
    )
    Assert-OkResponse -Response $selectFile -Step 'selectSourceFile'

    $mainBefore = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.mainContent')
    Assert-OkResponse -Response $mainBefore -Step 'ui.mainContent before idle wait'
    if ($mainBefore.mainContent.canStartSanitization -ne $true) {
        throw 'canStartSanitization is false before idle disconnect; UI selection or destination not ready.'
    }

    Write-TestStep 'Record gateway connected before disconnect'
    $gwBefore = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('gateway.status')
    Assert-OkResponse -Response $gwBefore -Step 'gateway.status (before disconnect)'
    if ($gwBefore.isConnected -ne $true) {
        throw 'Expected gateway connected after UI setup; cannot test disconnected first sanitization.'
    }

    if ($UseIdleDisconnectTimer) {
        Write-TestStep 'Waiting for gateway idle timer disconnect (Remain connected off)'
        $null = Wait-ScanAgentGatewayDisconnected -Exe $exe -IdleQuietSec $IdleQuietSec `
            -VerifyTimeoutSec $IdleVerifyTimeoutSec -Context 'NCP-7368 idle timer'
    }
    else {
        Write-TestStep 'Core session drop (Remain connected off; no auto-reconnect)'
        Invoke-ScanAgentCoreSessionDropAndAdmissionsOn -HookUrl $script:Ncp7368CoreDebugHookUrl -Exe $exe `
            -Context 'NCP-7368 before first startSanitization'
    }

    Write-TestStep 'startSanitization (first attempt while gateway disconnected)'
    $start = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('ui.invoke', '--action', 'startSanitization')
    Assert-OkResponse -Response $start -Step 'startSanitization'
    if ($start.PSObject.Properties.Name -contains 'sanitizationInProgress' -and $start.sanitizationInProgress -ne $true) {
        Write-TestStep 'Note: startSanitization returned ok but sanitizationInProgress=false (job may still be starting on UI thread).'
    }

    $null = Wait-ScanAgentGatewayConnected -Exe $exe -TimeoutSec $GatewayReconnectAfterStartSec `
        -Context 'after startSanitization reconnect'

    $null = Wait-ScanAgentSanitizationJobStarted -Exe $exe -TimeoutSec $JobStartTimeoutSec `
        -StalledIdleSec $JobStartStalledIdleSec

    $finalStatus = Wait-SanitizationComplete -Exe $exe -TimeoutSec $SanitizePollSec -ExpectedSelected 1
    Write-TestStep "NCP-7368 first-run-after-idle-disconnect job OK; passed=$($finalStatus.counts.passed)"

    $script:ScenarioPassed = $true
    Write-TestStep 'SA-33 / NCP-7368 scenario passed.'
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-Error "Scenario failed: $($_.Exception.Message)"
}
finally {
    if ($script:Ncp7368CorePolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($script:Ncp7368CoreDebugHookUrl) -and
        -not [string]::IsNullOrWhiteSpace($exe)) {
        try {
            Write-TestStep "Core: poppolicystate (restore pushed policy snapshot) and agent policy '$($script:OriginalPolicyName)'"
            $pop = Restore-ScanAgentSa05CorePolicyStack -HookUrl $script:Ncp7368CoreDebugHookUrl
            Write-ScanAgentCorePolicyHookJson -StepLabel 'Core poppolicystate response' -HookResponse $pop
            if ([string]::IsNullOrWhiteSpace($script:OriginalPolicyName)) {
                Disconnect-AllCoreAgentsForRefresh -HookUrl $script:Ncp7368CoreDebugHookUrl -Exe $exe -GatewayWaitSec 30
            }
            else {
                Disconnect-AllCoreAgentsForRefresh -HookUrl $script:Ncp7368CoreDebugHookUrl -Exe $exe -GatewayWaitSec 30
                $null = Invoke-Ncp7368SelectCorePolicy -Exe $exe -PolicyName $script:OriginalPolicyName `
                    -Label 'restore pre-test policy after poppolicystate'
            }
        }
        catch {
            Write-Warning "Core policy restore failed: $($_.Exception.Message)"
        }
    }

    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed) {
        if ($labSourceRoot -and (Test-Path -LiteralPath $labSourceRoot)) { $evidenceOnFailure += $labSourceRoot }
        if ($labDestRoot -and (Test-Path -LiteralPath $labDestRoot)) { $evidenceOnFailure += $labDestRoot }
    }

    if ($script:ScenarioPassed) {
        try {
            Clear-Ncp7368LabSourceFolder -Folder $labSourceRoot
        }
        catch {
            Write-Warning "Source cleanup failed: $($_.Exception.Message)"
        }
    }
}

Report-ScanAgentE2eScenarioToTestPlatform -ReportScriptPath $script:SaE2eReportScript `
    -TestId 'SA-33' -TestTitle 'NCP-7368 sanitize after idle disconnect' -EvidencePathsOnFailure $evidenceOnFailure

Exit-ScanAgentE2eScenario
