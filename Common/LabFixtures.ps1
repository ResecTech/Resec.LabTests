#Requires -Version 5.1
<#
.SYNOPSIS
  Shared fixture root for all Resec.LabTests product suites.
#>
Set-StrictMode -Version Latest

$script:LabSanitizeFixtureSubdirs = @('Allowed', 'Blocked', 'CDR')
$script:LabLegacyScanAgentFixtureFolderName = 'SA-TestFiles'

function Get-LabFixturesRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_FIXTURES_ROOT)) {
        $full = [System.IO.Path]::GetFullPath($env:LAB_FIXTURES_ROOT.Trim())
        if (-not [System.IO.Directory]::Exists($full)) {
            throw "LAB_FIXTURES_ROOT not found: $full"
        }
        return $full
    }

    $configPath = Get-LabConfigFilePath
    if (Test-Path -LiteralPath $configPath) {
        $json = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        if ($null -ne $json.optional -and ($json.optional.PSObject.Properties.Name -contains 'fixturesRoot')) {
            $configured = [string]$json.optional.fixturesRoot
            if (-not [string]::IsNullOrWhiteSpace($configured)) {
                $full = [System.IO.Path]::GetFullPath($configured.Trim())
                if (-not [System.IO.Directory]::Exists($full)) {
                    throw "optional.fixturesRoot not found: $full"
                }
                return $full
            }
        }
    }

    $default = Join-Path (Get-LabTestsRoot) 'Fixtures'
    if (-not [System.IO.Directory]::Exists($default)) {
        throw "Default fixtures folder not found: $default"
    }
    return [System.IO.Path]::GetFullPath($default)
}

function Test-LabSanitizeFixtureLayout {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not [System.IO.Directory]::Exists($Path)) {
        return $false
    }

    foreach ($subdir in $script:LabSanitizeFixtureSubdirs) {
        if ([System.IO.Directory]::Exists((Join-Path $Path $subdir))) {
            return $true
        }
    }

    return $false
}

function Get-LabFixturePath {
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath
    )

    $root = Get-LabFixturesRoot
    $full = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Fixture path not found: $full"
    }

    return [System.IO.Path]::GetFullPath($full)
}

function Get-LabMailAttachmentFolder {
    return Get-LabFixturePath -RelativePath 'Mail\E2eAttach'
}

function Get-LabCoreQrNcp7330FixtureRoot {
    return Get-LabFixturePath -RelativePath 'QR\NCP-7330'
}

function Get-LabDefaultCdrFixtureFolder {
    return Get-LabFixturePath -RelativePath 'CDR'
}
