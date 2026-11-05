#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7365: Exercise every policy assignment (PolicyConditions) field via Core REST simulate and file-size sanitize.

.DESCRIPTION
  Covers [NCP-7365](https://resec.atlassian.net/browse/NCP-7365) (File: Size condition matching any size):
    - Imports lab policies plus one assignment rule per schema field (see PolicyConditionsSchemaProvider).
    - File-size rules use WebMC wire shape (target magnitude + unit, e.g. 500/MB, 4/KB) — not pre-expanded byte strings.
    - For each field, POST /v1/policies/conditions/simulate with matching and non-matching context (WebMC Simulation path).
    - Runs debug sanitize with a sub-4 KiB file and a 5 KiB file to assert the file_size rule only matches when StoredFile size exceeds the threshold.

  Prerequisites:
    - Core with EnableDebugInterface (default hook https://localhost:4504/debug/hook). If Core is not running,
      the script starts Resec.Core.exe from RESEC_CORE_EXE_LOCATION / lab.local.json repo root (unless -SkipAutoStartCore).
    - At least one deployment row in the DB (for debug sanitize file-size phase).
    - WMC REST login defaults to resec_admin / resec_admin (override CORE_E2E_WMC_* or -WmcUser / -WmcPassword).

.EXAMPLE
  .\NCP7365-PolicyAssignmentConditions.ps1

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
    [string] $CoreExe = '',
    [switch] $SkipPolicyImport,
    [switch] $SkipPolicyStack,
    [switch] $SkipSanitizeFileSizeScenario,
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
. (Join-Path $commonRoot 'CoreE2eNcp7365Policy.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$coreRestBaseUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7365'
$script:TestTitle = 'Policy assignment conditions simulate + file size (NCP-7365)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function New-Ncp7365PaddedFile {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [int] $SizeBytes
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $fs.SetLength($SizeBytes)
    }
    finally {
        $fs.Dispose()
    }
}

function Assert-Ncp7365FileSizeSanitizeLog {
    param(
        [Parameter(Mandatory)]
        [string] $LogHistory,
        [Parameter(Mandatory)]
        [bool] $ExpectLargeFileRuleMatch,
        [Parameter(Mandatory)]
        [string] $FileLabel
    )

    $ruleToken = "Matched rule 'NCP7365-file-size-gt-4k'"
    $hasRule = $LogHistory -like "*$ruleToken*"
    if ($ExpectLargeFileRuleMatch -and -not $hasRule) {
        $pcLines = @(
            $LogHistory -split "`r?`n" |
                Where-Object { $_ -like '*PolicyConditions*' } |
                Select-Object -First 8
        )
        $pcHint = if (@($pcLines).Count -gt 0) { " PolicyConditions lines: $($pcLines -join ' | ')" } else { ' No PolicyConditions lines in sanitization log.' }
        throw "Sanitize $FileLabel : expected log to contain '$ruleToken' but PolicyConditions match line was missing.$pcHint"
    }

    if (-not $ExpectLargeFileRuleMatch -and $hasRule) {
        throw "Sanitize $FileLabel : file_size rule matched unexpectedly (NCP-7365 regression). Log contains '$ruleToken'."
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    $coreRestBaseUrl = Get-CoreE2eCoreRestBaseUrl -HookUrl $hookUrl -Override $CoreRestBaseUrl
    $outputRoot = $OutputRoot
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        $outputRoot = Join-Path $env:TEMP ("CoreE2e-NCP7365-{0}" -f [Guid]::NewGuid().ToString('N'))
    }

    $outputRoot = [System.IO.Path]::GetFullPath($outputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    if (-not $SkipAutoStartCore) {
        Write-TestStep 'Ensure Core is running (auto-start Resec.Core.exe when debug hook is down)'
        Ensure-CoreE2eServerRunning -HookUrl $hookUrl -CoreExe $CoreExe | Out-Null
        Write-TestStep "Wait for Core ready: $hookUrl"
        Wait-CoreE2eReady -HookUrl $hookUrl -CoreExe $CoreExe -SkipInitialAutoStart | Out-Null
    }
    else {
        Write-TestStep "Wait for Core ready: $hookUrl"
        Wait-CoreE2eReady -HookUrl $hookUrl -CoreExe $CoreExe -SkipAutoStartCore | Out-Null
    }

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    Assert-CoreE2eDebugHookResponse -Response $versionInfo -Step 'version'
    $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
    Write-TestStep "Core version: $($versionInfo.version)"

    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        Write-TestStep 'importpolicies (NCP-7365 assignment rules)'
        Import-Ncp7365PolicyAssignmentLabPolicies -HookUrl $hookUrl | Out-Null
    }
    else {
        throw 'SkipPolicyImport is not supported for this test (assignment rules are required).'
    }

    Write-TestStep "WMC REST login: $coreRestBaseUrl"
    $apiToken = Connect-CoreE2eWmcRestSession -BaseUrl $coreRestBaseUrl -User $WmcUser -Password $WmcPassword

    $cases = Get-Ncp7365PolicyConditionSimulateCases
    Write-TestStep ("simulate: {0} condition field(s)" -f @($cases).Count)

    foreach ($case in $cases) {
        $label = [string]$case.Label
        Write-TestStep "simulate match: $label"
        $matchResponse = Invoke-CoreE2ePolicyConditionsSimulate -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -BodyObject $case.MatchBody
        Assert-CoreE2ePolicyConditionSimulateMatch -Response $matchResponse `
            -ExpectedRuleName ([string]$case.ExpectedRuleName) -ScenarioLabel $label

        Write-TestStep "simulate no-match: $label"
        $negativeResponse = Invoke-CoreE2ePolicyConditionsSimulate -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -BodyObject $case.NegativeBody
        Assert-CoreE2ePolicyConditionSimulateNoMatch -Response $negativeResponse -ScenarioLabel $label
    }

    if (-not $SkipSanitizeFileSizeScenario) {
        # Agent/user rules from the simulate import match first on a real deployment and shadow file_size.
        Write-TestStep 'importpolicies (file_size > 4 KiB rule only, for sanitize)'
        Import-Ncp7365SanitizeFileSizeLabPolicies -HookUrl $hookUrl | Out-Null

        $baselinePolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $script:Ncp7365LabPolicyName
        $smallPath = Join-Path $outputRoot 'ncp7365-small.bin'
        $largePath = Join-Path $outputRoot 'ncp7365-large.bin'
        New-Ncp7365PaddedFile -Path $smallPath -SizeBytes 1024
        New-Ncp7365PaddedFile -Path $largePath -SizeBytes 5120

        $sanitizeCommon = @{
            HookUrl        = $hookUrl
            PolicyId       = $baselinePolicyId
            TimeoutSeconds = $SanitizeTimeoutSec
        }
        if ($DeploymentId -gt 0) {
            $sanitizeCommon.DeploymentId = $DeploymentId
        }

        Write-TestStep 'sanitize small file (must not match file_size > 4 KiB rule)'
        $smallResult = Invoke-CoreE2eSanitizeFile @sanitizeCommon -FilePath $smallPath `
            -OutputPath (Join-Path $outputRoot 'out-small.bin')
        $smallLog = Get-CoreE2eSanitizationLogHistory -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -SanitizationId ([int]$smallResult.sanitizationId)
        Assert-Ncp7365FileSizeSanitizeLog -LogHistory $smallLog -ExpectLargeFileRuleMatch $false -FileLabel 'small'

        Write-TestStep 'sanitize large file (must match file_size > 4 KiB rule)'
        $largeResult = Invoke-CoreE2eSanitizeFile @sanitizeCommon -FilePath $largePath `
            -OutputPath (Join-Path $outputRoot 'out-large.bin')
        $largeLog = Get-CoreE2eSanitizationLogHistory -BaseUrl $coreRestBaseUrl -ApiToken $apiToken `
            -SanitizationId ([int]$largeResult.sanitizationId)
        Assert-Ncp7365FileSizeSanitizeLog -LogHistory $largeLog -ExpectLargeFileRuleMatch $true -FileLabel 'large'
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
        foreach ($autoStartLog in (Get-CoreE2eAutoStartProcessLogPaths)) {
            if (Test-Path -LiteralPath $autoStartLog) {
                $evidenceOnFailure += $autoStartLog
                Write-TestStep "Core auto-start process log: $autoStartLog"
            }
        }
        if (@($evidenceOnFailure).Count -gt 0) {
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7365'
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
            Write-Warning "Failed to remove output folder: $($_.Exception.Message)"
        }
    }
}
