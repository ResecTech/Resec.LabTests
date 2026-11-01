#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7353: MHTML with Html/Email CDR — debug sanitize and verify MHTML byte-patch path.

.DESCRIPTION
  Default: all fixtures in Core\Fixtures\MHT\NCP7353\manifest.json (UTF-8 smoke, EUC-JP 比較ビズ, ORICON).
  Pass -InputFile for a single file (legacy).
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $InputFile = '',
    [string] $FixtureRoot = '',
    [string] $OutputRoot = 'D:\out',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7353-mhtml-htmlcdr-lab',
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
    [switch] $SkipPolicyStack
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
. (Join-Path $commonRoot 'CoreE2eDebugHook.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7344Policy.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7353Policy.ps1')

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Test-ByteSubsequencePresent {
    param(
        [byte[]] $Haystack,
        [byte[]] $Needle
    )

    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) {
        return $false
    }

    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }

        if ($match) {
            return $true
        }
    }

    return $false
}

function Add-MhtmlSearchNeedlesFromBytes {
    param(
        [System.Collections.Generic.List[byte[]]] $Needles,
        [byte[]] $PayloadBytes
    )

    if ($PayloadBytes.Length -eq 0) {
        return
    }

    $null = $Needles.Add($PayloadBytes)
    $qpText = ($PayloadBytes | ForEach-Object { '=' + ('{0:X2}' -f $_) }) -join ''
    if (-not [string]::IsNullOrEmpty($qpText)) {
        $null = $Needles.Add([System.Text.Encoding]::ASCII.GetBytes($qpText))
    }
}

function Test-MhtmlOutputContainsText {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Text
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $needles = New-Object 'System.Collections.Generic.List[byte[]]'
    Add-MhtmlSearchNeedlesFromBytes -Needles $needles -PayloadBytes ([System.Text.Encoding]::UTF8.GetBytes($Text))

    $encodings = @(
        [System.Text.Encoding]::UTF8,
        [System.Text.Encoding]::ASCII
    )

    foreach ($name in @('euc-jp', 'shift_jis', 'iso-2022-jp')) {
        try {
            $encodings += [System.Text.Encoding]::GetEncoding($name)
        }
        catch {
            # skip unsupported code pages
        }
    }

    foreach ($encoding in $encodings) {
        Add-MhtmlSearchNeedlesFromBytes -Needles $needles -PayloadBytes ($encoding.GetBytes($Text))
    }

    foreach ($needle in $needles) {
        if (Test-ByteSubsequencePresent -Haystack $bytes -Needle $needle) {
            return $true
        }
    }

    return $false
}

function Get-Ncp7353FixtureStringList {
    param(
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $PropertyName
    )

    if ($null -eq $FixtureSpec) {
        return @()
    }

    if (-not ($FixtureSpec.PSObject.Properties.Name -contains $PropertyName)) {
        return @()
    }

    return @($FixtureSpec.$PropertyName)
}

function Assert-Ncp7353MhtmlFixtureOutput {
    param(
        [Parameter(Mandatory)]
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $InputPath,
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [Parameter(Mandatory)]
        $Result,
        [string] $CoreLogPath
    )

    $label = [string]$FixtureSpec.label
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = [System.IO.Path]::GetFileName($InputPath)
    }

    if ($Result.timedOut -eq $true) {
        throw "Timed out sanitizing '$label' (sanitizationId=$($Result.sanitizationId))."
    }

    $outcome = [string]$Result.outcome
    $details = [string]$Result.outcomeDetails
    foreach ($forbidden in (Get-Ncp7353FixtureStringList -FixtureSpec $FixtureSpec -PropertyName 'forbiddenOutcomes')) {
        if ($outcome -eq [string]$forbidden) {
            throw "Unexpected outcome '$outcome' for '$label'. Details: $details"
        }
    }

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Missing output for '$label': $OutputPath"
    }

    $inputHash = (Get-FileHash -LiteralPath $InputPath -Algorithm MD5).Hash
    $outputHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm MD5).Hash
    if ($outputHash -eq $inputHash) {
        throw "Output byte-identical to input for '$label' after HTML CDR; expected MHTML patch path."
    }

    $patchedLog = $false
    if ($CoreLogPath -and (Test-Path -LiteralPath $CoreLogPath)) {
        $patchedLog = [bool](Select-String -LiteralPath $CoreLogPath -Pattern 'MHTML: patching sanitized HTML' -Quiet)
    }

    if (-not $patchedLog) {
        throw "Expected Core log line 'MHTML: patching sanitized HTML' for '$label'."
    }

    foreach ($required in (Get-Ncp7353FixtureStringList -FixtureSpec $FixtureSpec -PropertyName 'requiredTextInOutput')) {
        if ([string]::IsNullOrWhiteSpace([string]$required)) {
            continue
        }

        if (-not (Test-MhtmlOutputContainsText -Path $OutputPath -Text ([string]$required))) {
            throw "Output for '$label' missing required text '$required'."
        }
    }

    $anyList = @(Get-Ncp7353FixtureStringList -FixtureSpec $FixtureSpec -PropertyName 'requiredTextInOutputAny' |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (@($anyList).Count -gt 0) {
        $anyHit = $false
        foreach ($candidate in $anyList) {
            if (Test-MhtmlOutputContainsText -Path $OutputPath -Text ([string]$candidate)) {
                $anyHit = $true
                break
            }
        }

        if (-not $anyHit) {
            $listed = ($anyList | ForEach-Object { [string]$_ }) -join ', '
            throw "Output for '$label' missing any required marker (checked: $listed)."
        }
    }

    Write-TestStep "OK '$label' -> outcome=$outcome outputMD5=$outputHash"
}

$hookUrl = $null
$policyStackPushed = $false

try {
    $fixtureSpecs = $null
    $fixtureRoot = $null

    if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
            throw "Input file not found: $InputFile"
        }

        $fixtureSpecs = @(
            [PSCustomObject]@{
                file                     = [System.IO.Path]::GetFileName($InputFile)
                label                    = 'custom-input'
                forbiddenOutcomes        = @('OutcomeBlockedTransformationFailed')
                requiredTextInOutput     = @()
                requiredTextInOutputAny  = @()
                _absoluteInputPath       = [System.IO.Path]::GetFullPath($InputFile)
            }
        )
    }
    else {
        if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
            $FixtureRoot = Join-Path $PSScriptRoot 'Fixtures\MHT\NCP7353'
        }

        $fixtureRoot = [System.IO.Path]::GetFullPath($FixtureRoot)
        $manifestPath = Join-Path $fixtureRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "manifest.json not found: $manifestPath"
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $fixtureSpecs = @($manifest.fixtures)
        if ($fixtureSpecs.Count -eq 0) {
            throw 'manifest.json contains no fixtures.'
        }
    }

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "Output: $outputRoot"
    if ($fixtureRoot) {
        Write-TestStep "Fixture root: $fixtureRoot"
    }

    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $policyStackPushed = $true
        }

        $jsonPath = Get-Ncp7353MhtmlHtmlCdrLabPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies: $jsonPath"
        Import-Ncp7353MhtmlHtmlCdrLabPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath -PolicyName $LabPolicyName | Out-Null
        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId.'
    }

    $coreLog = Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl

    foreach ($spec in $fixtureSpecs) {
        if ($spec.PSObject.Properties.Name -contains '_absoluteInputPath') {
            $inputPath = [string]$spec._absoluteInputPath
        }
        else {
            $inputPath = Join-Path $fixtureRoot ([string]$spec.file)
        }

        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "Fixture not found: $inputPath"
        }

        $outName = [System.IO.Path]::GetFileName($inputPath)
        $outputPath = Join-Path $outputRoot ('7353-' + ([string]$spec.label) + '-' + $outName)

        Write-TestStep "sanitize: $inputPath"
        $sanitizeParams = @{
            HookUrl        = $hookUrl
            FilePath       = $inputPath
            PolicyId       = $resolvedPolicyId
            OutputPath     = $outputPath
            TimeoutSeconds = $SanitizeTimeoutSec
        }
        if ($DeploymentId -gt 0) {
            $sanitizeParams.DeploymentId = $DeploymentId
        }

        $result = Invoke-CoreE2eSanitizeFile @sanitizeParams
        Write-TestStep "outcome=$($result.outcome) details=$($result.outcomeDetails) elapsedMs=$($result.elapsedMs)"

        Assert-Ncp7353MhtmlFixtureOutput -FixtureSpec $spec -InputPath $inputPath -OutputPath $outputPath -Result $result -CoreLogPath $coreLog
    }

    if ($coreLog -and (Test-Path -LiteralPath $coreLog)) {
        $mhtmlLines = Select-String -LiteralPath $coreLog -Pattern 'MHTML:|htmlBodyReassembly|Aspose.*Save|PatchHtml' |
            Select-Object -Last 25
        if ($mhtmlLines) {
            Write-TestStep 'Recent Core MHTML log lines:'
            $mhtmlLines | ForEach-Object { Write-Host "  $($_.Line)" }
        }
    }

    Write-Host "Scenario passed: $($fixtureSpecs.Count) MHTML fixture(s), HTML CDR + byte patch."
    exit 0
}
catch {
    Write-Error "Scenario failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($policyStackPushed -and $hookUrl) {
        try {
            Write-TestStep 'poppolicystate'
            Pop-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "poppolicystate: $($_.Exception.Message)"
        }
    }
}
