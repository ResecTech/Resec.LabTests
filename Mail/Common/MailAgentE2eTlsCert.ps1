#Requires -Version 5.1
<#
.SYNOPSIS
  Resolves a machine-local certificate subject for StrPropType_SmtpSenderIncomingTlsCertificateSubject (mail agent inbound SMTP TLS).
#>

$script:MailAgentE2eInboundTlsCertSubjectEnvVar = 'MAIL_E2E_INBOUND_TLS_CERTIFICATE_SUBJECT'

function Get-MailAgentE2eCertificateCnFromSubject {
    param([string] $Subject)

    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return ''
    }

    if ($Subject -match '(?i)CN\s*=\s*([^,;]+)') {
        return $Matches[1].Trim().Trim('"')
    }

    return $Subject.Trim()
}

function Get-MailAgentE2eCertificateSanNames {
    param($Certificate)

    if ($null -eq $Certificate -or $null -eq $Certificate.DnsNameList) {
        return @()
    }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Certificate.DnsNameList) {
        if ($null -eq $entry) {
            continue
        }

        $name = $null
        if ($entry -is [string]) {
            $name = $entry
        }
        else {
            $unicodeProp = $entry.PSObject.Properties['Unicode']
            if ($null -ne $unicodeProp -and -not [string]::IsNullOrWhiteSpace([string]$unicodeProp.Value)) {
                $name = [string]$unicodeProp.Value
            }
            else {
                $punyProp = $entry.PSObject.Properties['Punycode']
                if ($null -ne $punyProp -and -not [string]::IsNullOrWhiteSpace([string]$punyProp.Value)) {
                    $name = [string]$punyProp.Value
                }
                else {
                    $name = [string]$entry
                }
            }
        }

        $name = $name.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$names.Add($name)
        }
    }

    return $names.ToArray()
}

function Test-MailAgentE2eCertificateSuitableForInboundTls {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate)

    if (-not $Certificate.HasPrivateKey) {
        return $false
    }

    if ($Certificate.NotAfter -le (Get-Date)) {
        return $false
    }

    $hasServerAuth = $false
    $hasEku = $false
    foreach ($usage in $Certificate.EnhancedKeyUsageList) {
        if ($null -eq $usage) {
            continue
        }

        $hasEku = $true
        $oid = ''
        $valueProp = $usage.PSObject.Properties['Value']
        if ($null -ne $valueProp) {
            $oid = [string]$valueProp.Value
        }

        $friendly = ''
        $friendlyProp = $usage.PSObject.Properties['FriendlyName']
        if ($null -ne $friendlyProp) {
            $friendly = [string]$friendlyProp.Value
        }

        if ($oid -eq '1.3.6.1.5.5.7.3.1') {
            $hasServerAuth = $true
        }
        elseif ($friendly -match '(?i)Server\s+Authentication') {
            $hasServerAuth = $true
        }
    }

    if ($hasEku -and -not $hasServerAuth) {
        return $false
    }

    return $true
}

function Get-MailAgentE2eInboundTlsCertificateCandidates {
    $storePaths = @(
        @{ Path = 'Cert:\LocalMachine\My'; Label = 'LocalMachine\My' },
        @{ Path = 'Cert:\CurrentUser\My'; Label = 'CurrentUser\My' }
    )

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($store in $storePaths) {
        $certs = @(Get-ChildItem -Path $store.Path -ErrorAction SilentlyContinue)
        foreach ($cert in $certs) {
            if (-not (Test-MailAgentE2eCertificateSuitableForInboundTls -Certificate $cert)) {
                continue
            }

            $cn = Get-MailAgentE2eCertificateCnFromSubject -Subject $cert.Subject
            $san = @(Get-MailAgentE2eCertificateSanNames -Certificate $cert)
            if ([string]::IsNullOrWhiteSpace($cn)) {
                if ($san.Count -gt 0) {
                    $cn = $san[0]
                }
                else {
                    continue
                }
            }

            if ($cert.Subject -notmatch '(?i)\bCN=' -and $cn -match '(?i)^DC=') {
                continue
            }

            [void]$list.Add([pscustomobject]@{
                    Cn           = $cn
                    Subject      = $cert.Subject
                    Store        = $store.Label
                    Thumbprint   = $cert.Thumbprint
                    NotAfter     = $cert.NotAfter
                    HasLocalhost = ($cn -ieq 'localhost') -or ($san -icontains 'localhost')
                })
        }
    }

    return $list.ToArray()
}

function Resolve-MailAgentE2eInboundTlsCertificateSubject {
    <#
    Value for StrPropType_SmtpSenderIncomingTlsCertificateSubject (WebMC label: Incoming TLS Certificate Subject).
    Override via -Subject or MAIL_E2E_INBOUND_TLS_CERTIFICATE_SUBJECT; else pick CN=localhost from store, then any server-auth cert.
    #>
    param([string] $Subject = '')

    if (-not [string]::IsNullOrWhiteSpace($Subject)) {
        return $Subject.Trim()
    }

    $envVal = $env:MAIL_E2E_INBOUND_TLS_CERTIFICATE_SUBJECT
    if (-not [string]::IsNullOrWhiteSpace($envVal)) {
        return $envVal.Trim()
    }

    $candidates = @(Get-MailAgentE2eInboundTlsCertificateCandidates)
    if ($candidates.Count -eq 0) {
        throw @(
            'No suitable inbound TLS certificate found in LocalMachine\My or CurrentUser\My (needs private key, not expired, Server Authentication EKU when EKU is present).'
            'Install a cert (e.g. CN=localhost) or set -Ma03IncomingTlsCertificateSubject / MAIL_E2E_INBOUND_TLS_CERTIFICATE_SUBJECT.'
        ) -join ' '
    }

    $localhost = @($candidates | Where-Object { $_.HasLocalhost } | Sort-Object NotAfter -Descending)
    if ($localhost.Count -gt 0) {
        $pick = $localhost[0]
        Write-Host ("[INFO] MA-03 B inbound TLS cert: CN={0} ({1}, thumb={2})" -f $pick.Cn, $pick.Store, $pick.Thumbprint)
        return $pick.Cn
    }

    $pick = @($candidates | Sort-Object NotAfter -Descending)[0]
    Write-Host ("[INFO] MA-03 B inbound TLS cert (no localhost): CN={0} ({1}, thumb={2})" -f $pick.Cn, $pick.Store, $pick.Thumbprint)
    return $pick.Cn
}

function Test-MailAgentE2eInboundSmtpTlsLoadedInLogTail {
    param(
        [Parameter(Mandatory)][string] $LogPath,
        [int] $TailLineCount = 120
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $tail = @(Get-Content -LiteralPath $LogPath -Tail $TailLineCount -ErrorAction SilentlyContinue)
    $blob = ($tail -join [Environment]::NewLine)
    if ($blob -match '(?i)without TLS since the server certificate was not found') {
        return $false
    }

    return ($blob -match '(?i)(Loading the Smtp Server with TLS|inbound.*tls|SmtpListener.*TLS|TLS.*certificate)')
}