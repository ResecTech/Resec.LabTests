#Requires -Version 5.1
<#
.SYNOPSIS
  MA-02: Resilience (minimal functional test plan P0 #2).

.DESCRIPTION
  Automates substeps A–E per MA-minimal-functional-testplan.md (step C delegates to MA-02-C-NCP7307).
  Use -SkipStep* to run a subset. Step D default commdown is 300s.
  Step E uses Core dbsimulateon during listen-port soak (EF DB-unavailable simulation).

.NOTES
  Exit 0 = all selected steps passed; Exit 1 = any failed.
#>
[CmdletBinding()]
param(
    [string] $MailTempFolder = '',
    [string] $CoreDebugBaseUrl = '',
    [string] $MailAgentDebugBaseUrl = '',
    [int] $SimpleMailPort = 26,
    [double] $ResponseDelaySeconds = 5,
    [string] $InboundSmtpServer = '127.0.0.1',
    [int] $InboundSmtpPort = 25,
    [string] $MailTo = 'recipient@example.com',
    [string] $MailFrom = 'sender@example.com',
    [string] $SimpleMailServerPath = '',
    [string] $SendBulkAttachmentMailPath = '',
    [string] $CaptureSaveFolder = '',
    [string] $SimpleMailListenHost = '127.0.0.1',
    [int] $SimpleMailStartupTimeoutSec = 20,
    [switch] $SkipStartSimpleMailServer,
    [string] $MailAgentExePath = '',
    [int] $MailAgentStartupTimeoutSec = 90,
    [switch] $SkipStartMailAgent,
    [switch] $SkipCorePolicySetup,
    [string] $MailRelayName = '',
    [string] $CoreDebugHookUrl = '',
    [ValidateSet('All', 'Short', 'Long')]
    [string] $Ma02CScenarios = 'All',
    [int] $StepBEmailCount = 8,
    [int] $StepBMaxParallelSends = 3,
    [int] $StepDCommdownHoldSeconds = 300,
    [int] $StepEListenSoakMinutes = 15,
    [int] $StepEListenIntervalMinutes = 5,
    [switch] $SkipStepA,
    [switch] $SkipStepB,
    [switch] $SkipStepC,
    [switch] $SkipStepD,
    [switch] $SkipStepE,
    [switch] $SkipCoreDatabaseSimulation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-MailDeployRequirements
}

$script:MaE2eCommonRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common'
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eBootstrap.ps1') -CallingScriptRoot $PSScriptRoot
$coreCommon = Join-Path (Get-LabTestsRoot) 'Core\Common'
. (Join-Path $coreCommon 'CoreE2eDebugHook.ps1')
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eCorePolicy.ps1')
. (Join-Path $script:MaE2eCommonRoot 'MailAgentE2eMa02.ps1')

Assert-MailAgentE2eBulkPrerequisites -CallingScriptRoot $PSScriptRoot `
    -SimpleMailServerPathOverride $SimpleMailServerPath `
    -SendBulkAttachmentMailPathOverride $SendBulkAttachmentMailPath

$script:OverallPassed = $true
$script:PolicyStackPushed = $false
$script:CoreDebugHookUrl = $null
$mailAgentProcess = $null
$mailAgentStartedByScript = $false
$simpleMailProcess = $null
$simpleMailStartedByScript = $false
$lab = $null

function Write-TestStep {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] $Message"
}

function Invoke-Ma02StepWithReporting {
    param(
        [Parameter(Mandatory)][string] $StepId,
        [Parameter(Mandatory)][string] $StepTitle,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    $passed = $false
    $failure = $null
    $startedAtUtc = [DateTimeOffset]::UtcNow
    $runLogPath = Start-MailAgentE2eRunLog -TestId $StepId
    try {
        & $Action
        $passed = $true
    }
    catch {
        $failure = $_.Exception.Message
        $script:OverallPassed = $false
        Write-Host "[ERROR] [$StepId] $failure"
    }
    finally {
        try {
            Complete-MailAgentE2eTest -TestId $StepId -TestTitle $StepTitle -Passed:$passed `
                -FailureMessage $failure -StartedAtUtc $startedAtUtc -RunLogPath $runLogPath
        }
        finally {
            Stop-MailAgentE2eRunLog
        }
    }

    if (-not $passed) {
        throw "MA-02 step $StepId failed: $failure"
    }
}

try {
    $MailAgentDebugBaseUrl = Get-MailAgentDebugBaseUrl -Override $MailAgentDebugBaseUrl
    $CoreDebugBaseUrl = Get-MailAgentCoreDebugBaseUrl -Override $CoreDebugBaseUrl
    Write-TestStep 'MA-02: waiting for Core readiness.'
    Wait-MailAgentCoreReady -BaseUrl $CoreDebugBaseUrl | Out-Null
    $script:CoreDebugHookUrl = Get-MailAgentE2eCoreDebugHookUrl -BaseUrl $CoreDebugBaseUrl -Override $CoreDebugHookUrl

    if (-not $SkipCorePolicySetup) {
        $policyTempFolder = Get-MailAgentE2eDefaultLabTempFolder -Override $MailTempFolder
        Write-TestStep 'MA-02: install mail lab policy.'
        Install-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl -RelayName $MailRelayName `
            -NextHopPort $SimpleMailPort -InboundPort $InboundSmtpPort -TempFolder $policyTempFolder
        $script:PolicyStackPushed = $true
    }

    Write-TestStep 'MA-02: ensure mail agent.'
    $mailEnsure = Ensure-MailAgentE2eProcessRunning -CallingScriptRoot $PSScriptRoot `
        -BaseUrl $MailAgentDebugBaseUrl -MailAgentExePath $MailAgentExePath `
        -ExpectedInboundPort $InboundSmtpPort -StartupTimeoutSec $MailAgentStartupTimeoutSec `
        -SkipStart:$SkipStartMailAgent
    $mailAgentProcess = $mailEnsure.Process
    $mailAgentStartedByScript = [bool]$mailEnsure.StartedByScript
    $null = Wait-MailAgentDebugReady -BaseUrl $MailAgentDebugBaseUrl -ExpectedInboundPort $InboundSmtpPort

    if ($script:PolicyStackPushed) {
        Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $MailAgentDebugBaseUrl -HookUrl $script:CoreDebugHookUrl -TestId 'MA-02'
        Assert-MailAgentE2ePolicyFromAgentLog -BaseUrl $MailAgentDebugBaseUrl -NextHopHost $SimpleMailListenHost `
            -NextHopPort $SimpleMailPort
    }

    $smsExe = Resolve-SimpleMailServerPath -CallingScriptRoot $PSScriptRoot -Path $SimpleMailServerPath
    $bulkExe = Resolve-SendBulkAttachmentMailPath -CallingScriptRoot $PSScriptRoot -Path $SendBulkAttachmentMailPath
    $smsConfig = Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\simple-mail-server.appsettings.json'
    if (-not $SkipStepB -or -not $SkipStepD) {
        $lab = Initialize-MailAgentE2eMa02SharedLab -CallingScriptRoot $PSScriptRoot -MailAgentDebugUrl $MailAgentDebugBaseUrl `
            -CoreDebugHookUrl $script:CoreDebugHookUrl -BulkExe $bulkExe -SmsExe $smsExe `
            -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
            -ResponseDelaySeconds $ResponseDelaySeconds -CaptureSaveFolder $CaptureSaveFolder `
            -SmsConfig $smsConfig -SimpleMailStartupTimeoutSec $SimpleMailStartupTimeoutSec `
            -SkipStartSimpleMailServer:$SkipStartSimpleMailServer -MailAgentExePath $MailAgentExePath `
            -MailAgentStartupTimeoutSec $MailAgentStartupTimeoutSec -InboundPort $InboundSmtpPort
        $simpleMailProcess = $lab.SimpleMailProcess
        $simpleMailStartedByScript = $lab.SimpleMailStartedByScript
    }

    if (-not $SkipStepA) {
        Invoke-Ma02StepWithReporting -StepId 'MA-02-A' -StepTitle 'MA-02 A idle temp folders' {
            Invoke-Ma02StepA -MailAgentDebugUrl $MailAgentDebugBaseUrl
        }
    }
    else {
        Write-TestStep 'SKIP MA-02 A (-SkipStepA).'
    }

    if (-not $SkipStepB) {
        Invoke-Ma02StepWithReporting -StepId 'MA-02-B' -StepTitle 'MA-02 B burst send and agent restart' {
            Invoke-Ma02StepB -Lab $lab -EmailCount $StepBEmailCount `
                -MaxParallelSends $StepBMaxParallelSends -InboundServer $InboundSmtpServer -InboundPort $InboundSmtpPort `
                -MailFrom $MailFrom -MailTo $MailTo -CallingScriptRoot $PSScriptRoot `
                -CoreDebugHookUrl $script:CoreDebugHookUrl
        }
    }
    else {
        Write-TestStep 'SKIP MA-02 B (-SkipStepB).'
    }

    if (-not $SkipStepC) {
        Invoke-Ma02StepWithReporting -StepId 'MA-02-C' -StepTitle 'MA-02 C NCP-7307 reconnect outbound delivery' {
            $ma02c = Join-Path $PSScriptRoot 'MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1'
            $cArgs = @{
                MailAgentDebugBaseUrl     = $MailAgentDebugBaseUrl
                CoreDebugBaseUrl          = $CoreDebugBaseUrl
                SimpleMailPort            = $SimpleMailPort
                Scenarios                 = $Ma02CScenarios
                InboundSmtpServer         = $InboundSmtpServer
                InboundSmtpPort           = $InboundSmtpPort
                MailTo                    = $MailTo
                MailFrom                  = $MailFrom
                SimpleMailServerPath      = $SimpleMailServerPath
                SendBulkAttachmentMailPath = $SendBulkAttachmentMailPath
                CaptureSaveFolder         = if ($null -ne $lab) { $lab.CaptureFolder } else { $CaptureSaveFolder }
                SimpleMailListenHost      = $SimpleMailListenHost
                SkipStartSimpleMailServer = ($null -ne $lab)
                SkipStartMailAgent        = $true
                SkipCorePolicySetup       = $true
                CoreDebugHookUrl          = $script:CoreDebugHookUrl
                SkipRestoreCorePolicy     = $true
                SkipScenarioProcessTeardown = $true
            }
            & $ma02c @cArgs
            if ($LASTEXITCODE -ne 0) {
                throw "MA-02-C-NCP7307 exited with code $LASTEXITCODE"
            }
        }
    }
    else {
        Write-TestStep 'SKIP MA-02 C (-SkipStepC).'
    }

    if (-not $SkipStepD) {
        if ($null -eq $lab) {
            $lab = Initialize-MailAgentE2eMa02SharedLab -CallingScriptRoot $PSScriptRoot -MailAgentDebugUrl $MailAgentDebugBaseUrl `
                -CoreDebugHookUrl $script:CoreDebugHookUrl -BulkExe $bulkExe -SmsExe $smsExe `
                -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort `
                -ResponseDelaySeconds $ResponseDelaySeconds -CaptureSaveFolder $CaptureSaveFolder `
                -SmsConfig $smsConfig -SimpleMailStartupTimeoutSec $SimpleMailStartupTimeoutSec `
                -SkipStartSimpleMailServer:$SkipStartSimpleMailServer -MailAgentExePath $MailAgentExePath `
                -MailAgentStartupTimeoutSec $MailAgentStartupTimeoutSec -InboundPort $InboundSmtpPort
            $simpleMailProcess = $lab.SimpleMailProcess
            $simpleMailStartedByScript = $lab.SimpleMailStartedByScript
        }
        Invoke-Ma02StepWithReporting -StepId 'MA-02-D' -StepTitle 'MA-02 D Core outage without agent restart' {
            Invoke-Ma02StepD -Lab $lab -CoreDebugBaseUrl $CoreDebugBaseUrl -CommdownHoldSeconds $StepDCommdownHoldSeconds `
                -InboundServer $InboundSmtpServer -InboundPort $InboundSmtpPort -MailFrom $MailFrom -MailTo $MailTo
        }
    }
    else {
        Write-TestStep 'SKIP MA-02 D (-SkipStepD).'
    }

    if (-not $SkipStepE) {
        Invoke-Ma02StepWithReporting -StepId 'MA-02-E' -StepTitle 'MA-02 E inbound listen port soak' {
            Invoke-Ma02StepE -ComputerName $InboundSmtpServer -Port $InboundSmtpPort -MailAgentDebugUrl $MailAgentDebugBaseUrl `
                -CoreDebugHookUrl $script:CoreDebugHookUrl -TotalMinutes $StepEListenSoakMinutes `
                -IntervalMinutes $StepEListenIntervalMinutes -SkipCoreDatabaseSimulation:$SkipCoreDatabaseSimulation
        }
    }
    else {
        Write-TestStep 'SKIP MA-02 E (-SkipStepE).'
    }
}
catch {
    $script:OverallPassed = $false
    Write-Host "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    if ((Test-Ma02EDatabaseSimulationNeedsCleanup) -and $script:CoreDebugHookUrl) {
        try {
            Write-TestStep 'MA-02: dbsimulateoff (cleanup)'
            Set-CoreE2eDatabaseSimulation -HookUrl $script:CoreDebugHookUrl -SimulateOffline $false | Out-Null
        }
        catch {
            Write-Warning "dbsimulateoff cleanup failed: $($_.Exception.Message)"
        }
    }

    if ($script:PolicyStackPushed -and $script:CoreDebugHookUrl) {
        try {
            Write-TestStep 'MA-02: poppolicystate'
            Restore-MailAgentE2eLabCorePolicy -HookUrl $script:CoreDebugHookUrl
        }
        catch {
            Write-Warning "poppolicystate failed: $($_.Exception.Message)"
        }
    }

    if ($simpleMailStartedByScript -and $simpleMailProcess -and -not $simpleMailProcess.HasExited) {
        Stop-Process -Id $simpleMailProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if ($mailAgentStartedByScript -and $mailAgentProcess -and -not $mailAgentProcess.HasExited) {
        Write-TestStep "MA-02: stopping mail agent started by script (pid=$($mailAgentProcess.Id))."
        Stop-Process -Id $mailAgentProcess.Id -Force -ErrorAction SilentlyContinue
    }

    if (-not $script:OverallPassed) {
        exit 1
    }
}