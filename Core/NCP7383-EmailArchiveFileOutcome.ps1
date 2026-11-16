#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7383: Files tree — archive attachment shows Content Removed; .eml root must not.

.DESCRIPTION
  Regression for [NCP-7383](https://resec.atlassian.net/browse/NCP-7383):
    Lab EML with body (HTML/plain) plus embedded ZIP containing a policy-blocked inner file.
    After debug sanitize, embeddedObjects summary must show Content Removed on the archive row
    while the .eml container row stays Passed (body parts unchanged).

  Prerequisites:
    - Core DEBUG with EnableDebugInterface (hook https://localhost:4504).
    - Core build with NCP-7383 email root FileOutcome fix and sanitize includeEmbeddedSummary.

.EXAMPLE
  .\NCP7383-EmailArchiveFileOutcome.ps1

  Optional Jira parity: place 20261115125132oren490.eml in Fixtures\Mail\NCP-7383 and pass -UseJiraParityFixture.

  Scenarios (-Scenario):
    SingleBlocked       — one blocked ZIP attachment (baseline).
    OneAttachmentRemoved — blocked ZIP + clean ZIP; only the blocked archive shows Content Removed.
    AllAttachmentsRemoved — two blocked ZIPs; both show Content Removed; .eml root stays Passed.
    All (default)       — runs all three synthetic scenarios in one test.

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $OutputRoot = '',
    [string] $FixtureRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7383-email-embedded-archive-block-lab',
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 600,
    [switch] $SkipPolicyImport,
    [switch] $SkipPolicyStack,
    [switch] $UseJiraParityFixture,
    [ValidateSet('All', 'SingleBlocked', 'OneAttachmentRemoved', 'AllAttachmentsRemoved')]
    [string] $Scenario = 'All'
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
. (Join-Path $commonRoot 'CoreE2eNcp7383Policy.ps1')
. (Join-Path $commonRoot 'CoreE2eWmcApi.ps1')

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$script:TestId = 'Core-NCP7383'
$script:TestTitle = 'Email Files tree: Content Removed on archive only (NCP-7383)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Get-Ncp7383ManifestRoot {
    param([string] $OverrideRoot = '')

    $root = $OverrideRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_FIXTURE_ROOT)) {
            $root = $env:CORE_E2E_FIXTURE_ROOT
        }
        else {
            $root = Join-Path (Get-LabTestsRoot) 'Fixtures\Mail\NCP-7383'
        }
    }

    $root = [System.IO.Path]::GetFullPath($root)
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "NCP-7383 manifest not found: $manifestPath"
    }

    return @{
        Root     = $root
        Manifest = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
    }
}

function New-Ncp7383FixtureSpecFromManifest {
    param(
        [Parameter(Mandatory)]
        $Manifest,
        [int] $MinArchiveContentRemovedCount = 1,
        [int] $MinArchivePassedCount = 0
    )

    return @{
        ForbiddenEmailRootOutcomes    = @($Manifest.forbiddenEmailRootOutcomeNames)
        ForbiddenEmailRootOutcomeVals = @($Manifest.forbiddenEmailRootOutcomeValues | ForEach-Object { [int]$_ })
        RequiredArchiveOutcomes       = @($Manifest.requiredArchiveOutcomeNames)
        RequiredArchiveOutcomeVals    = @($Manifest.requiredArchiveOutcomeValues | ForEach-Object { [int]$_ })
        EmailRootNeedle               = [string]$Manifest.expectedEmailRootFileNameContains
        ArchiveNeedle                 = [string]$Manifest.expectedArchiveFileNameContains
        BodyNamePatterns              = @($Manifest.expectedPassedBodyNamePatterns)
        ArchiveDetailsPattern         = [string]$Manifest.requiredArchiveDetailsPattern
        MinArchiveContentRemovedCount = $MinArchiveContentRemovedCount
        MinArchivePassedCount         = $MinArchivePassedCount
    }
}

function Build-Ncp7383ScenarioEml {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('SingleBlocked', 'OneAttachmentRemoved', 'AllAttachmentsRemoved')]
        [string] $ScenarioName,
        [Parameter(Mandatory)]
        $Manifest,
        [Parameter(Mandatory)]
        [string] $ManifestRoot,
        [Parameter(Mandatory)]
        [string] $WorkOutputRoot
    )

    $blockedInner = [System.IO.Path]::GetFullPath((Join-Path $ManifestRoot ([string]$Manifest.innerBlockedFixtureRelative)))
    if (-not (Test-Path -LiteralPath $blockedInner -PathType Leaf)) {
        throw "NCP-7383 blocked inner fixture not found: $blockedInner"
    }

    $scenarioDir = Join-Path $WorkOutputRoot $ScenarioName
    New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null

    $attachments = @()
    $blockedZipName = 'ncp7383-blocked.zip'
    $blockedZipPath = Join-Path $scenarioDir $blockedZipName
    New-Ncp7383InnerFileZip -InnerFilePath $blockedInner -OutputZipPath $blockedZipPath
    $attachments += @{ ZipPath = $blockedZipPath; DisplayName = $blockedZipName }

    if ($ScenarioName -eq 'OneAttachmentRemoved' -or $ScenarioName -eq 'AllAttachmentsRemoved') {
        if ($ScenarioName -eq 'OneAttachmentRemoved') {
            $cleanInner = [System.IO.Path]::GetFullPath((Join-Path $ManifestRoot ([string]$Manifest.cleanAttachmentFixtureRelative)))
            if (-not (Test-Path -LiteralPath $cleanInner -PathType Leaf)) {
                throw "NCP-7383 clean attachment fixture not found: $cleanInner"
            }
            $cleanZipName = 'ncp7383-clean.zip'
            $cleanZipPath = Join-Path $scenarioDir $cleanZipName
            New-Ncp7383InnerFileZip -InnerFilePath $cleanInner -OutputZipPath $cleanZipPath
            $attachments += @{ ZipPath = $cleanZipPath; DisplayName = $cleanZipName }
        }
        elseif ($ScenarioName -eq 'AllAttachmentsRemoved') {
            $blockedZipName2 = 'ncp7383-blocked-2.zip'
            $blockedZipPath2 = Join-Path $scenarioDir $blockedZipName2
            New-Ncp7383InnerFileZip -InnerFilePath $blockedInner -OutputZipPath $blockedZipPath2
            $attachments += @{ ZipPath = $blockedZipPath2; DisplayName = $blockedZipName2 }
        }
    }

    $emlName = "ncp7383-$ScenarioName.eml"
    $emlPath = Join-Path $scenarioDir $emlName
    New-Ncp7383LabEmlWithZipAttachments -OutputPath $emlPath -Attachments $attachments -Subject "NCP-7383 $ScenarioName"

    $expectations = $Manifest.scenarioExpectations.$ScenarioName
    $spec = New-Ncp7383FixtureSpecFromManifest -Manifest $Manifest `
        -MinArchiveContentRemovedCount ([int]$expectations.minArchiveContentRemovedCount) `
        -MinArchivePassedCount ([int]$expectations.minArchivePassedCount)

    return @{
        ScenarioName = $ScenarioName
        EmlPath      = $emlPath
        FixtureSpec  = $spec
    }
}

function Get-Ncp7383JiraParityFixture {
    param(
        [Parameter(Mandatory)]
        $Manifest,
        [Parameter(Mandatory)]
        [string] $ManifestRoot
    )

    $jiraName = [string]$Manifest.jiraParityFixtureFile
    $jiraPath = Join-Path $ManifestRoot $jiraName
    if (-not (Test-Path -LiteralPath $jiraPath -PathType Leaf)) {
        throw "Jira parity EML not found: $jiraPath"
    }

    $spec = New-Ncp7383FixtureSpecFromManifest -Manifest $Manifest
    return @{
        ScenarioName = 'JiraParity'
        EmlPath      = $jiraPath
        FixtureSpec  = $spec
    }
}

function New-Ncp7383InnerFileZip {
    param(
        [Parameter(Mandatory)]
        [string] $InnerFilePath,
        [Parameter(Mandatory)]
        [string] $OutputZipPath
    )

    $dir = Split-Path -Parent $OutputZipPath
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $OutputZipPath) {
        Remove-Item -LiteralPath $OutputZipPath -Force
    }

    Compress-Archive -LiteralPath $InnerFilePath -DestinationPath $OutputZipPath -Force
}

function New-Ncp7383LabEmlWithZipAttachments {
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [Parameter(Mandatory)]
        [array] $Attachments,
        [string] $Subject = 'NCP-7383 lab embedded archive content removed'
    )

    if ($Attachments.Count -lt 1) {
        throw 'At least one ZIP attachment is required.'
    }

    $boundary = "----=_NCP7383_" + [Guid]::NewGuid().ToString('N')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('From: ncp7383-sender@test.local')
    [void]$sb.AppendLine('To: ncp7383-recipient@test.local')
    [void]$sb.AppendLine("Subject: $Subject")
    [void]$sb.AppendLine('MIME-Version: 1.0')
    [void]$sb.AppendLine("Content-Type: multipart/mixed; boundary=`"$boundary`"")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine('Content-Type: text/plain; charset=utf-8')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NCP-7383 lab plain body.')
    [void]$sb.AppendLine("--$boundary")
    [void]$sb.AppendLine('Content-Type: text/html; charset=utf-8')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('<html><body><p>NCP-7383 lab HTML body.</p></body></html>')

    foreach ($attachment in $Attachments) {
        $zipPath = [string]$attachment.ZipPath
        $displayName = [string]$attachment.DisplayName
        $bytes = [System.IO.File]::ReadAllBytes($zipPath)
        $b64 = [Convert]::ToBase64String($bytes)
        $b64Lines = [System.Text.RegularExpressions.Regex]::Split($b64, '(.{1,76})') |
            Where-Object { -not [string]::IsNullOrEmpty($_) }

        [void]$sb.AppendLine("--$boundary")
        [void]$sb.AppendLine('Content-Type: application/zip')
        [void]$sb.AppendLine('Content-Transfer-Encoding: base64')
        [void]$sb.AppendLine("Content-Disposition: attachment; filename=`"$displayName`"")
        [void]$sb.AppendLine('')
        foreach ($line in $b64Lines) {
            [void]$sb.AppendLine($line)
        }
    }

    [void]$sb.AppendLine("--$boundary--")

    $dir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

function Get-Ncp7383EmbeddedField {
    param(
        [Parameter(Mandatory)]
        $Row,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    return [string](Get-CoreE2eWmcRestPropertyValue -Object $Row -Names $Names)
}

function Get-Ncp7383OutcomeValue {
    param([Parameter(Mandatory)] $Row)

    $raw = Get-Ncp7383EmbeddedField -Row $Row -Names @('fileOutcomeValue', 'FileOutcomeValue')
    if ($raw -match '^\d+$') {
        return [int]$raw
    }

    $name = Get-Ncp7383EmbeddedField -Row $Row -Names @('fileOutcome', 'FileOutcome')
    switch -Regex ($name) {
        'OutcomePassed' { return 100 }
        'OutcomeContentRemoved' { return 103 }
        default {
            throw "Unsupported fileOutcome for row: $name"
        }
    }
}

function Assert-Ncp7383SanitizeResult {
    param(
        [Parameter(Mandatory)]
        $Result,
        [Parameter(Mandatory)]
        $FixtureSpec,
        [Parameter(Mandatory)]
        [string] $EmlFileName,
        [string] $ScenarioLabel = ''
    )

    if ($Result.timedOut -eq $true) {
        throw "Timed out sanitizing EML (sanitizationId=$($Result.sanitizationId))."
    }

    $embeddedRaw = Get-CoreE2eWmcRestPropertyValue -Object $Result -Names @('embeddedObjects', 'EmbeddedObjects')
    $embedded = @($embeddedRaw | Where-Object { $null -ne $_ })
    if ($embedded.Count -eq 0) {
        throw 'includeEmbeddedSummary returned no embeddedObjects; ensure Core build includes debug hook embedded summary.'
    }

    $emailRows = @($embedded | Where-Object {
            $fileName = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileName', 'FileName')
            $fileId = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileId', 'FileId')
            ($fileName -like "*$($FixtureSpec.EmailRootNeedle)*" -or $fileId -like "*$($FixtureSpec.EmailRootNeedle)*") -and
            $fileName -notlike "*$($FixtureSpec.ArchiveNeedle)*" -and
            $fileId -notlike "*$($FixtureSpec.ArchiveNeedle)*"
        })

    if ($emailRows.Count -eq 0) {
        throw "No .eml root row in embeddedObjects (needle '$($FixtureSpec.EmailRootNeedle)')."
    }

    $emailRoot = $emailRows | Where-Object {
            $fn = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileName', 'FileName')
            $fn -like "*$EmlFileName*" -or $fn -like "*$($FixtureSpec.EmailRootNeedle)*"
        } | Select-Object -First 1
    if (-not $emailRoot) {
        $emailRoot = $emailRows[0]
    }

    $rootOutcomeName = Get-Ncp7383EmbeddedField -Row $emailRoot -Names @('fileOutcome', 'FileOutcome')
    $rootOutcomeValue = Get-Ncp7383OutcomeValue -Row $emailRoot
    foreach ($forbiddenName in @($FixtureSpec.ForbiddenEmailRootOutcomes)) {
        if ($rootOutcomeName -eq $forbiddenName) {
            throw "Email root row shows forbidden outcome $forbiddenName (NCP-7383: .eml must not inherit archive Content Removed)."
        }
    }
    foreach ($forbiddenVal in @($FixtureSpec.ForbiddenEmailRootOutcomeVals)) {
        if ($rootOutcomeValue -eq $forbiddenVal) {
            throw "Email root row shows forbidden outcome value $forbiddenVal (expected Passed / 100)."
        }
    }

    $archiveRows = @($embedded | Where-Object {
            $fileName = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileName', 'FileName')
            $fileId = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileId', 'FileId')
            $fileName -like "*$($FixtureSpec.ArchiveNeedle)*" -or $fileId -like "*$($FixtureSpec.ArchiveNeedle)*"
        })

    if ($archiveRows.Count -eq 0) {
        $ids = ($embedded | ForEach-Object { Get-Ncp7383EmbeddedField -Row $_ -Names @('fileId', 'FileId') }) -join '; '
        throw "No embedded archive row in embeddedObjects (needle '$($FixtureSpec.ArchiveNeedle)'). Rows: $ids"
    }

    $contentRemovedArchiveRows = @()
    $passedArchiveRows = @()
    foreach ($row in $archiveRows) {
        $outcomeName = Get-Ncp7383EmbeddedField -Row $row -Names @('fileOutcome', 'FileOutcome')
        $outcomeValue = Get-Ncp7383OutcomeValue -Row $row
        $details = Get-Ncp7383EmbeddedField -Row $row -Names @('outcomeDetails', 'OutcomeDetails')
        $isContentRemoved = @($FixtureSpec.RequiredArchiveOutcomes) -contains $outcomeName -or
            @($FixtureSpec.RequiredArchiveOutcomeVals) -contains $outcomeValue
        if ($isContentRemoved) {
            if ([string]::IsNullOrWhiteSpace($FixtureSpec.ArchiveDetailsPattern) -or
                $details -match $FixtureSpec.ArchiveDetailsPattern) {
                $contentRemovedArchiveRows += $row
            }
        }
        elseif ($outcomeValue -eq 100) {
            $passedArchiveRows += $row
        }
    }

    $minRemoved = if ($null -ne $FixtureSpec.MinArchiveContentRemovedCount) {
        [int]$FixtureSpec.MinArchiveContentRemovedCount
    }
    else {
        1
    }
    $minPassed = if ($null -ne $FixtureSpec.MinArchivePassedCount) {
        [int]$FixtureSpec.MinArchivePassedCount
    }
    else {
        0
    }

    if ($contentRemovedArchiveRows.Count -lt $minRemoved) {
        $names = ($archiveRows | ForEach-Object { Get-Ncp7383EmbeddedField -Row $_ -Names @('fileOutcome', 'FileOutcome') }) -join ', '
        $label = if ($ScenarioLabel) { " [$ScenarioLabel]" } else { '' }
        throw "Expected at least $minRemoved archive row(s) with Content Removed$label; got $($contentRemovedArchiveRows.Count). Archive outcomes: $names"
    }

    if ($passedArchiveRows.Count -lt $minPassed) {
        $names = ($archiveRows | ForEach-Object { Get-Ncp7383EmbeddedField -Row $_ -Names @('fileOutcome', 'FileOutcome') }) -join ', '
        $label = if ($ScenarioLabel) { " [$ScenarioLabel]" } else { '' }
        throw "Expected at least $minPassed archive row(s) with Passed$label; got $($passedArchiveRows.Count). Archive outcomes: $names"
    }

    $bodyHits = 0
    foreach ($pattern in @($FixtureSpec.BodyNamePatterns)) {
        $bodyRow = $embedded | Where-Object {
            $fileName = Get-Ncp7383EmbeddedField -Row $_ -Names @('fileName', 'FileName')
            $fileName -like "*$pattern*"
        } | Select-Object -First 1
        if ($bodyRow) {
            $val = Get-Ncp7383OutcomeValue -Row $bodyRow
            if ($val -ne 100) {
                throw "Body part matching '$pattern' expected Passed (100), got $val."
            }
            $bodyHits++
        }
    }

    if ($bodyHits -eq 0) {
        Write-TestStep 'Warning: no explicit HTML/plain body rows in embedded summary (Jira parity EML may use different tree labels). Email root Passed assertion still applied.'
    }
    else {
        Write-TestStep "Body part Passed assertions OK ($bodyHits row(s))."
    }

    $scenarioSuffix = if ($ScenarioLabel) { " scenario=$ScenarioLabel" } else { '' }
    Write-TestStep "NCP-7383 assertions OK${scenarioSuffix}: .eml root=$rootOutcomeName ($rootOutcomeValue); archives ContentRemoved=$($contentRemovedArchiveRows.Count) Passed=$($passedArchiveRows.Count)."
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7383-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $manifestPack = Get-Ncp7383ManifestRoot -OverrideRoot $FixtureRoot

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl
    Write-TestStep "Hook: $hookUrl"

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

        $policyImport = Import-Ncp7383EmailEmbeddedArchiveBlockLabPolicy -HookUrl $hookUrl `
            -PolicyImportJson $PolicyImportJson -PolicyName $LabPolicyName
        Write-TestStep "importpolicies ($($policyImport.PolicySource))"

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $scenarioRuns = @()
    if ($UseJiraParityFixture) {
        $scenarioRuns += Get-Ncp7383JiraParityFixture -Manifest $manifestPack.Manifest -ManifestRoot $manifestPack.Root
    }
    else {
        $scenarioNames = switch ($Scenario) {
            'All' { @('SingleBlocked', 'OneAttachmentRemoved', 'AllAttachmentsRemoved') }
            default { @($Scenario) }
        }
        foreach ($scenarioName in $scenarioNames) {
            $scenarioRuns += Build-Ncp7383ScenarioEml -ScenarioName $scenarioName `
                -Manifest $manifestPack.Manifest -ManifestRoot $manifestPack.Root -WorkOutputRoot $outputRoot
        }
    }

    foreach ($run in $scenarioRuns) {
        Write-TestStep "=== Scenario: $($run.ScenarioName) ==="
        Write-TestStep "Fixture EML: $($run.EmlPath)"
        Write-CoreE2eDebugLogMark -HookUrl $hookUrl -Step 'NCP7383' -Mark "before sanitize $($run.ScenarioName)"

        Write-TestStep 'debug sanitize (includeEmbeddedSummary)'
        $sanitizeParams = @{
            HookUrl                = $hookUrl
            FilePath               = $run.EmlPath
            PolicyId               = $resolvedPolicyId
            TimeoutSeconds         = $SanitizeTimeoutSec
            IncludeEmbeddedSummary = $true
        }
        if ($DeploymentId -gt 0) {
            $sanitizeParams.DeploymentId = $DeploymentId
        }

        $sanitizeResult = Invoke-CoreE2eSanitizeFile @sanitizeParams
        Write-TestStep "Sanitize finished sanitizationId=$($sanitizeResult.sanitizationId) outcome=$($sanitizeResult.outcome) embeddedCount=$($sanitizeResult.numOfEmbeddedObjects)"

        $emlBaseName = [System.IO.Path]::GetFileName($run.EmlPath)
        Assert-Ncp7383SanitizeResult -Result $sanitizeResult -FixtureSpec $run.FixtureSpec `
            -EmlFileName $emlBaseName -ScenarioLabel $run.ScenarioName
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
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7383'
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