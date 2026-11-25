#Requires -Version 5.1
<#
.SYNOPSIS
  WebMC / Core management REST helpers for lab E2E (same host as /debug/hook).

.NOTES
  Uses /v1/auth/login (headers user, password, remoteIp) and apiToken on subsequent calls.
  Credentials: -User/-Password, then CORE_E2E_WMC_USER / CORE_E2E_WMC_PASSWORD, else Core lab defaults
  resec_admin / resec_admin (AdminUser / AdminPassword from install). Viewer+ is enough for /v1/sanitizations/email.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CoreE2ePortalApi.ps1')

$script:CoreE2eWmcDefaultUser = 'resec_admin'
$script:CoreE2eWmcDefaultPassword = 'resec_admin'

function Get-CoreE2eWmcCredentials {
    param(
        [string] $UserOverride = '',
        [string] $PasswordOverride = ''
    )

    $user = $UserOverride
    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = $env:CORE_E2E_WMC_USER
    }

    $password = $PasswordOverride
    if ([string]::IsNullOrWhiteSpace($password)) {
        $password = $env:CORE_E2E_WMC_PASSWORD
    }

    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = $script:CoreE2eWmcDefaultUser
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        $password = $script:CoreE2eWmcDefaultPassword
    }

    return @{
        User     = $user.Trim()
        Password = $password
    }
}

function Connect-CoreE2eWmcRestSession {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [string] $User = '',
        [string] $Password = '',
        [string] $RemoteIp = '127.0.0.1'
    )

    $creds = Get-CoreE2eWmcCredentials -UserOverride $User -PasswordOverride $Password
    $loginUri = '{0}/v1/auth/login' -f $BaseUrl.TrimEnd('/')

    $irmParams = @{
        Uri     = $loginUri
        Method  = 'Post'
        Headers = @{
            user     = $creds.User
            password = $creds.Password
            remoteIp = $RemoteIp
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $irmParams.SkipCertificateCheck = $true
    }
    else {
        Enable-CoreE2eDebugTlsBypass
    }

    $raw = Invoke-RestMethod @irmParams
    if ($raw -is [string]) {
        $login = $raw | ConvertFrom-Json
    }
    else {
        $login = $raw
    }

    $token = [string]$login.apiToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $reason = [string]$login.failureReason
        throw "WMC login failed for user '$($creds.User)'. FailureReason='$reason'."
    }

    return $token
}

function Get-CoreE2eWmcSanitizationQueryTimeRange {
    param(
        [int] $LookbackDays = 7
    )

    # WebMC always sends startTime/endTime. Omitting them makes SanitizationQueryParamsMapper use DateTime.MinValue
    # for both, and DbHelper.ApplyUploadTimeFilter then matches almost nothing.
    $end = [DateTime]::UtcNow
    $start = $end.AddDays(-1 * [Math]::Abs($LookbackDays))
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    return @{
        StartTime = $start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $culture)
        EndTime   = $end.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $culture)
    }
}

function Get-CoreE2eWmcRestPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Invoke-CoreE2eWmcRestMethod {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [string] $Path,
        [ValidateSet('Get', 'Post')]
        [string] $Method = 'Get',
        [hashtable] $BodyObject,
        [hashtable] $ExtraHeaders,
        [int] $TimeoutSec = 120
    )

    return Invoke-CoreE2ePortalRestMethod -BaseUrl $BaseUrl -Path $Path -PortalApiToken $ApiToken `
        -Method $Method -BodyObject $BodyObject -ExtraHeaders $ExtraHeaders -TimeoutSec $TimeoutSec
}

# SanitizationWorkflowAction.Resubmit (1 << 1)
$script:CoreE2eWmcWorkflowActionResubmit = 2

function Invoke-CoreE2eWmcPerformWorkflowAction {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId,
        [Parameter(Mandatory)]
        [int] $Action,
        [int] $PolicyId = 0
    )

    $query = "sanitizationId=$SanitizationId&action=$Action&resultMsg="
    if ($PolicyId -gt 0) {
        $query += "&policyId=$PolicyId"
    }

    $path = '/v1/sanitizations/workflow-actions/perform?' + $query
    $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
        -Path $path -Method Get

    $actionId = [string](Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('actionId', 'ActionId'))
    if ([string]::IsNullOrWhiteSpace($actionId)) {
        throw "Perform workflow action returned empty actionId (sanitizationId=$SanitizationId action=$Action)."
    }

    return $actionId
}

function Test-CoreE2eWmcWorkflowActionStillPending {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $errorText = [string](Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('error', 'Error'))
    $resultOk = Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('result', 'Result')

    if ($errorText -like '*No information*') {
        return $true
    }

    if ($resultOk -eq $true -or $resultOk -eq 'True') {
        $data = Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('data', 'Data')
        if ($null -eq $data) {
            return $true
        }

        $childId = [int](Get-CoreE2eWmcRestPropertyValue -Object $data -Names @('sanitizationId', 'SanitizationId'))
        $errorIsInfoOnly = ($errorText -like '*Sanitization info not found*')
        if ($childId -le 0 -and $errorIsInfoOnly) {
            return $true
        }

        return $false
    }

    if ($resultOk -eq $false -or $resultOk -eq 'False' -or $resultOk -eq 'false') {
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $data = Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('data', 'Data')
            if ($null -eq $data) {
                return $true
            }

            $childId = [int](Get-CoreE2eWmcRestPropertyValue -Object $data -Names @('sanitizationId', 'SanitizationId'))
            if ($childId -le 0) {
                return $true
            }
        }
    }

    return $false
}

function Wait-CoreE2eWmcWorkflowActionResult {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [string] $ActionId,
        [Parameter(Mandatory)]
        [int] $SanitizationId,
        [int] $TimeoutSec = 120,
        [int] $PollSec = 2
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $pollIndex = 0
    $lastResponseJson = ''

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pollIndex++
        $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
            -Path '/v1/sanitizations/workflow-actions/result' -Method Post -ExtraHeaders @{
                actionId       = $ActionId
                sanitizationId = [string]$SanitizationId
            }

        $lastResponseJson = try { $response | ConvertTo-Json -Depth 8 -Compress } catch { [string]$response }

        if (Test-CoreE2eWmcWorkflowActionStillPending -Response $response) {
            if ($pollIndex -eq 1 -or ($pollIndex % 10) -eq 0) {
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Workflow poll ${pollIndex}: pending actionId=$ActionId"
            }

            Start-Sleep -Seconds $PollSec
            continue
        }

        $errorText = [string](Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('error', 'Error'))
        $resultOk = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('result', 'Result')

        if ($resultOk -eq $false -or $resultOk -eq 'False' -or $resultOk -eq 'false') {
            $data = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('data', 'Data')
            $dataOutcome = ''
            if ($null -ne $data) {
                $dataOutcome = [string](Get-CoreE2eWmcRestPropertyValue -Object $data -Names @('outcome', 'Outcome'))
            }

            throw "Workflow action $ActionId failed: error='$errorText' dataOutcome='$dataOutcome' response=$lastResponseJson"
        }

        $data = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('data', 'Data')
        if ($null -eq $data) {
            throw "Workflow action $ActionId completed without data payload. response=$lastResponseJson"
        }

        return $data
    }

    throw "Workflow action $ActionId did not complete within ${TimeoutSec}s (last response=$lastResponseJson)."
}

function Get-CoreE2eSanitizationLogHistory {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId
    )

    $path = '/v1/sanitizations/details?sanitizationId={0}' -f $SanitizationId
    $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
        -Path $path -Method Get

    return [string](Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('logHistory', 'LogHistory'))
}

function Get-CoreE2eWmcEmailSanitizationRow {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId,
        [int] $SanitizationTypeEmail = 1
    )

    $range = Get-CoreE2eWmcSanitizationQueryTimeRange
    $body = @{
        sanitizationId   = $SanitizationId
        sanitizationType = $SanitizationTypeEmail
        startTime        = $range.StartTime
        endTime          = $range.EndTime
        pageIndex        = 1
        pageSize         = 10
    }

    $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
        -Path '/v1/sanitizations/email' -Method Post -BodyObject $body

    $data = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('data', 'Data')
    $rows = @($data)
    if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
        throw "No email sanitization row returned for sanitizationId=$SanitizationId (WMC /v1/sanitizations/email)."
    }

    $match = @($rows | Where-Object {
            $rowId = Get-CoreE2eWmcRestPropertyValue -Object $_ -Names @('sanitizationId', 'SanitizationId')
            [int]$rowId -eq $SanitizationId
        } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        $match = @($rows | Select-Object -First 1)
    }

    return $match[0]
}

$script:CoreE2eWmcEmailOutcomeNameToValue = @{
    OutcomePassed               = 100
    OutcomeModified             = 101
    OutcomePartiallyProcessed   = 102
    OutcomeContentRemoved       = 103
    OutcomePasswordProtectedContentRemoved = 104
    OutcomeRedacted             = 105
    OutcomeReconstructed        = 106
    OutcomeMultipartReceived    = 107
    OutcomeBypassed             = 108
    OutcomeReleased             = 109
}

function Test-CoreE2eWmcEmailSanitizationOutcomeAllowed {
    param(
        $Outcome,
        [string[]] $AllowedOutcomes
    )

    if ($AllowedOutcomes.Count -eq 0) {
        return $true
    }

    if ($null -eq $Outcome) {
        return $false
    }

    $text = [string]$Outcome
    if ($AllowedOutcomes -contains $text) {
        return $true
    }

    $allowedInts = @()
    foreach ($name in $AllowedOutcomes) {
        if ($script:CoreE2eWmcEmailOutcomeNameToValue.ContainsKey($name)) {
            $allowedInts += $script:CoreE2eWmcEmailOutcomeNameToValue[$name]
        }
    }

    if ($text -match '^\d+$') {
        return $allowedInts -contains [int]$text
    }

    return $false
}

function Test-CoreE2eWmcEmailRowSubjectMatches {
    param(
        $Row,
        [Parameter(Mandatory)]
        [string] $SubjectContains
    )

    if ($null -eq $Row) {
        return $false
    }

    foreach ($prop in @('mailSubject', 'MailSubject', 'fileName', 'FileName')) {
        $value = [string](Get-CoreE2eWmcRestPropertyValue -Object $Row -Names @($prop))
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -like "*$SubjectContains*") {
            return $true
        }
    }

    return $false
}

function Wait-CoreE2eWmcEmailSanitizationBySubject {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [string] $SubjectContains,
        [string[]] $MailTo = @(),
        [int] $TimeoutSec = 120,
        [int] $PollSec = 3,
        [string[]] $AllowedOutcomes = @('OutcomePassed', 'OutcomeModified', 'OutcomePartiallyProcessed', 'OutcomeReconstructed')
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $pollIndex = 0
    $lastDiag = ''

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pollIndex++
        $range = Get-CoreE2eWmcSanitizationQueryTimeRange
        $queries = @(
            @{ useSubjectFilter = $true }
            @{ useSubjectFilter = $false }
        )

        foreach ($mode in $queries) {
            $body = @{
                startTime        = $range.StartTime
                endTime          = $range.EndTime
                pageIndex        = 1
                pageSize         = 50
                sanitizationType = 1
                sortField        = 'TimeUploaded'
                sortOrder        = 'Desc'
            }
            if ($mode.useSubjectFilter) {
                $body.subject = $SubjectContains
            }
            if ($MailTo -and $MailTo.Count -gt 0) {
                $body.to = @($MailTo | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
                -Path '/v1/sanitizations/email' -Method Post -BodyObject $body
            $data = Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('data', 'Data')
            $rows = @($data)
            if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
                $lastDiag = 'rows=0'
                continue
            }

            foreach ($row in $rows) {
                if ($null -eq $row) {
                    continue
                }
                if (-not (Test-CoreE2eWmcEmailRowSubjectMatches -Row $row -SubjectContains $SubjectContains)) {
                    continue
                }

                $outcome = Get-CoreE2eWmcRestPropertyValue -Object $row -Names @('outcome', 'Outcome')
                if (-not (Test-CoreE2eWmcEmailSanitizationOutcomeAllowed -Outcome $outcome -AllowedOutcomes $AllowedOutcomes)) {
                    $lastDiag = "matched subject but outcome=$outcome (waiting for $($AllowedOutcomes -join ','))"
                    continue
                }

                return $row
            }
        }

        if ($pollIndex -eq 1 -or ($pollIndex % 5) -eq 0) {
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] WMC poll ${pollIndex}: subject '*$SubjectContains*'; $lastDiag"
        }

        Start-Sleep -Seconds $PollSec
    }

    throw "WMC did not show email sanitization with subject containing '$SubjectContains' and allowed outcome within ${TimeoutSec}s (last: $lastDiag)."
}
