#Requires -Version 5.1
<#
.SYNOPSIS
  Core /v1/portal REST helpers for Password Portal lab E2E (same host as /debug/hook).
.NOTES
  Portal routes require header apiToken matching system property Portal_Secret.
#>
Set-StrictMode -Version Latest

function Get-CoreE2eCoreRestBaseUrl {
    param(
        [string] $HookUrl = '',
        [string] $Override = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_CORE_REST_BASE_URL)) {
        return $env:CORE_E2E_CORE_REST_BASE_URL.Trim().TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:MAIL_E2E_CORE_DEBUG_BASE_URL)) {
        return $env:MAIL_E2E_CORE_DEBUG_BASE_URL.Trim().TrimEnd('/')
    }

    if ([string]::IsNullOrWhiteSpace($HookUrl)) {
        if (-not (Get-Command Get-CoreE2eDebugHookUrl -ErrorAction SilentlyContinue)) {
            throw 'Get-CoreE2eCoreRestBaseUrl requires HookUrl or CORE_E2E_CORE_REST_BASE_URL when CoreE2eDebugHook.ps1 is not loaded.'
        }

        $HookUrl = Get-CoreE2eDebugHookUrl
    }

    $uri = [Uri]$HookUrl.Trim()
    $path = $uri.AbsolutePath
    if ($path -match '/debug/hook') {
        $path = $path -replace '/debug/hook.*$', ''
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = '/'
    }

    $builder = New-Object System.UriBuilder $uri.Scheme, $uri.Host, $uri.Port, $path
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}

function Get-CoreE2eSystemPropertyValue {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $PropertyName
    )

    $export = Invoke-CoreE2eDebugHook -HookUrl $HookUrl -Command 'exportsystempropertystate'
    Assert-CoreE2eDebugHookResponse -Response $export -Step 'exportsystempropertystate'

    $match = @($export.systemProperties | Where-Object { [string]$_.name -eq $PropertyName } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        return $null
    }

    return [string]$match[0].propValue
}

function New-CoreE2ePortalSanitizationSignature {
    param(
        [Parameter(Mandatory)]
        [string] $PortalSecret,
        [Parameter(Mandatory)]
        [int] $SanitizationId
    )

    $stream = New-Object System.IO.MemoryStream
    try {
        $idBytes = [BitConverter]::GetBytes([int32]$SanitizationId)
        $stream.Write($idBytes, 0, $idBytes.Length) | Out-Null
        $secretBytes = [System.Text.Encoding]::Unicode.GetBytes($PortalSecret)
        $stream.Write($secretBytes, 0, $secretBytes.Length) | Out-Null
        $stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($stream)
        return (($hash | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-CoreE2ePortalRestMethod {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $PortalApiToken,
        [ValidateSet('Get', 'Post')]
        [string] $Method = 'Get',
        [hashtable] $BodyObject,
        [int] $TimeoutSec = 120
    )

    $uri = '{0}{1}' -f $BaseUrl.TrimEnd('/'), $Path
    $irmParams = @{
        Uri        = $uri
        Method     = $Method
        Headers    = @{ apiToken = $PortalApiToken }
        TimeoutSec = $TimeoutSec
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $irmParams.SkipCertificateCheck = $true
    }
    else {
        Enable-CoreE2eDebugTlsBypass
    }

    if ($BodyObject) {
        $json = $BodyObject | ConvertTo-Json -Depth 20 -Compress
        $irmParams.Body = $json
        $irmParams.ContentType = 'application/json; charset=utf-8'
    }

    return Invoke-RestMethod @irmParams
}

function Get-CoreE2ePortalFileData {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $PortalApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId
    )

    $path = '/v1/portal/file-data?sanitizationId={0}' -f $SanitizationId
    return Invoke-CoreE2ePortalRestMethod -BaseUrl $BaseUrl -Path $path -PortalApiToken $PortalApiToken -Method Get
}

function Submit-CoreE2ePortalFilePassword {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $PortalApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId,
        [Parameter(Mandatory)]
        [string] $Signature,
        [Parameter(Mandatory)]
        [string] $InternalName,
        [Parameter(Mandatory)]
        [string] $Password
    )

    $body = @{
        requestId       = 1
        sanitizationId  = $SanitizationId
        signature       = $Signature
        fileRequest     = @{
            internalName = $InternalName
            password     = $Password
            files        = @()
        }
    }

    return Invoke-CoreE2ePortalRestMethod -BaseUrl $BaseUrl -Path '/v1/portal/submit-file-data' `
        -PortalApiToken $PortalApiToken -Method Post -BodyObject $body
}

function Test-CoreE2ePortalFileDataIsFinal {
    param(
        [Parameter(Mandatory)]
        $FileData
    )

    if ($null -eq $FileData) {
        return $false
    }

    $outcome = 0
    if ($FileData.PSObject.Properties.Name -contains 'outcome') {
        $outcome = [int]$FileData.outcome
    }

    $state = 0
    if ($FileData.PSObject.Properties.Name -contains 'sanitizationState') {
        $state = [int]$FileData.sanitizationState
    }

    if ($state -eq 40) {
        return $false
    }

    if ($outcome -gt 0 -and $outcome -lt 50) {
        return $false
    }

    if ($outcome -eq 0 -and $state -eq 0) {
        return $false
    }

    return $true
}

function Wait-CoreE2ePortalFileDataFinal {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $PortalApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId,
        [int] $TimeoutSec = 300,
        [string] $ScenarioLabel = 'portal file-data'
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $last = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $last = Get-CoreE2ePortalFileData -BaseUrl $BaseUrl -PortalApiToken $PortalApiToken `
                -SanitizationId $SanitizationId
            if (Test-CoreE2ePortalFileDataIsFinal -FileData $last) {
                return $last
            }
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -notmatch 'actively refused|No connection could be made|Unable to connect|connection attempt failed') {
                throw
            }
        }

        Start-Sleep -Seconds 2
    }

    throw "[$ScenarioLabel] Portal file-data did not reach a final state within ${TimeoutSec}s (sanitizationId=$SanitizationId)."
}

function Resolve-CoreE2ePortalPasswordSubmitInternalName {
    param(
        [Parameter(Mandatory)]
        $FileData,
        [string] $PreferredInternalName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredInternalName)) {
        return $PreferredInternalName
    }

    if ($null -eq $FileData) {
        throw 'Cannot resolve portal InternalName from empty file-data.'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$FileData.internalName)) {
        return [string]$FileData.internalName
    }

    if ($FileData.files -and @($FileData.files).Count -gt 0) {
        $first = @($FileData.files | Select-Object -First 1)[0]
        if (-not [string]::IsNullOrWhiteSpace([string]$first.internalName)) {
            return [string]$first.internalName
        }
    }

    throw 'Portal file-data did not include internalName for password submit.'
}
