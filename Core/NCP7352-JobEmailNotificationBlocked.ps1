#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7352: Job completion email uses blocked vs all-passed templates correctly.

.DESCRIPTION
  Patches Core SMTP system properties via /debug/hook (push/import/pop stack), imports a lab
  policy that blocks unknown file types and enables Email Notification, then:
  1) Sanitizes a synthetic unknown-type file — expects blocked outcome and blocked email template.
  2) Sanitizes a plain-text file — expects success outcome and all-passed email template.

  SMTP capture uses SimpleMailServer.exe --cli (same helper as Mail Agent E2E). Default listen
  127.0.0.1:2525 (override with -SmtpPort or CORE_E2E_SMTP_PORT). Use -SkipStartSmtpCapture when
  you already run a listener on that port.

  Prerequisites:
    - Core with EnableDebugInterface and system-properties debug commands (importsystemproperties).
    - Core build including NCP-7352 JobReporter fix (in-memory job outcome for notification).
    - SimpleMailServer built or MAIL_E2E_SIMPLE_MAIL_SERVER_EXE set.

.EXAMPLE
  .\NCP7352-JobEmailNotificationBlocked.ps1

.NOTES
  Exit 0 = passed; exit 1 = failed.
#>
[CmdletBinding()]
param(
    [string] $CoreDebugHookUrl = '',
    [string] $OutputRoot = '',
    [string] $PolicyImportJson = '',
    [string] $LabPolicyName = 'NCP7352-email-notification-blocked',
    [string] $SimpleMailServerPath = '',
    [string] $SmtpListenHost = '127.0.0.1',
    [int] $SmtpPort = 0,
    [string] $SmtpSenderAccount = 'core-lab-sender@127.0.0.1',
    [int] $EmailCaptureTimeoutSec = 120,
    [switch] $SkipPolicyImport,
    [int] $PolicyId = 0,
    [int] $DeploymentId = 0,
    [int] $SanitizeTimeoutSec = 300,
    [switch] $SkipPolicyStack,
    [switch] $SkipSystemPropertiesStack,
    [switch] $SkipStartSmtpCapture,
    [switch] $SkipSuccessScenario
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
. (Join-Path $commonRoot 'CoreE2eSmtpCapture.ps1')
. (Join-Path $commonRoot 'CoreE2eNcp7352Policy.ps1')

$script:BlockedBodyMarker = 'LAB-NCP7352-BLOCKED-MARKER'
$script:AllPassedBodyMarker = 'LAB-NCP7352-ALL-PASSED-MARKER'
$script:ExpectedEmailSubjectFragment = 'LAB-NCP7352 job notification'

$script:ScenarioPassed = $false
$script:ScenarioFailureMessage = $null
$script:TestStartedAtUtc = [DateTimeOffset]::MinValue
$script:E2eRunLogPath = $null
$script:PolicyStackPushed = $false
$script:SystemPropertiesStackPushed = $false
$script:EvidenceZipPath = $null
$hookUrl = $null
$outputRoot = $null
$smtpSession = $null
$script:TestId = 'Core-NCP7352'
$script:TestTitle = 'Job email notification blocked and success templates (NCP-7352)'

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Assert-Ncp7352JobNotificationEmail {
    param(
        [Parameter(Mandatory)]
        $Captured,
        [Parameter(Mandatory)]
        [string] $RequiredBodyMarker,
        [string[]] $ForbiddenBodyMarkers = @(),
        [string] $ScenarioLabel = 'notification'
    )

    if ($Captured.Subject -notlike "*$($script:ExpectedEmailSubjectFragment)*") {
        throw "[$ScenarioLabel] Captured subject '$($Captured.Subject)' does not contain '$($script:ExpectedEmailSubjectFragment)'."
    }

    $body = [string]$Captured.Body
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "[$ScenarioLabel] Captured message has no readable body (file=$($Captured.SavedFilePath))."
    }

    if ($body -notlike "*$RequiredBodyMarker*") {
        throw "[$ScenarioLabel] Notification body missing marker '$RequiredBodyMarker'. Subject=$($Captured.Subject) File=$($Captured.SavedFilePath)"
    }

    foreach ($forbidden in @($ForbiddenBodyMarkers)) {
        if ([string]::IsNullOrWhiteSpace($forbidden)) { continue }
        if ($body -like "*$forbidden*") {
            throw "[$ScenarioLabel] Notification body must not contain '$forbidden'. Subject=$($Captured.Subject) File=$($Captured.SavedFilePath)"
        }
    }

    Write-TestStep "[$ScenarioLabel] Captured email OK: subject='$($Captured.Subject)' file=$($Captured.SavedFilePath)"
}

function Register-Ncp7352SmtpCaptureBaseline {
    param(
        [Parameter(Mandatory)]
        $SmtpSession,
        [Parameter(Mandatory)]
        $Captured
    )

    if (-not [string]::IsNullOrWhiteSpace($Captured.SavedFilePath)) {
        $SmtpSession.ExcludeCaptureFiles[[string]$Captured.SavedFilePath] = $true
    }

    return [int]$Captured.MessageCount
}

function Invoke-Ncp7352DebugSanitize {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [int] $PolicyId,
        [Parameter(Mandatory)]
        [string] $FileLabel,
        [int] $TimeoutSeconds = 300,
        [int] $DeploymentId = 0,
        [string] $OutputPath = ''
    )

    Write-TestStep "sanitize: $FileLabel"
    $sanitizeParams = @{
        HookUrl        = $HookUrl
        FilePath       = $FilePath
        PolicyId       = $PolicyId
        TimeoutSeconds = $TimeoutSeconds
    }
    if ($DeploymentId -gt 0) {
        $sanitizeParams.DeploymentId = $DeploymentId
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $sanitizeParams.OutputPath = $OutputPath
    }

    $result = Invoke-CoreE2eSanitizeFile @sanitizeParams
    if ($result.timedOut -eq $true) {
        throw "Timed out sanitizing '$FileLabel' (sanitizationId=$($result.sanitizationId))."
    }

    return $result
}

function Wait-Ncp7352JobNotificationEmail {
    param(
        [Parameter(Mandatory)]
        $SmtpSession,
        [int] $MinMessageCount = 0,
        [int] $TimeoutSec = 120,
        [string] $ScenarioLabel = 'notification'
    )

    Write-TestStep "[$ScenarioLabel] Wait for job notification email (up to ${TimeoutSec}s)"
    return Wait-CoreE2eCapturedSmtpMessage -StatusPath $SmtpSession.StatusPath `
        -CaptureFolder $SmtpSession.CaptureFolder `
        -MinMessageCount $MinMessageCount `
        -TimeoutSec $TimeoutSec `
        -ExcludeCaptureFiles $SmtpSession.ExcludeCaptureFiles
}

function Resolve-Ncp7352PassFixturePath {
    param([Parameter(Mandatory)][string] $OutputRoot)

    $fromFixtures = Join-Path (Get-LabFixturesRoot) 'FileTypeDetection\sample.txt'
    if (Test-Path -LiteralPath $fromFixtures -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($fromFixtures)
    }

    $generated = Join-Path $OutputRoot 'lab-pass-sample.txt'
    [System.IO.File]::WriteAllText($generated, "NCP-7352 lab pass fixture`r`n", [System.Text.UTF8Encoding]::new($false))
    return $generated
}

if ($SmtpPort -le 0) {
    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_SMTP_PORT)) {
        $SmtpPort = [int]$env:CORE_E2E_SMTP_PORT
    }
    else {
        $SmtpPort = 2525
    }
}

try {
    $script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
    $script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId

    $hookUrl = Get-CoreE2eDebugHookUrl -Override $CoreDebugHookUrl

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreE2e-NCP7352-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    Write-TestStep "Hook: $hookUrl"
    Write-TestStep "SMTP target: ${SmtpListenHost}:$SmtpPort"
    Write-TestStep "Output: $outputRoot"

    Write-TestStep 'Start local SMTP capture (SimpleMailServer)'
    $smtpSession = Start-CoreE2eSmtpCapture -CallingScriptRoot $PSScriptRoot `
        -SimpleMailServerPath $SimpleMailServerPath -ListenHost $SmtpListenHost -Port $SmtpPort `
        -CaptureRoot (Join-Path $outputRoot 'smtp-capture') -SkipStart:$SkipStartSmtpCapture

    Write-TestStep 'Wait for Core ready'
    Wait-CoreE2eReady -HookUrl $hookUrl | Out-Null

    $versionInfo = Invoke-CoreE2eDebugHook -HookUrl $hookUrl -Command 'version'
    if ($versionInfo.version) {
        $env:CORE_COMPONENT_VERSION = [string]$versionInfo.version
        Write-TestStep "Core version: $($versionInfo.version)"
    }

    if (-not $SkipSystemPropertiesStack) {
        Write-TestStep 'pushsystempropertystate'
        Push-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        $script:SystemPropertiesStackPushed = $true
    }

    Write-TestStep 'importsystemproperties (lab SMTP)'
    Set-CoreE2eLabAlertEmailSmtpSystemProperties -HookUrl $hookUrl -SmtpServer $SmtpListenHost `
        -SmtpPort $SmtpPort -SenderAccount $SmtpSenderAccount | Out-Null

    $resolvedPolicyId = $PolicyId
    if (-not $SkipPolicyImport) {
        if (-not $SkipPolicyStack) {
            Write-TestStep 'pushpolicystate'
            Push-CoreE2ePolicyState -HookUrl $hookUrl | Out-Null
            $script:PolicyStackPushed = $true
        }

        $jsonPath = Get-Ncp7352EmailNotificationBlockedPolicyImportPoliciesPath -OverridePath $PolicyImportJson
        Write-TestStep "importpolicies from JSON: $jsonPath"
        Import-Ncp7352EmailNotificationBlockedPolicy -HookUrl $hookUrl -PolicyImportJson $jsonPath `
            -PolicyName $LabPolicyName | Out-Null

        $resolvedPolicyId = Resolve-CoreE2ePolicyIdByName -HookUrl $hookUrl -PolicyName $LabPolicyName
        Write-TestStep "Resolved policy '$LabPolicyName' -> id $resolvedPolicyId"
    }
    elseif ($resolvedPolicyId -le 0) {
        throw 'SkipPolicyImport requires -PolicyId (positive).'
    }

    $unknownInput = Join-Path $outputRoot 'lab-unknown-type.dat'
    $unknownBytes = [byte[]](0x52, 0x45, 0x53, 0x45, 0x43, 0x2D, 0x4E, 0x43, 0x50, 0x2D, 0x37, 0x33, 0x35, 0x32, 0x00, 0xFF)
    [System.IO.File]::WriteAllBytes($unknownInput, $unknownBytes)

    $blockedResult = Invoke-Ncp7352DebugSanitize -HookUrl $hookUrl -FilePath $unknownInput `
        -PolicyId $resolvedPolicyId -FileLabel ([System.IO.Path]::GetFileName($unknownInput)) `
        -TimeoutSeconds $SanitizeTimeoutSec -DeploymentId $DeploymentId

    $blockedOutcome = [string]$blockedResult.outcome
    if ($blockedOutcome -ne 'OutcomeBlockedByPolicy') {
        throw "Expected OutcomeBlockedByPolicy but got '$blockedOutcome'. Details: $($blockedResult.outcomeDetails)"
    }
    Write-TestStep "Blocked sanitize OK (outcome=$blockedOutcome)"

    $blockedCaptured = Wait-Ncp7352JobNotificationEmail -SmtpSession $smtpSession `
        -MinMessageCount $smtpSession.BaselineMessageCount -TimeoutSec $EmailCaptureTimeoutSec `
        -ScenarioLabel 'blocked'
    Assert-Ncp7352JobNotificationEmail -Captured $blockedCaptured -RequiredBodyMarker $script:BlockedBodyMarker `
        -ForbiddenBodyMarkers @($script:AllPassedBodyMarker) -ScenarioLabel 'blocked'

    $smtpMinAfterBlocked = Register-Ncp7352SmtpCaptureBaseline -SmtpSession $smtpSession -Captured $blockedCaptured

    if (-not $SkipSuccessScenario) {
        $passInput = Resolve-Ncp7352PassFixturePath -OutputRoot $outputRoot
        $passOutput = Join-Path $outputRoot ([System.IO.Path]::GetFileName($passInput))

        $passResult = Invoke-Ncp7352DebugSanitize -HookUrl $hookUrl -FilePath $passInput `
            -PolicyId $resolvedPolicyId -FileLabel ([System.IO.Path]::GetFileName($passInput)) `
            -TimeoutSeconds $SanitizeTimeoutSec -DeploymentId $DeploymentId -OutputPath $passOutput

        $passOutcome = [string]$passResult.outcome
        if ($passOutcome -eq 'OutcomeBlockedByPolicy') {
            throw "Pass fixture was blocked by policy (outcome=$passOutcome). Details: $($passResult.outcomeDetails)"
        }
        if ($passOutcome -match 'Blocked|Failed|Rejected') {
            throw "Pass fixture did not succeed (outcome=$passOutcome). Details: $($passResult.outcomeDetails)"
        }
        Write-TestStep "Pass sanitize OK (outcome=$passOutcome)"

        $successCaptured = Wait-Ncp7352JobNotificationEmail -SmtpSession $smtpSession `
            -MinMessageCount $smtpMinAfterBlocked -TimeoutSec $EmailCaptureTimeoutSec `
            -ScenarioLabel 'success'
        Assert-Ncp7352JobNotificationEmail -Captured $successCaptured -RequiredBodyMarker $script:AllPassedBodyMarker `
            -ForbiddenBodyMarkers @($script:BlockedBodyMarker) -ScenarioLabel 'success'
    }
    else {
        Write-TestStep 'SkipSuccessScenario — blocked notification only.'
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
            $script:EvidenceZipPath = New-CoreE2eFailureEvidenceZip -Paths $evidenceOnFailure -Label 'Core-NCP7352'
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

    if ($script:SystemPropertiesStackPushed -and -not [string]::IsNullOrWhiteSpace($hookUrl)) {
        try {
            Write-TestStep 'popsystempropertystate'
            Pop-CoreE2eSystemPropertiesState -HookUrl $hookUrl | Out-Null
        }
        catch {
            Write-Warning "popsystempropertystate failed: $($_.Exception.Message)"
        }
    }

    if ($null -ne $smtpSession) {
        Stop-CoreE2eSmtpCapture -CaptureSession $smtpSession
    }

    if ($script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        try {
            Remove-Item -LiteralPath $outputRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove output folder '$outputRoot': $($_.Exception.Message)"
        }
    }
    elseif (-not $script:ScenarioPassed -and $outputRoot -and (Test-Path -LiteralPath $outputRoot)) {
        Write-Host "Output artifacts left at: $outputRoot"
    }
}
