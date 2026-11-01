#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:MailAgentE2eSimpleMailServerEnvVar = 'MAIL_E2E_SIMPLE_MAIL_SERVER_EXE'
$script:MailAgentE2eSendBulkAttachmentMailEnvVar = 'MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE'

function Get-MailAgentE2eRepoRoot {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot
    )

    if (-not (Get-Command Get-LabProductRepoRoot -ErrorAction SilentlyContinue)) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        . (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
    }

    return Get-LabProductRepoRoot -Product Mail
}

function Get-LabTestsRootForMailE2eTools {
    if (-not (Get-Command Get-LabTestsRoot -ErrorAction SilentlyContinue)) {
        $labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        . (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
    }

    return Get-LabTestsRoot
}

function Get-SimpleMailServerToolDirectories {
    param([Parameter(Mandatory)][string] $CallingScriptRoot)

    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add((Join-Path (Get-LabTestsRootForMailE2eTools) 'Tools\SimpleMailServer'))

    try {
        $legacyMailRoot = Get-MailAgentE2eRepoRoot -CallingScriptRoot $CallingScriptRoot
        $dirs.Add((Join-Path $legacyMailRoot 'SimpleMailServer'))
    }
    catch {
    }

    return $dirs
}

function Get-MailAgentE2eToolPathCandidates {
    param(
        [Parameter(Mandatory)]
        [string] $ToolName,
        [Parameter(Mandatory)]
        [string] $ExecutableFileName,
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $ExplicitPath = ''
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add($ExplicitPath.Trim())
    }

    $toolDirectories = New-Object System.Collections.Generic.List[string]
    if ($ToolName -eq 'SimpleMailServer') {
        foreach ($dir in @(Get-SimpleMailServerToolDirectories -CallingScriptRoot $CallingScriptRoot)) {
            if (-not [string]::IsNullOrWhiteSpace($dir)) {
                $toolDirectories.Add($dir)
            }
        }
    }
    else {
        $repoRoot = Get-MailAgentE2eRepoRoot -CallingScriptRoot $CallingScriptRoot
        $toolDirectories.Add((Join-Path $repoRoot $ToolName))
    }

    foreach ($toolDir in $toolDirectories) {
        foreach ($configuration in @('Debug', 'Release')) {
            $candidates.Add((Join-Path $toolDir "bin\$configuration\net10.0-windows7.0\win-x64\$ExecutableFileName"))
            $candidates.Add((Join-Path $toolDir "bin\x64\$configuration\net10.0-windows7.0\win-x64\$ExecutableFileName"))
            $candidates.Add((Join-Path $toolDir "bin\publish\single-file\$ExecutableFileName"))
        }
    }

    try {
        $fromPath = Get-Command -Name $ExecutableFileName -ErrorAction Stop
        if ($null -ne $fromPath -and -not [string]::IsNullOrWhiteSpace($fromPath.Source)) {
            $candidates.Add($fromPath.Source)
        }
    }
    catch {
    }

    return $candidates
}

function Find-MailAgentE2eToolPath {
    param(
        [Parameter(Mandatory)]
        [string] $ToolName,
        [Parameter(Mandatory)]
        [string] $ExecutableFileName,
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $ExplicitPath = '',
        [string] $EnvironmentVariableName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $explicit = $ExplicitPath.Trim()
        if (Test-Path -LiteralPath $explicit) {
            return [System.IO.Path]::GetFullPath($explicit)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariableName)) {
        $fromEnv = [Environment]::GetEnvironmentVariable($EnvironmentVariableName)
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
            $envPath = $fromEnv.Trim()
            if (Test-Path -LiteralPath $envPath) {
                return [System.IO.Path]::GetFullPath($envPath)
            }
        }
    }

    $checked = @{}
    foreach ($candidate in @(Get-MailAgentE2eToolPathCandidates -ToolName $ToolName `
                -ExecutableFileName $ExecutableFileName -CallingScriptRoot $CallingScriptRoot `
                -ExplicitPath $ExplicitPath)) {
        try {
            $resolved = [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
            continue
        }
        if ($checked.ContainsKey($resolved)) {
            continue
        }
        $checked[$resolved] = $true
        if (Test-Path -LiteralPath $resolved) {
            return $resolved
        }
    }

    return $null
}

function Set-MailAgentE2eToolEnvironment {
    <#
    .SYNOPSIS
      Locates Mail Agent E2E utility executables and sets session environment variables.
    .DESCRIPTION
      Sets MAIL_E2E_SIMPLE_MAIL_SERVER_EXE and MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE when found.
      Skips variables that are already set to an existing file unless -Force is specified.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [switch] $Force,
        [switch] $Quiet
    )

    $definitions = @(
        @{
            ToolName = 'SimpleMailServer'
            ExecutableFileName = 'SimpleMailServer.exe'
            EnvironmentVariableName = $script:MailAgentE2eSimpleMailServerEnvVar
        },
        @{
            ToolName = 'SendBulkAttachmentMail'
            ExecutableFileName = 'SendBulkAttachmentMail.exe'
            EnvironmentVariableName = $script:MailAgentE2eSendBulkAttachmentMailEnvVar
        }
    )

    $results = @{}
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($def in $definitions) {
        $envName = $def.EnvironmentVariableName
        $existing = [Environment]::GetEnvironmentVariable($envName)
        if (-not $Force -and -not [string]::IsNullOrWhiteSpace($existing) -and (Test-Path -LiteralPath $existing.Trim())) {
            $path = [System.IO.Path]::GetFullPath($existing.Trim())
            $results[$envName] = $path
            if (-not $Quiet) {
                Write-Host "$envName already set: $path"
            }
            continue
        }

        $found = Find-MailAgentE2eToolPath -ToolName $def.ToolName `
            -ExecutableFileName $def.ExecutableFileName `
            -CallingScriptRoot $CallingScriptRoot `
            -EnvironmentVariableName ''

        if ($null -eq $found) {
            $missing.Add("$($def.ExecutableFileName) ($envName)")
            continue
        }

        Set-Item -Path "Env:$envName" -Value $found
        $results[$envName] = $found
        if (-not $Quiet) {
            Write-Host "Set $envName=$found"
        }
    }

    if ($missing.Count -gt 0) {
        throw ("Could not locate: " + ($missing -join '; ') + ". Build the utils or add them to PATH, then re-run Initialize-MailAgentE2eToolPaths.ps1.")
    }

    return $results
}

function Resolve-MailAgentE2eToolPath {
    param(
        [Parameter(Mandatory)]
        [string] $ToolName,
        [Parameter(Mandatory)]
        [string] $ExecutableFileName,
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $ExplicitPath = '',
        [string] $EnvironmentVariableName = ''
    )

    $found = Find-MailAgentE2eToolPath -ToolName $ToolName -ExecutableFileName $ExecutableFileName `
        -CallingScriptRoot $CallingScriptRoot -ExplicitPath $ExplicitPath `
        -EnvironmentVariableName $EnvironmentVariableName

    if ($null -ne $found) {
        return $found
    }

    $envHint = ''
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariableName)) {
        $envHint = " Set $EnvironmentVariableName, or run Mail\Common\Initialize-MailAgentE2eToolPaths.ps1 from Resec.LabTests."
    }

    $buildHint = if ($ToolName -eq 'SimpleMailServer') {
        'Resec.LabTests\Tools\SimpleMailServer'
    }
    else {
        "Resec.Agent.Mail\$ToolName"
    }

    throw "$ExecutableFileName not found. Build $buildHint (Debug|Release), pass an explicit -Path parameter, or locate tools via environment.$envHint"
}

function Resolve-SimpleMailServerPath {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $Path = ''
    )

    return Resolve-MailAgentE2eToolPath -ToolName 'SimpleMailServer' -ExecutableFileName 'SimpleMailServer.exe' `
        -CallingScriptRoot $CallingScriptRoot -ExplicitPath $Path `
        -EnvironmentVariableName $script:MailAgentE2eSimpleMailServerEnvVar
}

function Resolve-SendBulkAttachmentMailPath {
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot,
        [string] $Path = ''
    )

    return Resolve-MailAgentE2eToolPath -ToolName 'SendBulkAttachmentMail' -ExecutableFileName 'SendBulkAttachmentMail.exe' `
        -CallingScriptRoot $CallingScriptRoot -ExplicitPath $Path `
        -EnvironmentVariableName $script:MailAgentE2eSendBulkAttachmentMailEnvVar
}
