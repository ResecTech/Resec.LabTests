#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7374: Repro cross-portal Local:: PutFile (ExistingFile -> GetExternalPathToFile temp collision).

.DESCRIPTION
  Uses DEBUG sanitizecrosscluster with reproNcp7374CrossPortalPutFile (synthetic portalServerOverride),
  Office spreadsheet CDR, and Local:: destination — same shape as QA SendPutFile + CDR worker output
  without a second Core.

  Default (-AssertBugReproduced): PASS when signals match (bug still present). Use -AssertBugFixed after
  patching ExistingFile.GetExternalPathToFile (CopyTo overwrite) to guard regression.

.PARAMETER AssertBugFixed
  Expect sanitization success and no repro signals in Core log (post-fix regression mode).

.PARAMETER AssertBugReproduced
  Expect failure signatures (default on unpatched builds).

.EXAMPLE
  .\NCP7374-CrossPortalPutFileRepro.ps1

.NOTES
  Exit 0 = scenario met expectations; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $FixtureRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7374-office-cdr-local-putfile-lab',
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 600,
    [switch] $SkipPolicyStack,
    [switch] $AssertBugFixed,
    [switch] $AssertBugReproduced
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-CoreDeployRequirements
}

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')

$commonRoot = Join-Path $PSScriptRoot 'Common'
$script:CoreE2eReportScript = Join-Path $commonRoot 'Report-CoreE2eTestPlatformResult.ps1'
. $script:CoreE2eReportScript
. (Join-Path $commonRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7374PutfilePolicy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$script:TestId = 'Core-NCP7374-PutFileRepro'
$script:TestTitle = 'NCP-7374 cross-portal PutFile temp collision repro'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-Ncp7374PutfileReproFixtureRoot {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $full = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Fixture root not found: $full"
        }
        return $full
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-LabFixturesRoot) 'CrossCluster\NCP-7374'))
}

function Test-Ncp7374PutfileReproSignals {
    param(
        [Parameter(Mandatory)]
        $SanitizeResponse,
        [Parameter(Mandatory)]
        [string] $CoreLogPath,
        [Parameter(Mandatory)]
        [string[]] $Patterns
    )

    $hits = New-Object System.Collections.Generic.List[string]

    $detail = [string]$SanitizeResponse.outcomeDetails
    $outcome = [string]$SanitizeResponse.outcome
    if ($outcome -eq 'OutcomeFailSaveAccessToDestinationDenied') {
        $hits.Add("outcome=$outcome")
    }

    foreach ($pattern in $Patterns) {
        if ($detail -match $pattern) {
            $hits.Add("outcomeDetails:$pattern")
        }
    }

    if (Test-Path -LiteralPath $CoreLogPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $CoreLogPath -Encoding UTF8) {
            foreach ($pattern in $Patterns) {
                if ($line -match $pattern) {
                    $hits.Add("log:$pattern")
                    break
                }
            }
        }
    }

    if ($hits.Count -eq 0) {
        return @()
    }

    return [string[]]($hits.ToArray() | Select-Object -Unique)
}

$expectRepro = $true
if ($PSBoundParameters.ContainsKey('AssertBugFixed')) {
    $expectRepro = -not $AssertBugFixed
}
elseif ($PSBoundParameters.ContainsKey('AssertBugReproduced')) {
    $expectRepro = [bool]$AssertBugReproduced
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $fixtureRoot = Get-Ncp7374PutfileReproFixtureRoot -Override $FixtureRoot
    $manifestPath = Join-Path $fixtureRoot 'putfile-repro-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "putfile-repro-manifest.json not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Mode: expectRepro=$expectRepro (AssertBugFixed=$($PSBoundParameters.ContainsKey('AssertBugFixed')))"

    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        Import-Ncp7374OfficeCdrLocalPutfileLabPolicy -HookUrl $hookUrl -PolicyImportJson $PolicyImportJson `
            -PolicyName $LabPolicyName | Out-Null
        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $coreLogBefore = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
    Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Step 'NCP7374-PutFileRepro' -Mark "expectRepro=$expectRepro"

    $spec = $manifest.fixtures[0]
    $rel = [string]$spec.relativeSource
    $fixturePath = [System.IO.Path]::GetFullPath((Join-Path $fixtureRoot $rel))
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Fixture not found: $fixturePath"
    }

    $destName = [string]$manifest.destinationName
    if ([string]::IsNullOrWhiteSpace($destName)) {
        $destName = 'Local::'
    }

    Write-TestStep "sanitizecrosscluster (reproNcp7374CrossPortalPutFile): $fixturePath"
    $response = Invoke-CoreE2eSanitizeCrossCluster -HookUrl $hookUrl -FilePath $fixturePath -PolicyId $resolvedPolicyId `
        -CrossClusterMode 'inprocess' -ForceRemoteWorker $true -DestinationName $destName `
        -ReproNcp7374CrossPortalPutFile $true -TimeoutSeconds $SanitizeTimeoutSec -DeploymentId $DeploymentId

    if ([string]::IsNullOrWhiteSpace([string]$response.portalServerOverrideApplied)) {
        throw 'portalServerOverrideApplied missing from hook response — Core build may lack NCP-7374 repro hook fields.'
    }

    Write-TestStep "portalServerOverrideApplied=$($response.portalServerOverrideApplied) outcome=$($response.outcome)"

    $coreLogPath = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
    $signals = @(Test-Ncp7374PutfileReproSignals -SanitizeResponse $response -CoreLogPath $coreLogPath `
        -Patterns @($manifest.reproSignalPatterns))
    $signalCount = $signals.Length

    if ($expectRepro) {
        if ($signalCount -eq 0) {
            throw "Bug not reproduced: no signals matched. Outcome=$($response.outcome) Details=$($response.outcomeDetails)"
        }
        Write-TestStep "Repro signals ($signalCount): $($signals -join '; ')"
    }
    else {
        if ($signalCount -gt 0) {
            throw "Regression: repro signals still present: $($signals -join '; ')"
        }
        $okOutcomes = @('OutcomePassed', 'OutcomeClean', 'OutcomePartiallyProcessed')
        if ($okOutcomes -notcontains [string]$response.outcome) {
            throw "Unexpected outcome after fix: $($response.outcome) — $($response.outcomeDetails)"
        }
        Write-TestStep 'Bug fixed: sanitization succeeded without repro signals.'
    }

    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    Write-TestStep "FAILED: $($_.Exception.Message)"
    exit 1
}
finally {
    $evidenceOnFailure = @()
    if (-not $script:ScenarioPassed) {
        if (-not [string]::IsNullOrWhiteSpace($hookUrl)) {
            $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
            if ($coreLog) {
                $evidenceOnFailure += $coreLog
                Write-TestStep "Core log for evidence: $coreLog"
            }
        }
        if (@($evidenceOnFailure).Count -gt 0) {
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7374-PutFileRepro'
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
}

if ($script:ScenarioPassed) {
    exit 0
}
exit 1
