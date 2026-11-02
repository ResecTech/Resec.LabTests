#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7353: MHTML with Html/Email CDR — debug sanitize and verify MHTML byte-patch path.

.DESCRIPTION
  Default: all fixtures in Core\Fixtures\MHT\NCP7353\manifest.json (script stripping, UTF-8 smoke, EUC-JP, ORICON).
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

function Get-Ncp7353FixtureOptionalBool {
    param(
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $PropertyName,
        [bool] $Default = $false
    )

    if ($null -eq $FixtureSpec -or -not ($FixtureSpec.PSObject.Properties.Name -contains $PropertyName)) {
        return $Default
    }

    return [bool]$FixtureSpec.$PropertyName
}

function Get-Ncp7353FixtureOptionalInt {
    param(
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $PropertyName,
        [int] $Default = 0
    )

    if ($null -eq $FixtureSpec -or -not ($FixtureSpec.PSObject.Properties.Name -contains $PropertyName)) {
        return $Default
    }

    return [int]$FixtureSpec.$PropertyName
}

function Get-MhtmlHtmlScriptOpenTagCount {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::Latin1.GetString($bytes)
    return [regex]::Matches($text, '<script\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
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
    $allowIdentical = Get-Ncp7353FixtureOptionalBool -FixtureSpec $FixtureSpec -PropertyName 'allowOutputIdenticalToInput' -Default $false
    if (-not $allowIdentical -and $outputHash -eq $inputHash) {
        throw "Output byte-identical to input for '$label'; expected sanitized repack."
    }

    $expectHtmlPatchLog = Get-Ncp7353FixtureOptionalBool -FixtureSpec $FixtureSpec -PropertyName 'expectHtmlPatchLog' -Default $true
    $expectEmbeddedPatchLog = Get-Ncp7353FixtureOptionalBool -FixtureSpec $FixtureSpec -PropertyName 'expectEmbeddedPartPatchLog' -Default $false

    $patchedHtmlLog = $false
    $patchedEmbeddedLog = $false
    if ($CoreLogPath -and (Test-Path -LiteralPath $CoreLogPath)) {
        $patchedHtmlLog = [bool](Select-String -LiteralPath $CoreLogPath -Pattern 'MHTML: patching sanitized HTML' -Quiet)
        $patchedEmbeddedLog = [bool](Select-String -LiteralPath $CoreLogPath -Pattern 'MHTML: patching sanitized embedded MIME parts' -Quiet)
    }

    if ($expectHtmlPatchLog -and -not $patchedHtmlLog) {
        throw "Expected Core log line 'MHTML: patching sanitized HTML' for '$label'."
    }

    if ($expectEmbeddedPatchLog -and -not $patchedEmbeddedLog -and ($allowIdentical -or $outputHash -eq $inputHash)) {
        throw "Expected embedded MIME repack for '$label' (Core log 'MHTML: patching sanitized embedded MIME parts' and/or output bytes changed)."
    }

    foreach ($absent in (Get-Ncp7353FixtureStringList -FixtureSpec $FixtureSpec -PropertyName 'requiredAbsentInOutput')) {
        if ([string]::IsNullOrWhiteSpace([string]$absent)) {
            continue
        }

        if (Test-MhtmlOutputContainsText -Path $OutputPath -Text ([string]$absent)) {
            throw "Output for '$label' still contains disallowed marker '$absent'."
        }
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

    if (Get-Ncp7353FixtureOptionalBool -FixtureSpec $FixtureSpec -PropertyName 'requireScriptsRemoved') {
        $minInput = Get-Ncp7353FixtureOptionalInt -FixtureSpec $FixtureSpec -PropertyName 'minInputScriptTags' -Default 1
        $maxOutput = Get-Ncp7353FixtureOptionalInt -FixtureSpec $FixtureSpec -PropertyName 'maxOutputScriptTags' -Default 0
        $inputScripts = Get-MhtmlHtmlScriptOpenTagCount -Path $InputPath
        $outputScripts = Get-MhtmlHtmlScriptOpenTagCount -Path $OutputPath

        if ($inputScripts -lt $minInput) {
            throw "Input for '$label' expected at least $minInput '<script' tags, found $inputScripts."
        }

        if ($outputScripts -gt $maxOutput) {
            throw "Output for '$label' expected at most $maxOutput '<script' tags after Html CDR, found $outputScripts."
        }

        Write-TestStep "Scripts '$label': input=$inputScripts output=$outputScripts (max allowed $maxOutput)"
    }

    Write-TestStep "OK '$label' -> outcome=$outcome output=$OutputPath outputMD5=$outputHash"
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

    Write-TestStep 'Waiting for Core startup (ready)...'
    Wait-CoreE2eReady -HookUrl $hookUrl -LogMarkStep 'NCP7353-MhtmlHtmlCdrSanitize' | Out-Null
    Write-TestStep 'Core ready (coreInitialized=true)'

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
        $outputPath = [System.IO.Path]::GetFullPath((Join-Path $outputRoot ('7353-' + ([string]$spec.label) + '-' + $outName)))

        Write-TestStep "sanitize: $inputPath"
        Write-TestStep "output: $outputPath"
        Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Step ([string]$spec.label) -Mark "before sanitize $outName"
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
        if ($result.outputPath -and (Test-Path -LiteralPath $result.outputPath -PathType Leaf)) {
            $note = [string]$result.outputPathNote
            if ([string]::IsNullOrWhiteSpace($note)) {
                Write-TestStep "Output written: $($result.outputPath)"
            }
            else {
                Write-TestStep "Output written: $($result.outputPath) ($note)"
            }
        }

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

    Write-Host "Scenario passed: $($fixtureSpecs.Count) MHTML fixture(s), HTML/embedded MIME byte patch."
    exit 0
}
catch {
    if ($_.Exception.Message -match 'actively refused|No connection could be made') {
        Write-Error @"
Scenario failed: Core debug hook is not reachable.
Start Core in DEBUG (HTTPS port 4504) and re-run:
  cd $($PSScriptRoot)
  .\NCP7353-MhtmlHtmlCdrSanitize.ps1 -OutputRoot D:\out
Original error: $($_.Exception.Message)
"@
    }
    else {
        Write-Error "Scenario failed: $($_.Exception.Message)"
    }
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
