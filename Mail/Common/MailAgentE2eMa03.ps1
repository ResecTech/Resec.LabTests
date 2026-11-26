#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:Ma03PassOutcomes = @(
    'OutcomePassed', 'OutcomeModified', 'OutcomePartiallyProcessed', 'OutcomeReconstructed'
)

function Write-Ma03Step {
    param([string] $Message)
    Write-Host ("[{0}] [STEP] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Assert-Ma03Check {
    param(
        [Parameter(Mandatory)][string] $StepId,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][string] $Expect,
        [string] $Actual,
        [switch] $Passed
    )

    Write-Host ("[{0}] Action: {1}" -f $StepId, $Action)
    Write-Host ("  Expect: {0}" -f $Expect)
    Write-Host ("  Actual: {0}" -f $(if ([string]::IsNullOrWhiteSpace($Actual)) { '(empty)' } else { $Actual }))

    if (-not $Passed) {
        $reason = switch -Wildcard ($StepId) {
            'MA-03-A1' { 'Dual next-hop policy: comma-separated NextHopServerAddress (dead,valid), single NextHopPort=25; use -Ma03ADualHopEmailFacetPath from WebMC or built-in Mail/Config/ma03-dual-hop-email-facet.txt; or -Ma03A1SingleValidHop for single-hop only.' }
            'MA-03-B' { 'Set StrPropType_SmtpSenderIncomingTlsCertificateSubject to a CN present in LocalMachine\My or CurrentUser\My, restart the mail agent, then send one message. Override with -Ma03IncomingTlsCertificateSubject or install a Server Authentication cert (prefer CN=localhost).' }
            'MA-03-D' { 'After step C, disk/spool rows in agent debug stats must not be Degraded on a lab volume with adequate free space. Session-capacity denials may still show Degraded on Inbound SMTP sessions (ignored by step D).' }
            default { 'Assertion did not match the test plan expectation.' }
        }
        throw ("[{0}] FAILED - {1}" -f $StepId, $reason)
    }

    Write-Host ("  Result: PASS")
}

function Get-Ma03DefaultDualHopFacetPath {
    return (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config\ma03-dual-hop-email-facet.txt')
}

function Test-Ma03SecondHopTargetsSimpleMailCapture {
    param(
        [string] $ValidHopHost,
        [int] $ValidHopPort,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort
    )

    if ([string]::IsNullOrWhiteSpace($ValidHopHost)) {
        return $false
    }

    $hostMatch = ($ValidHopHost -ieq $SimpleMailListenHost) -or ($ValidHopHost -eq '127.0.0.1' -and $SimpleMailListenHost -eq '127.0.0.1')
    return $hostMatch -and ($ValidHopPort -eq $SimpleMailPort)
}

function Get-Ma03ADualHopEmailFacetRaw {
    param(
        [string] $InlineRaw = '',
        [string] $FacetPath = '',
        [string] $DeadHopHost = '',
        [int] $DeadHopPort = 25,
        [string] $ValidHopHost = '',
        [int] $ValidHopPort = 25,
        [bool] $ValidHopUseTls = $true,
        [int] $InboundPort = 25,
        [string] $TempFolder = '',
        [string] $RelayName = 'mail'
    )

    if (-not [string]::IsNullOrWhiteSpace($InlineRaw)) {
        return $InlineRaw.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($FacetPath)) {
        if (-not (Test-Path -LiteralPath $FacetPath)) {
            throw "MA-03 A1: facet file not found: $FacetPath"
        }
        return ([System.IO.File]::ReadAllText($FacetPath)).Trim()
    }

    $envPath = $env:MAIL_E2E_MA03_DUAL_HOP_EMAIL_FACET_PATH
    if (-not [string]::IsNullOrWhiteSpace($envPath)) {
        if (-not (Test-Path -LiteralPath $envPath)) {
            throw "MA-03 A1: MAIL_E2E_MA03_DUAL_HOP_EMAIL_FACET_PATH file not found: $envPath"
        }
        return ([System.IO.File]::ReadAllText($envPath)).Trim()
    }

    $builtInPath = Get-Ma03DefaultDualHopFacetPath
    if (Test-Path -LiteralPath $builtInPath) {
        return ([System.IO.File]::ReadAllText($builtInPath)).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($DeadHopHost) -and -not [string]::IsNullOrWhiteSpace($ValidHopHost)) {
        $temp = if ([string]::IsNullOrWhiteSpace($TempFolder)) { Get-MailAgentE2eDefaultLabTempFolder } else { $TempFolder }
        $relay = Get-MailAgentE2eDefaultRelayName -Override $RelayName
        $sharedPort = if ($ValidHopPort -gt 0) { $ValidHopPort } else { 25 }
        return (New-MailAgentE2eMa03DualHopEmailFacetRaw -RelayName $relay -DeadHopHost $DeadHopHost `
            -ValidHopHost $ValidHopHost -NextHopPort $sharedPort -InboundPort $InboundPort -TempFolder $temp `
            -ValidHopUseTls:$ValidHopUseTls).Trim()
    }

    return $null
}

function Get-CoreE2eWmcEmailSanitizationRowBySubject {
    param(
        [Parameter(Mandatory)][string] $BaseUrl,
        [Parameter(Mandatory)][string] $ApiToken,
        [Parameter(Mandatory)][string] $SubjectContains,
        [int] $TimeoutSec = 180,
        [int] $PollSec = 4
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $lastDiag = ''

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $range = Get-CoreE2eWmcSanitizationQueryTimeRange
        $body = @{
            startTime        = $range.StartTime
            endTime          = $range.EndTime
            pageIndex        = 1
            pageSize         = 50
            sanitizationType = 1
            sortField        = 'TimeUploaded'
            sortOrder        = 'Desc'
            subject          = $SubjectContains
        }

        $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
            -Path '/v1/sanitizations/email' -Method Post -BodyObject $body
        $data = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('data', 'Data')
        $rows = @($data | Where-Object { $null -ne $_ })

        foreach ($row in $rows) {
            if (Test-CoreE2eWmcEmailRowSubjectMatches -Row $row -SubjectContains $SubjectContains) {
                return $row
            }
        }

        $lastDiag = "rows=$($rows.Count)"
        Start-Sleep -Seconds $PollSec
    }

    throw "WMC did not return any email sanitization with subject containing '$SubjectContains' within ${TimeoutSec}s (last: $lastDiag)."
}

function Test-CoreE2eWmcEmailSanitizationIsPassOutcome {
    param($Outcome)

    return (Test-CoreE2eWmcEmailSanitizationOutcomeAllowed -Outcome $Outcome -AllowedOutcomes $script:Ma03PassOutcomes)
}

function Assert-MailAgentE2eOutboundFailureLogMarkers {
    param(
        [string] $MailAgentDebugUrl,
        [string] $SubjectContains = '',
        [int] $TailLineCount = 600
    )

    $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $MailAgentDebugUrl
    if ([string]::IsNullOrWhiteSpace($log) -or -not (Test-Path -LiteralPath $log)) {
        throw 'MA-03 A2: mail agent log path unavailable (debug logpath); cannot verify DAD/timeout text.'
    }

    $tail = @(Get-Content -LiteralPath $log -Tail $TailLineCount -ErrorAction SilentlyContinue)
    $blob = ($tail -join [Environment]::NewLine)

    $failurePattern = '(?i)(\bDAD\b|delivery attempt|deliver.+fail|next hop|timeout|timed out|unable to connect|connection refused|no route)'
    if ($blob -notmatch $failurePattern) {
        throw "MA-03 A2: agent log tail does not contain expected outbound failure markers (DAD/timeout/next-hop failure). Log=$log"
    }

    if (-not [string]::IsNullOrWhiteSpace($SubjectContains)) {
        if ($blob -notmatch [regex]::Escape($SubjectContains)) {
            Write-Host "[WARN] MA-03 A2: subject '$SubjectContains' not found in log tail; failure markers still present."
        }
    }

    return $log
}

function Send-Ma03CleanInboundMail {
    <#
    One inbound message with a clean attachment (SendBulkAttachmentMail, EmailCount=1, MaxParallelSends=1).
    The bulk tool is the shared lab SMTP client; only step C uses multi-message load.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Lab,
        [string] $SubjectPrefix,
        [string] $InboundServer,
        [int] $InboundPort,
        [string] $MailFrom,
        [string] $MailTo,
        [int] $DeliveryTimeoutSec = 120,
        [string] $StepLabel,
        [switch] $RequireCapture,
        [switch] $AllowBulkNonZeroExit
    )

    $captureBaseline = Get-CaptureFolderFileSnapshot -Folder $Lab.CaptureFolder
    $statusBaseline = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount

    Write-Ma03Step "$StepLabel - send one message to inbound SMTP ($InboundServer`:$InboundPort)."
    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $Lab.AttachFolder -SmtpServer $InboundServer `
        -SmtpPort $InboundPort -From $MailFrom -To $MailTo -SendTimeoutSeconds $DeliveryTimeoutSec `
        -SubjectPrefix $SubjectPrefix -MinAttachmentsPerEmail 1 -MaxAttachmentsPerEmail 1 `
        -EmailCount 1 -MaxParallelSends 1
    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $SubjectPrefix

    $report = $null
    $bulkFailed = $false
    try {
        $report = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec $DeliveryTimeoutSec `
            -ProgressLabel $StepLabel -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
            -EmitLogMarks -E2eTestId 'MA-03' -CoreDebugHookUrl $Lab.CoreDebugHookUrl
    }
    catch {
        $bulkFailed = $true
        if (-not $AllowBulkNonZeroExit) {
            throw
        }
        Write-Ma03Step "$StepLabel inbound send ended with non-zero exit (allowed for failure scenario): $($_.Exception.Message)"
    }
    finally {
        if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
            Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
        }
    }

    $actualSubjectPrefix = Get-MailAgentE2eBulkReportSubjectPrefix -Report $report -ConfiguredPrefix $SubjectPrefix
    if (-not [string]::IsNullOrWhiteSpace($actualSubjectPrefix) -and $actualSubjectPrefix -ne $SubjectPrefix) {
        Write-Ma03Step "$StepLabel bulk actual subject prefix=$actualSubjectPrefix (configured=$SubjectPrefix)."
    }

    $expectedSubject = '{0}-1' -f $actualSubjectPrefix
    $wmcSubjectContains = Resolve-MailAgentE2eBulkCoreSubjectContains -SubjectPrefix $actualSubjectPrefix

    $capture = $null
    if ($RequireCapture) {
        if ($bulkFailed) {
            throw "$StepLabel expected capture but bulk send failed."
        }
        $capture = Wait-ForCapturedSubject -StatusPath $Lab.StatusFilePath -ExpectedSubject $expectedSubject `
            -TimeoutSec $DeliveryTimeoutSec -MinMessageCount $statusBaseline `
            -CaptureFolder $Lab.CaptureFolder -ExcludeCaptureFiles $captureBaseline
    }

    return @{
        ExpectedSubject      = $expectedSubject
        WmcSubjectContains   = $wmcSubjectContains
        ActualSubjectPrefix  = $actualSubjectPrefix
        Capture              = $capture
        BulkJob              = $bulkJob
        BulkFailed           = $bulkFailed
        Report               = $report
        StatusBaseline       = $statusBaseline
        CaptureBaseline      = $captureBaseline
    }
}

function Invoke-Ma03StepA {
    param(
        [hashtable] $Lab,
        [string] $HookUrl,
        [string] $RelayName,
        [int] $InboundPort,
        [string] $TempFolder,
        [string] $DeadHopHost,
        [int] $DeadHopPort,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort,
        [string] $DualHopFacetRaw,
        [string] $DualHopFacetPath,
        [string] $ValidHopHost,
        [int] $ValidHopPort = 25,
        [bool] $ValidHopUseTls = $true,
        [switch] $A1SingleValidHop,
        [string] $CoreRestUrl,
        [string] $WmcToken,
        [string] $InboundServer,
        [string] $MailFrom,
        [string] $MailTo,
        [int] $OutboundFailureTimeoutSec = 200
    )

    $facetRaw = Get-Ma03ADualHopEmailFacetRaw -InlineRaw $DualHopFacetRaw -FacetPath $DualHopFacetPath `
        -DeadHopHost $DeadHopHost -DeadHopPort $DeadHopPort -ValidHopHost $ValidHopHost -ValidHopPort $ValidHopPort `
        -ValidHopUseTls:$ValidHopUseTls -InboundPort $InboundPort -TempFolder $TempFolder -RelayName $RelayName
    if ([string]::IsNullOrWhiteSpace($facetRaw)) {
        if (-not $A1SingleValidHop) {
            Assert-Ma03Check -StepId 'MA-03-A1' -Action 'Import dual next-hop policy (dead then working)' `
                -Expect 'Facet raw (comma-separated hops, port 25) from WebMC or Mail/Config/ma03-dual-hop-email-facet.txt' `
                -Actual 'No -Ma03ADualHopEmailFacetRaw/Path and auto-build inputs missing' -Passed:$false
        }

        Write-Ma03Step "MA-03 A1 - single valid next hop only (-Ma03A1SingleValidHop): $ValidHopHost`:$ValidHopPort (TLS=$ValidHopUseTls)."
        Update-MailAgentE2eLabCorePolicy -HookUrl $HookUrl -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
            -RelayName $RelayName -NextHopHost $ValidHopHost -NextHopPort $ValidHopPort -InboundPort $InboundPort `
            -TempFolder $TempFolder -NextHopUseTls:$ValidHopUseTls -NextHopSkipTlsCertificateValidation:$true -TestId 'MA-03'
    }
    else {
        Write-Ma03Step "MA-03 A1 - re-import policy with dual next hop facet from WebMC export."
        Update-MailAgentE2eLabCorePolicy -HookUrl $HookUrl -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
            -RelayName $RelayName -NextHopHost $SimpleMailListenHost -NextHopPort $SimpleMailPort `
            -InboundPort $InboundPort -TempFolder $TempFolder -EmailInfrastructureFacetRaw $facetRaw -TestId 'MA-03'
    }

    $a1UsesCapture = Test-Ma03SecondHopTargetsSimpleMailCapture -ValidHopHost $ValidHopHost -ValidHopPort $ValidHopPort `
        -SimpleMailListenHost $SimpleMailListenHost -SimpleMailPort $SimpleMailPort
    $subjectA1 = 'MA03-A1-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $sendA1 = Send-Ma03CleanInboundMail -Lab $Lab -SubjectPrefix $subjectA1 `
        -InboundServer $InboundServer -InboundPort $Lab.InboundPort -MailFrom $MailFrom -MailTo $MailTo `
        -StepLabel 'MA-03 A1' -RequireCapture:$a1UsesCapture

    if ($a1UsesCapture) {
        Assert-Ma03Check -StepId 'MA-03-A1' -Action 'Deliver via failover to second next hop (SimpleMail capture)' `
            -Expect "Capture contains subject *$($sendA1.ExpectedSubject)*" `
            -Actual "Captured on SimpleMailServer" -Passed:$true
    }
    else {
        if ([string]::IsNullOrWhiteSpace($WmcToken)) {
            throw 'MA-03 A1: WMC token required when valid next hop is not SimpleMail capture.'
        }

        $wmcSubjectToken = $sendA1.WmcSubjectContains
        if ([string]::IsNullOrWhiteSpace($wmcSubjectToken)) {
            $wmcSubjectToken = $sendA1.ExpectedSubject
        }

        $wmcTimeout = [Math]::Max(180, $OutboundFailureTimeoutSec)
        Write-Ma03Step "MA-03 A1 - WMC wait for Pass on valid hop $ValidHopHost (subject *$wmcSubjectToken*, up to ${wmcTimeout}s)."
        $row = Wait-CoreE2eWmcEmailSanitizationBySubject -BaseUrl $CoreRestUrl -ApiToken $WmcToken `
            -SubjectContains $wmcSubjectToken -MailTo @($MailTo) -TimeoutSec $wmcTimeout -AllowedOutcomes @('OutcomePassed')
        $outcome = [string](Get-CoreE2eWmcRestPropertyValue -Object $row -Names @('outcome', 'Outcome'))
        Assert-Ma03Check -StepId 'MA-03-A1' -Action "Deliver via failover to valid hop $ValidHopHost" `
            -Expect "WMC OutcomePassed for subject *$wmcSubjectToken*" `
            -Actual "outcome=$outcome" -Passed:$true
    }

    Write-Ma03Step 'MA-03 A2 - re-import policy with only dead next hop.'
    Update-MailAgentE2eLabCorePolicy -HookUrl $HookUrl -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
        -RelayName $RelayName -NextHopHost $DeadHopHost -NextHopPort $DeadHopPort `
        -InboundPort $InboundPort -TempFolder $TempFolder -TestId 'MA-03'

    $statusBefore = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $subjectA2 = 'MA03-A2-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $sendA2 = Send-Ma03CleanInboundMail -Lab $Lab -SubjectPrefix $subjectA2 `
        -InboundServer $InboundServer -InboundPort $Lab.InboundPort -MailFrom $MailFrom -MailTo $MailTo `
        -DeliveryTimeoutSec $OutboundFailureTimeoutSec -StepLabel 'MA-03 A2' -AllowBulkNonZeroExit

    $statusAfter = (Get-SimpleMailServerStatusSnapshot -StatusPath $Lab.StatusFilePath).MessageCount
    $captureIncremented = ($statusAfter -gt $statusBefore)
    Assert-Ma03Check -StepId 'MA-03-A2' -Action 'No delivery to capture when all hops dead' `
        -Expect 'SimpleMailServer message count unchanged' `
        -Actual "before=$statusBefore after=$statusAfter" -Passed:(-not $captureIncremented)

    if ([string]::IsNullOrWhiteSpace($WmcToken)) {
        throw 'MA-03 A2: WMC token required (-SkipWmcCheck not allowed for MA-03 A).'
    }

    $subjectA2Token = $sendA2.WmcSubjectContains
    if ([string]::IsNullOrWhiteSpace($subjectA2Token)) {
        $subjectA2Token = Resolve-MailAgentE2eBulkCoreSubjectContains -SubjectPrefix $subjectA2
    }
    if ([string]::IsNullOrWhiteSpace($subjectA2Token)) {
        $subjectA2Token = $subjectA2
    }

    $row = Get-CoreE2eWmcEmailSanitizationRowBySubject -BaseUrl $CoreRestUrl -ApiToken $WmcToken `
        -SubjectContains $subjectA2Token -TimeoutSec $OutboundFailureTimeoutSec
    $outcome = Get-CoreE2eWmcRestPropertyValue -Object $row -Names @('outcome', 'Outcome')
    $outcomeText = [string]$outcome
    $isPass = Test-CoreE2eWmcEmailSanitizationIsPassOutcome -Outcome $outcome
    Assert-Ma03Check -StepId 'MA-03-A2' -Action 'WMC shows sanitization row (not missing)' `
        -Expect "Row for subject *$subjectA2* with non-Pass outcome" `
        -Actual "outcome=$outcomeText" -Passed:(-not $isPass)

    $logSubject = if (-not [string]::IsNullOrWhiteSpace($sendA2.WmcSubjectContains)) { $sendA2.WmcSubjectContains } else { $subjectA2 }
    $log = Assert-MailAgentE2eOutboundFailureLogMarkers -MailAgentDebugUrl $Lab.MailAgentDebugUrl -SubjectContains $logSubject
    Write-Ma03Step "MA-03 A2: outbound failure markers found in agent log ($log)."
}

function Invoke-Ma03StepB {
    param(
        [hashtable] $Lab,
        [string] $HookUrl,
        [string] $RelayName,
        [int] $InboundPort,
        [string] $TempFolder,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort,
        [string] $InboundServer,
        [string] $MailFrom,
        [string] $MailTo,
        [string] $IncomingTlsCertificateSubject,
        [Parameter(Mandatory)][string] $CallingScriptRoot,
        [string] $MailAgentExePath = '',
        [int] $MailAgentStartupTimeoutSec = 90,
        [string] $WmcToken = '',
        [string] $CoreRestUrl = ''
    )

    $tlsSubject = Resolve-MailAgentE2eInboundTlsCertificateSubject -Subject $IncomingTlsCertificateSubject
    Write-Ma03Step "MA-03 B - policy Incoming TLS Certificate Subject=$tlsSubject; next hop capture ${SimpleMailListenHost}:$SimpleMailPort."
    Update-MailAgentE2eLabCorePolicy -HookUrl $HookUrl -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
        -RelayName $RelayName -NextHopHost $SimpleMailListenHost -NextHopPort $SimpleMailPort `
        -InboundPort $InboundPort -TempFolder $TempFolder -NextHopUseTls:$false `
        -NextHopSkipTlsCertificateValidation:$true -IncomingTlsCertificateSubject $tlsSubject -TestId 'MA-03'

    Write-Ma03Step 'MA-03 B - restart mail agent so inbound SMTP binds the TLS certificate.'
    Restart-MailAgentE2eWindowsServiceOrProcess -CallingScriptRoot $CallingScriptRoot `
        -MailAgentDebugUrl $Lab.MailAgentDebugUrl -MailAgentExePath $MailAgentExePath `
        -ExpectedInboundPort $InboundPort -StartupTimeoutSec $MailAgentStartupTimeoutSec `
        -Context 'MA-03 B'
    $null = Wait-MailAgentDebugReady -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $InboundPort -TimeoutSec $MailAgentStartupTimeoutSec
    Ensure-MailAgentE2eLabPolicyOnAgent -BaseUrl $Lab.MailAgentDebugUrl -HookUrl $HookUrl -TestId 'MA-03'

    $log = Get-MailAgentDebugLogPathEvidence -BaseUrl $Lab.MailAgentDebugUrl
    if ([string]::IsNullOrWhiteSpace($log)) {
        throw 'MA-03 B: cannot read agent log after restart.'
    }
    $tlsLoaded = Test-MailAgentE2eInboundSmtpTlsLoadedInLogTail -LogPath $log
    Assert-Ma03Check -StepId 'MA-03-B' -Action 'Inbound SMTP TLS certificate loaded after restart' `
        -Expect "Subject=$tlsSubject; log not 'certificate was not found'" `
        -Actual $(if ($tlsLoaded) { 'TLS load markers in log' } else { "No TLS load evidence in log tail ($log)" }) -Passed:$tlsLoaded

    $subject = 'MA03-B-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $send = Send-Ma03CleanInboundMail -Lab $Lab -SubjectPrefix $subject `
        -InboundServer $InboundServer -InboundPort $Lab.InboundPort -MailFrom $MailFrom -MailTo $MailTo `
        -StepLabel 'MA-03 B' -RequireCapture

    $delivered = ($null -ne $send.Capture)
    $deliveryDetail = if ($delivered) { 'Captured on SimpleMail' } else { 'No SimpleMail capture row' }

    if (-not $delivered -and -not [string]::IsNullOrWhiteSpace($WmcToken) -and -not [string]::IsNullOrWhiteSpace($CoreRestUrl)) {
        $wmcSubjectToken = $send.WmcSubjectContains
        if ([string]::IsNullOrWhiteSpace($wmcSubjectToken)) {
            $wmcSubjectToken = Resolve-MailAgentE2eBulkCoreSubjectContains -SubjectPrefix $send.ActualSubjectPrefix
        }
        if ([string]::IsNullOrWhiteSpace($wmcSubjectToken)) {
            $wmcSubjectToken = $send.ExpectedSubject
        }

        Write-Ma03Step "MA-03 B - WMC delivery check (subject *$wmcSubjectToken*)."
        $row = Wait-CoreE2eWmcEmailSanitizationBySubject -BaseUrl $CoreRestUrl -ApiToken $WmcToken `
            -SubjectContains $wmcSubjectToken -MailTo @($MailTo) -TimeoutSec 120 -AllowedOutcomes @('OutcomePassed')
        $outcome = [string](Get-CoreE2eWmcRestPropertyValue -Object $row -Names @('outcome', 'Outcome'))
        if ($outcome -eq '100' -or $outcome -ieq 'OutcomePassed') {
            $delivered = $true
            $deliveryDetail = "WMC Pass (outcome=$outcome)"
        }
    }

    Assert-Ma03Check -StepId 'MA-03-B' -Action 'One message delivered after inbound TLS policy' `
        -Expect "SimpleMail capture or WMC Pass for *$($send.ExpectedSubject)*" `
        -Actual $deliveryDetail -Passed:$delivered
}

function Invoke-Ma03StepC {
    param(
        [hashtable] $Lab,
        [string] $HookUrl,
        [string] $RelayName,
        [int] $InboundPort,
        [string] $TempFolder,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort,
        [string] $InboundServer,
        [string] $MailFrom,
        [string] $MailTo,
        [ValidateSet('sessions', 'spoolfull', 'spoolcap', 'processing')]
        [string] $OverloadMode = 'sessions',
        [int] $ParallelSends = 22,
        [int] $EmailCount = 24,
        [string] $WmcToken,
        [string] $CoreRestUrl
    )

    Write-Ma03Step 'MA-03 C - restore working capture next hop before capacity test.'
    Update-MailAgentE2eLabCorePolicy -HookUrl $HookUrl -MailAgentDebugUrl $Lab.MailAgentDebugUrl `
        -RelayName $RelayName -NextHopHost $SimpleMailListenHost -NextHopPort $SimpleMailPort `
        -InboundPort $InboundPort -TempFolder $TempFolder -TestId 'MA-03'

    Write-Ma03Step "MA-03 C - enable mail agent debug overload mode=$OverloadMode."
    Set-MailAgentDebugOverload -Mode $OverloadMode -BaseUrl $Lab.MailAgentDebugUrl | Out-Null

    $subject = 'MA03-C-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $bulkConfigPath = New-BulkSendAppsettings -AttachmentFolder $Lab.AttachFolder -SmtpServer $InboundServer `
        -SmtpPort $Lab.InboundPort -From $MailFrom -To $MailTo -SendTimeoutSeconds 45 `
        -SubjectPrefix $subject -EmailCount $EmailCount -MaxParallelSends $ParallelSends `
        -MinAttachmentsPerEmail 1 -MaxAttachmentsPerEmail 1
    $bulkJob = Start-BulkSendOnce -ExePath $Lab.BulkExe -ConfigPath $bulkConfigPath -SubjectPrefix $subject

    $detail = ''
    try {
        $null = Complete-BulkSendOnce -BulkJob $bulkJob -WaitExitTimeoutSec 90 -ProgressLabel 'MA-03 C load' `
            -MailAgentDebugUrl $Lab.MailAgentDebugUrl -EmitLogMarks -E2eTestId 'MA-03' -CoreDebugHookUrl $Lab.CoreDebugHookUrl
    }
    catch {
        $detail = $_.Exception.Message
    }
    finally {
        if ($bulkConfigPath -and (Test-Path -LiteralPath $bulkConfigPath)) {
            Remove-Item -LiteralPath $bulkConfigPath -Force -ErrorAction SilentlyContinue
        }
    }

    $reject = Assert-MailAgentE2eInboundCapacity452Observed -BulkJob $bulkJob -FailureDetail $detail `
        -Context 'MA-03 C overload' -MailAgentDebugUrl $Lab.MailAgentDebugUrl

    Assert-Ma03Check -StepId 'MA-03-C' -Action 'Inbound capacity rejection under overload' `
        -Expect 'SMTP 452 or equivalent 4xx in seconds' `
        -Actual "observedIn=$($reject.ObservedIn)" -Passed:$true

    $status = Wait-MailAgentDebugReady -BaseUrl $Lab.MailAgentDebugUrl -ExpectedInboundPort $Lab.InboundPort
    $procRunning = ($status.coreConnected -eq $true) -and ($status.inboundSmtpListening -eq $true)
    Assert-Ma03Check -StepId 'MA-03-C' -Action 'Mail agent stays up after overload' `
        -Expect 'Authenticated + inbound listening' `
        -Actual (Format-MailAgentDebugStatusSummary -Status $status) -Passed:$procRunning

    Write-Ma03Step 'MA-03 C - overload off.'
    Set-MailAgentDebugOverload -Mode off -BaseUrl $Lab.MailAgentDebugUrl | Out-Null
    Start-Sleep -Seconds 2

    $recoverySubject = 'MA03-C-recover-' + (Get-Date -Format 'yyyyMMddHHmmss')
    $recover = Send-Ma03CleanInboundMail -Lab $Lab -SubjectPrefix $recoverySubject `
        -InboundServer $InboundServer -InboundPort $Lab.InboundPort -MailFrom $MailFrom -MailTo $MailTo `
        -StepLabel 'MA-03 C recovery' -RequireCapture

    Assert-Ma03Check -StepId 'MA-03-C' -Action 'Single mail Pass after overload cleared' `
        -Expect "Capture $($recover.ExpectedSubject)" `
        -Actual 'Delivered to capture' -Passed:($null -ne $recover.Capture)

    if (-not [string]::IsNullOrWhiteSpace($WmcToken)) {
        $null = Wait-CoreE2eWmcEmailSanitizationBySubject -BaseUrl $CoreRestUrl -ApiToken $WmcToken `
            -SubjectContains $recover.ExpectedSubject -MailTo @($MailTo) -TimeoutSec 120
    }
}

function Get-MailAgentE2eStatsHealthCheckProperty {
    param(
        $Check,
        [string[]] $Names
    )

    if ($null -eq $Check) {
        return ''
    }

    foreach ($name in $Names) {
        if ($Check.PSObject.Properties.Match($name).Count -gt 0) {
            $value = $Check.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [string]$value
            }
        }
    }

    return ''
}

function Get-MailAgentE2eMa03DiskSpoolHealthChecks {
    param($Stats)

    if ($null -eq $Stats -or $null -eq $Stats.healthChecks) {
        return @()
    }

    return @($Stats.healthChecks | Where-Object {
        $checkName = Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('name', 'Name')
        -not [string]::IsNullOrWhiteSpace($checkName) -and $checkName -match '(?i)disk|spool|temp/'
    })
}

function Test-MailAgentE2eMa03StatsHasSpoolOrDiskMetrics {
    param($Stats)

    if ($null -eq $Stats) {
        return $false
    }

    if ($null -ne $Stats.operationalMetrics) {
        $om = $Stats.operationalMetrics
        foreach ($prop in @('inboundSpoolBacklog', 'diskFreeBytesTemp', 'diskFreePercentTemp', 'outboundQueueDepth')) {
            if ($om.PSObject.Properties.Match($prop).Count -gt 0) {
                return $true
            }
        }
    }

    return ((Get-MailAgentE2eMa03DiskSpoolHealthChecks -Stats $Stats).Count -gt 0)
}

function Invoke-Ma03StepD {
    param(
        [string] $MailAgentDebugUrl,
        [string] $RelayName
    )

    Write-Ma03Step 'MA-03 D - read mail agent debug stats (substitute for WMC System Health agent rows until API exists).'
    $stats = $null
    try {
        $stats = Invoke-MailAgentDebugHook -Command 'stats' -BaseUrl $MailAgentDebugUrl
    }
    catch {
        Assert-Ma03Check -StepId 'MA-03-D' -Action 'Read agent debug stats' `
            -Expect 'stats command returns spool/disk health fields' `
            -Actual $_.Exception.Message -Passed:$false
    }

    $statsJson = ($stats | ConvertTo-Json -Depth 8 -Compress)
    Write-Ma03Step "MA-03 D stats snapshot: $statsJson"

    $hasSpoolHint = Test-MailAgentE2eMa03StatsHasSpoolOrDiskMetrics -Stats $stats
    if (-not $hasSpoolHint) {
        Assert-Ma03Check -StepId 'MA-03-D' -Action 'Plausible spool/disk utilization in stats or WMC' `
            -Expect 'Spool/disk metrics (WMC System Health or debug stats)' `
            -Actual 'stats JSON has no spool/disk fields' -Passed:$false
    }

    $diskSpoolChecks = @(Get-MailAgentE2eMa03DiskSpoolHealthChecks -Stats $stats)
    if ($diskSpoolChecks.Count -eq 0) {
        Assert-Ma03Check -StepId 'MA-03-D' -Action 'Disk/spool health row present in stats' `
            -Expect 'At least one disk or spool healthChecks entry' `
            -Actual 'No disk/spool healthChecks row' -Passed:$false
    }

    $degradedDisk = @($diskSpoolChecks | Where-Object {
        (Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('status', 'Status')) -match '(?i)^degraded$'
    })
    $diskSummary = ($diskSpoolChecks | ForEach-Object {
        $n = Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('name', 'Name')
        $s = Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('status', 'Status')
        '{0}={1}' -f $n, $s
    }) -join '; '

    $sessionDegraded = @($stats.healthChecks | Where-Object {
        $n = Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('name', 'Name')
        $s = Get-MailAgentE2eStatsHealthCheckProperty -Check $_ -Names @('status', 'Status')
        $n -match '(?i)session' -and $s -match '(?i)^degraded$'
    })
    if ($sessionDegraded.Count -gt 0) {
        Write-Ma03Step 'MA-03 D - Inbound SMTP sessions shows Degraded after step C overload (expected); step D asserts disk/spool only.'
    }

    Assert-Ma03Check -StepId 'MA-03-D' -Action 'Disk not Degraded on healthy lab volume' `
        -Expect 'No Degraded disk/spool status after capacity test' `
        -Actual $(if ($degradedDisk.Count -gt 0) { 'Degraded disk/spool: ' + $diskSummary } else { $diskSummary }) `
        -Passed:($degradedDisk.Count -eq 0)

    $status = Invoke-MailAgentDebugHook -Command 'status' -BaseUrl $MailAgentDebugUrl
    $summary = Format-MailAgentDebugStatusSummary -Status $status
    Write-Ma03Step "MA-03 D status (relay=$RelayName): $summary"
}

function Initialize-MailAgentE2eMa03SharedLab {
    param(
        [Parameter(Mandatory)][string] $CallingScriptRoot,
        [string] $MailAgentDebugUrl,
        [string] $CoreDebugHookUrl,
        [string] $BulkExe,
        [string] $SmsExe,
        [string] $SimpleMailListenHost,
        [int] $SimpleMailPort,
        [double] $ResponseDelaySeconds,
        [string] $CaptureSaveFolder,
        [string] $SmsConfig,
        [int] $SimpleMailStartupTimeoutSec,
        [switch] $SkipStartSimpleMailServer,
        [int] $InboundPort
    )

    $testFilesRoot = Resolve-MailAgentE2eTestFilesRoot -CallingScriptRoot $CallingScriptRoot
    $attachRoot = Get-MailAgentE2eAttachmentFolder -TestFilesRoot $testFilesRoot
    $cleanSample = Join-Path $attachRoot 'clean-sample.txt'
    if (-not (Test-Path -LiteralPath $cleanSample)) {
        throw "MA-03 lab: missing fixture $cleanSample"
    }
    $attachFolder = New-MailAgentE2eAttachmentStagingFolder -SourceFilePaths @($cleanSample)

    if ([string]::IsNullOrWhiteSpace($CaptureSaveFolder)) {
        $CaptureSaveFolder = Join-Path $env:TEMP 'MailE2e-MA03-CapturedOutbound'
    }
    $CaptureSaveFolder = [System.IO.Path]::GetFullPath($CaptureSaveFolder)
    $statusFilePath = Join-Path $CaptureSaveFolder 'simple-mail-server-status.json'

    $smsEnsure = Ensure-MailAgentE2eSimpleMailServerHeadless -SimpleMailServerExe $SmsExe -ConfigPath $SmsConfig `
        -Port $SimpleMailPort -ResponseDelaySeconds $ResponseDelaySeconds -SaveFolder $CaptureSaveFolder `
        -StatusFilePath $statusFilePath -ListenHost $SimpleMailListenHost `
        -StartupTimeoutSec $SimpleMailStartupTimeoutSec -SkipStart:$SkipStartSimpleMailServer
    Assert-MailAgentE2eSimpleMailServerListening -ListenHost $SimpleMailListenHost -Port $SimpleMailPort `
        -SimpleMailServerExe $SmsExe -ConfigPath $SmsConfig -SaveFolder $CaptureSaveFolder `
        -ResponseDelaySeconds $ResponseDelaySeconds -StatusFilePath $statusFilePath

    return @{
        AttachFolder          = $attachFolder
        BulkExe               = $BulkExe
        CaptureFolder         = $CaptureSaveFolder
        StatusFilePath        = $statusFilePath
        MailAgentDebugUrl     = $MailAgentDebugUrl
        CoreDebugHookUrl      = $CoreDebugHookUrl
        SimpleMailProcess     = $smsEnsure.Process
        SimpleMailStartedByScript = [bool]$smsEnsure.StartedByScript
        InboundPort           = $InboundPort
    }
}