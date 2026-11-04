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
        [int] $TimeoutSec = 120
    )

    return Invoke-CoreE2ePortalRestMethod -BaseUrl $BaseUrl -Path $Path -PortalApiToken $ApiToken `
        -Method $Method -BodyObject $BodyObject -TimeoutSec $TimeoutSec
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
