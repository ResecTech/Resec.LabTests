#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7374: Cross-cluster temp file collision repro via debug sanitizecrosscluster (no second Core required for inprocess).

.DESCRIPTION
  Regression for [NCP-7374](https://resec.atlassian.net/browse/NCP-7374):
    - Portal enqueue then MQ worker leg (DEBUG crossClusterMode=inprocess) on Office-style fixtures.
    - Asserts no IOException / Temp\-N.x already exists in outcome or Core Serilog.
    - Optional parallel stress (-ParallelStress) runs multiple cross-cluster sanitizations back-to-back.

  Prerequisites:
    - Core with EnableDebugInterface and sanitizecrosscluster DEBUG hook (26.2+ lab build).
    - At least one deployment row in the DB.
    - Default policy: NCP-7344 no-CDR lab JSON (reused; Office fixtures from Fixtures\CrossCluster\NCP-7374 manifest).

.PARAMETER CrossClusterMode
  inprocess (default) or rabbit (requires MQ + second Core consumer).

.PARAMETER ParallelStress
  Repeat links.docx cross-cluster sanitize N times (manifest parallelStress.runCount) to surface races.

.PARAMETER SkipOptionalFixtures
  Do not run optional QA-only files when present in the fixture folder.

.EXAMPLE
  .\NCP7374-CrossClusterSanitize.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed. Copy Jira repro files into Fixtures\CrossCluster\NCP-7374\ for full QA parity.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $FixtureRoot = '',
    [string] $OutputRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7344-office-nocdr-lab',
    [string] $CrossClusterMode = '',
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 600,
    [switch] $SkipPolicyStack,
    [switch] $ParallelStress,
    [switch] $SkipOptionalFixtures,
    [switch] $ForceRemoteWorker
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
. (Join-Path $commonRoot 'CoreE2eNcp7344Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7374'
$script:TestTitle = 'Cross-cluster sanitize (sanitizecrosscluster) temp file (NCP-7374)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-Ncp7374FixtureRoot {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $full = [System.IO.Path]::GetFullPath($Override)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Fixture root not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_FIXTURE_ROOT)) {
        $full = [System.IO.Path]::GetFullPath($env:CORE_E2E_FIXTURE_ROOT.Trim())
        if (Test-Path -LiteralPath $full) {
            return $full
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-LabFixturesRoot) 'CrossCluster\NCP-7374'))
}

function Get-Ncp7374FixtureSpecValue {
    param(
        [Parameter(Mandatory)]
        $Spec,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Spec) {
        return $null
    }

    if ($Spec -is [System.Collections.IDictionary]) {
        if ($Spec.Contains($Name)) {
            return $Spec[$Name]
        }
        return $null
    }

    $prop = $Spec.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Resolve-Ncp7374FixturePath {
    param(
        [Parameter(Mandatory)]
        $Spec,
        [Parameter(Mandatory)]
        [string] $Root
    )

    $relativeSource = [string](Get-Ncp7374FixtureSpecValue -Spec $Spec -Name 'relativeSource')
    if (-not [string]::IsNullOrWhiteSpace($relativeSource)) {
        return [System.IO.Path]::GetFullPath((Join-Path $Root $relativeSource))
    }

    $fileName = [string](Get-Ncp7374FixtureSpecValue -Spec $Spec -Name 'file')
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw 'Fixture spec must include relativeSource or file.'
    }

    return Join-Path $Root $fileName
}

function Assert-Ncp7374CrossClusterSanitizeResult {
    param(
        [Parameter(Mandatory)]
        $Result,
        [Parameter(Mandatory)]
        $Manifest,
        [Parameter(Mandatory)]
        [string] $FileLabel,
        [Parameter(Mandatory)]
        [string] $ExpectedCrossClusterMode,
        [Parameter(Mandatory)]
        $FixtureSpec
    )

    if ($Result.timedOut -eq $true) {
        throw "Timed out cross-cluster sanitizing '$FileLabel' (sanitizationId=$($Result.sanitizationId))."
    }

    $mode = [string]$Result.crossClusterMode
    if (-not [string]::IsNullOrWhiteSpace($mode) -and $mode -ne $ExpectedCrossClusterMode) {
        throw "crossClusterMode mismatch for '$FileLabel': expected '$ExpectedCrossClusterMode', got '$mode'."
    }

    $processingServer = [string]$Result.processingServer
    if ([string]::IsNullOrWhiteSpace($processingServer)) {
        throw "processingServer was empty for '$FileLabel' (worker leg did not run)."
    }

    $queueName = [string]$Result.crossClusterQueueName
    $queuePrefix = [string]$Manifest.requiredCrossClusterQueuePrefix
    if ($ExpectedCrossClusterMode -eq 'inprocess' -and -not [string]::IsNullOrWhiteSpace($queuePrefix)) {
        if ([string]::IsNullOrWhiteSpace($queueName) -or $queueName -notlike "*$queuePrefix*") {
            throw "Expected crossClusterQueueName to contain '$queuePrefix' for inprocess; got '$queueName' ($FileLabel)."
        }
    }

    $outcome = [string]$Result.outcome
    $details = [string]$Result.outcomeDetails

    foreach ($pattern in @($Manifest.forbiddenOutcomeDetailsPatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($details) -and $details -match $pattern) {
            throw "Outcome details for '$FileLabel' matched forbidden pattern '$pattern'. Outcome=$outcome Details=$details"
        }
    }

    $expectedRaw = Get-Ncp7374FixtureSpecValue -Spec $FixtureSpec -Name 'expectedOutcomes'
    $expected = @(@($expectedRaw) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($expected).Count -gt 0 -and ($expected -notcontains $outcome)) {
        throw "Unexpected outcome '$outcome' for '$FileLabel' (expected one of: $($expected -join ', ')). Details: $details"
    }

    Write-TestStep "OK '$FileLabel' crossCluster -> outcome=$outcome processingServer=$processingServer queue=$queueName"
}

function Assert-Ncp7374CoreLogClean {
    param(
        [Parameter(Mandatory)]
        [string] $CoreLogPath,
        [Parameter(Mandatory)]
        $Manifest,
        [string] $MarkAfterUtc
    )

    if (-not (Test-Path -LiteralPath $CoreLogPath -PathType Leaf)) {
        Write-TestStep "Core log not available for forbidden-pattern scan: $CoreLogPath"
        return
    }

    $lines = Get-Content -LiteralPath $CoreLogPath -Encoding UTF8
    foreach ($pattern in @($Manifest.forbiddenLogPatterns)) {
        foreach ($line in $lines) {
            if ($line -match $pattern) {
                throw "Core log matched forbidden pattern '$pattern': $line"
            }
        }
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $fixtureRoot = Get-Ncp7374FixtureRoot -Override $FixtureRoot
    $manifestPath = Join-Path $fixtureRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "manifest.json not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $clusterMode = if ([string]::IsNullOrWhiteSpace($CrossClusterMode)) {
        [string]$manifest.defaultCrossClusterMode
    }
    else {
        $CrossClusterMode.Trim().ToLowerInvariant()
    }

    if ($clusterMode -notin @('inprocess', 'rabbit')) {
        throw "Invalid CrossClusterMode '$clusterMode'."
    }

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7374-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Fixtures: $fixtureRoot"
    Write-TestStep "Output: $outputRoot"
    Write-TestStep "crossClusterMode: $clusterMode"

    Write-TestStep 'Wait for Core ready'
    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-TestStep "Core version: $($versionInfo.version)"
    }

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        $jsonPath = Get-Ncp7344OfficeNoCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies from JSON: $jsonPath"
        Import-Ncp7344OfficeNoCdrLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $forceRemote = $true
    if ($PSBoundParameters.ContainsKey('ForceRemoteWorker')) {
        $forceRemote = [bool]$ForceRemoteWorker
    }

    $coreLogBefore = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
    Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Step 'NCP7374' -Mark "crossClusterMode=$clusterMode before fixtures"

    foreach ($spec in @($manifest.fixtures)) {
        $fixturePath = Resolve-Ncp7374FixturePath -Spec $spec -Root $fixtureRoot
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw "Fixture file missing: $fixturePath"
        }

        $label = [string](Get-Ncp7374FixtureSpecValue -Spec $spec -Name 'id')
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = [System.IO.Path]::GetFileName($fixturePath)
        }
        $outputPath = Join-Path $outputRoot $label
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
        $outFile = Join-Path $outputPath ([System.IO.Path]::GetFileName($fixturePath))

        Write-TestStep "sanitizecrosscluster: $label"
        $ccParams = @{
            HookUrl            = $hookUrl
            FilePath           = $fixturePath
            PolicyId           = $resolvedPolicyId
            CrossClusterMode   = $clusterMode
            ForceRemoteWorker  = $forceRemote
            OutputPath         = $outFile
            TimeoutSeconds     = $SanitizeTimeoutSec
        }
        if ($DeploymentId -gt 0) {
            $ccParams.DeploymentId = $DeploymentId
        }

        $result = Invoke-CoreE2eSanitizeCrossCluster @ccParams
        Assert-Ncp7374CrossClusterSanitizeResult -Result $result -Manifest $manifest -FileLabel $label `
            -ExpectedCrossClusterMode $clusterMode -FixtureSpec $spec
    }

    if (-not $SkipOptionalFixtures) {
        foreach ($opt in @($manifest.optionalFixtures)) {
            $optPath = Resolve-Ncp7374FixturePath -Spec $opt -Root $fixtureRoot
            if (-not (Test-Path -LiteralPath $optPath -PathType Leaf)) {
                Write-TestStep "Skip optional fixture (not present): $optPath"
                continue
            }

            $label = [string](Get-Ncp7374FixtureSpecValue -Spec $opt -Name 'id')
            Write-TestStep "sanitizecrosscluster optional: $label"
            $result = Invoke-CoreE2eSanitizeCrossCluster -HookUrl $hookUrl -FilePath $optPath -PolicyId $resolvedPolicyId `
                -CrossClusterMode $clusterMode -ForceRemoteWorker $forceRemote -TimeoutSeconds $SanitizeTimeoutSec
            Assert-Ncp7374CrossClusterSanitizeResult -Result $result -Manifest $manifest -FileLabel $label `
                -ExpectedCrossClusterMode $clusterMode -FixtureSpec $opt
        }
    }

    if ($ParallelStress -and $null -ne $manifest.parallelStress) {
        $stressPath = Resolve-Ncp7374FixturePath -Spec @{
            relativeSource = [string]$manifest.parallelStress.fileRelativeSource
        } -Root $fixtureRoot
        if (-not (Test-Path -LiteralPath $stressPath -PathType Leaf)) {
            throw "Parallel stress fixture missing: $stressPath"
        }

        $runCount = [int]$manifest.parallelStress.runCount
        if ($runCount -lt 2) {
            $runCount = 2
        }

        Write-TestStep "Parallel stress: $runCount x sanitizecrosscluster on $([System.IO.Path]::GetFileName($stressPath))"
        $jobs = @()
        for ($i = 0; $i -lt $runCount; $i++) {
            $jobs += Invoke-CoreE2eSanitizeCrossCluster -HookUrl $hookUrl -FilePath $stressPath `
                -PolicyId $resolvedPolicyId -CrossClusterMode $clusterMode -ForceRemoteWorker $forceRemote `
                -TimeoutSeconds $SanitizeTimeoutSec
        }

        $stressSpec = @{}
        $n = 0
        foreach ($jobResult in $jobs) {
            $n++
            Assert-Ncp7374CrossClusterSanitizeResult -Result $jobResult -Manifest $manifest `
                -FileLabel "parallel-stress-$n" -ExpectedCrossClusterMode $clusterMode -FixtureSpec $stressSpec
            foreach ($pattern in @($manifest.forbiddenOutcomeDetailsPatterns)) {
                $details = [string]$jobResult.outcomeDetails
                if (-not [string]::IsNullOrWhiteSpace($details) -and $details -match $pattern) {
                    throw "Parallel stress run $n matched forbidden pattern '$pattern'. Details: $details"
                }
            }
        }
    }

    $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl
    if ($coreLog) {
        Assert-Ncp7374CoreLogClean -CoreLogPath $coreLog -Manifest $manifest -MarkAfterUtc ''
        Write-TestStep "Core log scan OK: $coreLog"
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
        if (@($evidenceOnFailure).Count -gt 0) {
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7374'
            if ($script:EvidenceZipPath) {
                Write-TestStep "Evidence zip: $($script:EvidenceZipPath)"
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
            Write-Warning "Could not remove output folder '$outputRoot': $($_.Exception.Message)"
        }
    }
}
