#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7408: Resubmit with a different policy bypasses PolicyConditions assignment rules.

.DESCRIPTION
  Imports block-scripts vs allow-scripts policies and a file_path rule that maps .ps1 files to the block policy.
  Debug-sanitize with the allow policy is overridden by assignment rules and blocks.
  WMC workflow Resubmit with the allow policy must keep that policy (log: Skipping assignment rules for resubmit).

  Prerequisites:
    - Core with EnableDebugInterface; WMC REST login (default resec_admin / resec_admin).
    - At least one deployment in the DB (debug sanitize).

.EXAMPLE
  .\NCP7408-ResubmitPolicyBypass.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $CoreRestBaseUrl = '',
    [string] $OutputRoot = '',
    [string] $WmcUser = '',
    [string] $WmcPassword = '',
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
    [int] $ResubmitTimeoutSec = 300,
    [string] $CoreExe = '',
    [switch] $SkipPolicyStack,
    [switch] $SkipAutoStartCore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-CoreDeployRequirements
}

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')

$commonRoot = Join-Path $PSScriptRoot 'Common'
$script:CoreE2eReportScript = Join-Path $commonRoot 'Report-CoreE2eTestPlatformResult.ps1'
. $script:CoreE2eReportScript
. (Join-Path $commonRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $commonRoot 'CoreE2ePortalApi.ps1')
. (Join-Path $commonRoot 'CoreE2eWmcApi.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7408Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$coreRestBaseUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7408'
$script:TestTitle = 'Resubmit bypasses policy assignment rules (NCP-7408)'
$script:CoreE2eWmcOutcomeBlockedByPolicy = 140
$script:CoreE2eWmcOutcomePassed = 100

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Find-Ncp7408ResubmitSanitizationId {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [int] $SourceSanitizationId,
        [int] $TimeoutSec = 300,
        [int] $MaxIdDelta = 50
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $pollIndex = 0

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pollIndex++
        for ($id = ($SourceSanitizationId + 1); $id -le ($SourceSanitizationId + $MaxIdDelta); $id++) {
            $logHistory = ''
            try {
                $logHistory = Get-CoreE2eSanitizationLogHistory -BaseUrl $BaseUrl -ApiToken $ApiToken -SanitizationId $id
            }
            catch {
                continue
            }

            if ($logHistory -like '*InternalDescription:resubmit*' `
                    -and $logHistory -like '*PolicyConditions: Skipping assignment rules for resubmit*') {
                Write-TestStep "Located resubmit sanitizationId=$id via log scan (poll $pollIndex)"
                return $id
            }
        }

        if ($pollIndex -eq 1 -or ($pollIndex % 10) -eq 0) {
            Write-TestStep "Scanning for resubmit sanitization after sourceId=$SourceSanitizationId (poll $pollIndex)"
        }

        Start-Sleep -Seconds 3
    }

    throw "Could not find resubmit sanitization after sourceId=$SourceSanitizationId within ${TimeoutSec}s."
}

function New-Ncp7408LabPs1File {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value '# NCP-7408 lab placeholder script' -Encoding UTF8
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $coreRestBaseUrl = Get-CoreE2eCoreRestBaseUrl -HookUrl $hookUrl -Override $CoreRestBaseUrl
    $outputRoot = $OutputRoot
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        $outputRoot = Join-Path $env:TEMP ("CoreE2e-NCP7408-{0}" -f [Guid]::NewGuid().ToString('N'))
    }

    $outputRoot = [System.IO.Path]::GetFullPath($outputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    if (-not $SkipAutoStartCore) {
        Write-TestStep 'Ensure Core is running'
        Ensure-CoreE2eServerRunning -HookUrl $hookUrl -CoreExe $CoreExe | Out-Null
        Wait-CoreE2eReady -HookUrl $hookUrl -CoreExe $CoreExe -SkipInitialAutoStart | Out-Null
    }
    else {
        Wait-CoreE2eReady -HookUrl $hookUrl -CoreExe $CoreExe -SkipAutoStartCore | Out-Null
    }

    if (-not $SkipPolicyStack) {
        Write-TestStep 'pushpolicystate'
        Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        $script:PolicyStackPushed = $true
    }

    Write-TestStep 'importpolicies (NCP-7408 block vs allow + .ps1 assignment rule)'
    Import-Ncp7408ResubmitPolicyLabPolicies -HookUrl $hookUrl | Out-Null

    $blockPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $script:Ncp7408BlockScriptsPolicyName
    $allowPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $script:Ncp7408AllowScriptsPolicyName
    Write-TestStep "Policy ids: block=$blockPolicyId allow=$allowPolicyId"

    $inputPath = Join-Path $outputRoot 'NCP7408-ResubmitPolicyBypass.ps1'
    New-Ncp7408LabPs1File -Path $inputPath

    $sanitizeParams = @{
        HookUrl        = $hookUrl
        FilePath       = $inputPath
        PolicyId       = $allowPolicyId
        TimeoutSeconds = $SanitizeTimeoutSec
    }
    if ($DeploymentId -gt 0) {
        $sanitizeParams.DeploymentId = $DeploymentId
    }

    Write-TestStep 'sanitize with allow policy (assignment rules should force block policy)'
    $firstResult = Invoke-CoreE2eSanitizeFile @sanitizeParams
    $firstSanitizationId = [int]$firstResult.sanitizationId
    if ($firstSanitizationId -le 0) {
        throw 'Initial sanitize did not create a sanitization id.'
    }

    $firstOutcomeValue = [int]$firstResult.outcomeValue
    if ($firstOutcomeValue -ne $script:CoreE2eWmcOutcomeBlockedByPolicy) {
        throw "Expected initial OutcomeBlockedByPolicy ($($script:CoreE2eWmcOutcomeBlockedByPolicy)), got outcome=$($firstResult.outcome) value=$firstOutcomeValue."
    }

    Write-TestStep 'WMC REST login'
    $apiToken = Connect-CoreE2eWmcRestSession -BaseUrl $coreRestBaseUrl -User $WmcUser -Password $WmcPassword

    Write-TestStep "resubmit sanitizationId=$firstSanitizationId with allow policyId=$allowPolicyId"
    $actionId = Invoke-CoreE2eWmcPerformWorkflowAction -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
        -SanitizationId $firstSanitizationId -Action $script:CoreE2eWmcWorkflowActionResubmit `
        -PolicyId $allowPolicyId

    $resubmitSanitizationId = 0
    $resubmitOutcome = ''
    try {
        $actionData = Wait-CoreE2eWmcWorkflowActionResult -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -ActionId $actionId -SanitizationId $firstSanitizationId -TimeoutSec $ResubmitTimeoutSec

        $resubmitSanitizationId = [int](Get-CoreE2eWmcRestPropertyValue -Object $actionData -Names @('sanitizationId', 'SanitizationId'))
        $resubmitOutcome = [string](Get-CoreE2eWmcRestPropertyValue -Object $actionData -Names @('outcome', 'Outcome'))
    }
    catch {
        Write-TestStep "Workflow result poll failed; falling back to log scan. $($_.Exception.Message)"
    }

    if ($resubmitSanitizationId -le 0) {
        $resubmitSanitizationId = Find-Ncp7408ResubmitSanitizationId -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -SourceSanitizationId $firstSanitizationId -TimeoutSec $ResubmitTimeoutSec
    }

    $logHistory = Get-CoreE2eSanitizationLogHistory -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
        -SanitizationId $resubmitSanitizationId

    if ([string]::IsNullOrWhiteSpace($resubmitOutcome) -or [int]$resubmitOutcome -lt 0) {
        # Workflow payload may be missing when we used the log-scan fallback.
        $resubmitOutcome = ''
    }
    elseif ([int]$resubmitOutcome -eq $script:CoreE2eWmcOutcomeBlockedByPolicy) {
        $details = [string](Get-CoreE2eWmcRestPropertyValue -Object $actionData -Names @('outcomeDetails', 'OutcomeDetails'))
        throw "Resubmit still blocked by policy (NCP-7408). sanitizationId=$resubmitSanitizationId details=$details"
    }

    if ($logHistory -notlike '*PolicyConditions: Skipping assignment rules for resubmit*') {
        throw "Resubmit log missing policy-assignment bypass line (sanitizationId=$resubmitSanitizationId)."
    }

    if ($logHistory -like '*PolicyConditions: Matched rule*switching to policy*') {
        throw "Resubmit log still contains PolicyConditions policy switch (sanitizationId=$resubmitSanitizationId)."
    }

    if ($logHistory -like '*Status:OutcomeBlockedByPolicy*' -or $logHistory -like '*Outcome:OutcomeBlockedByPolicy*') {
        throw "Resubmit sanitization $resubmitSanitizationId still shows OutcomeBlockedByPolicy in log (NCP-7408)."
    }

    if ([int]$resubmitOutcome -eq $script:CoreE2eWmcOutcomeBlockedByPolicy) {
        throw "Resubmit still blocked by policy (NCP-7408). sanitizationId=$resubmitSanitizationId"
    }

    Write-TestStep "OK resubmit sanitizationId=$resubmitSanitizationId outcome=$resubmitOutcome"
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
        if ($outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
            $evidenceOnFailure += $outputRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
            $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
            if ($coreLog) {
                $evidenceOnFailure += $coreLog
                Write-TestStep "Core log for evidence: $coreLog"
            }
        }
    }

    Invoke-ScanAgentE2eTestPlatformReportingFinally -ReportScriptPath $script:CoreE2eReportScript `
        -TestId $script:TestId -TestTitle $script:TestTitle -Passed:$script:ScenarioPassed `
        -FailureMessage $script:ScenarioFailureMessage -StartedAtUtc $script:TestStartedAtUtc `
        -RunLogPath $script:E2eRunLogPath -EvidencePathsOnFailure $evidenceOnFailure `
        -EvidenceZipPath $script:EvidenceZipPath

    if ($script:PolicyStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-TestStep 'poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        try {
            Remove-Item -LiteralPath $outputRoot -Recurse -Force
        }
        catch {
            Write-Warning "Failed to remove output folder: $($_.Exception.Message)"
        }
    }
}