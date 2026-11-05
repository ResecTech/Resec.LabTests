#Requires -Version 5.1
<#
  Resolve product executables under lab deploy folders and update RESEC_*_EXE_LOCATION user env vars.
  Dot-source from Deploy\*.ps1 scripts.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Set-ResecLabExeLocationUserEnv.Function.ps1')

function Get-ResecLabDeployExeLocationProfile {
    param(
        [Parameter(Mandatory)]
        [string] $DeployScriptId
    )

    $id = $DeployScriptId.Trim()
    switch -Regex ($id) {
        '^Core$' {
            return [PSCustomObject]@{
                ExecutableFileNames     = @('Resec.Core.exe')
                EnvironmentVariableNames = @('RESEC_CORE_EXE_LOCATION', 'LAB_CORE_EXE')
            }
        }
        '^ScanAgent$' {
            return [PSCustomObject]@{
                ExecutableFileNames     = @('Resec.Agent.ScanAgent.exe')
                EnvironmentVariableNames = @('RESEC_SCANAGENT_EXE_LOCATION', 'LAB_SCANAGENT_EXE', 'SCANAGENT_EXE')
            }
        }
        '^Mail$' {
            return [PSCustomObject]@{
                ExecutableFileNames     = @('Resec.Agent.Mail.exe')
                EnvironmentVariableNames = @('RESEC_MAIL_AGENT_EXE_LOCATION', 'LAB_MAIL_AGENT_EXE')
            }
        }
        '^RestApi$' {
            return [PSCustomObject]@{
                ExecutableFileNames     = @('Resec.Agent.RestAPI.exe')
                EnvironmentVariableNames = @('RESEC_RESTAPI_EXE_LOCATION', 'LAB_RESTAPI_EXE')
            }
        }
        '^DirWatcher$' {
            return [PSCustomObject]@{
                ExecutableFileNames     = @('DirWatcher.exe', 'Resec.Agent.DirWatcher.exe')
                EnvironmentVariableNames = @('RESEC_DW_EXE_LOCATION', 'LAB_DIRWATCHER_EXE')
            }
        }
        default {
            return $null
        }
    }
}

function Find-ResecLabDeployExecutable {
    param(
        [Parameter(Mandatory)]
        [string[]] $SearchRoots,
        [Parameter(Mandatory)]
        [string[]] $ExecutableFileNames
    )

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($rootRaw in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($rootRaw)) {
            continue
        }

        $root = [System.IO.Path]::GetFullPath($rootRaw.Trim())
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($fileName in $ExecutableFileNames) {
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                continue
            }

            foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter $fileName -File -Recurse -ErrorAction SilentlyContinue)) {
                $null = $matches.Add($file.FullName)
            }
        }
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    return @($matches.ToArray() | Sort-Object { $_.Length } | Select-Object -First 1)[0]
}

function Update-ResecLabDeployExeLocationUserEnv {
    param(
        [Parameter(Mandatory)]
        [string] $DeployScriptId,
        [Parameter(Mandatory)]
        [string[]] $SearchRoots,
        [switch] $Quiet
    )

    $profile = Get-ResecLabDeployExeLocationProfile -DeployScriptId $DeployScriptId
    if ($null -eq $profile) {
        if (-not $Quiet) {
            Write-Host "No exe-location profile for deploy script '$DeployScriptId'; env vars unchanged."
        }
        return $false
    }

    $exePath = Find-ResecLabDeployExecutable -SearchRoots $SearchRoots -ExecutableFileNames $profile.ExecutableFileNames
    if ([string]::IsNullOrWhiteSpace($exePath)) {
        $names = ($profile.ExecutableFileNames -join ', ')
        Write-Warning "Deploy: none of ($names) found under: $(($SearchRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; ')"
        return $false
    }

    Set-ResecLabExeLocationUserEnv -ExePath $exePath -EnvironmentVariableNames $profile.EnvironmentVariableNames -Quiet:$Quiet | Out-Null
    if (-not $Quiet) {
        Write-Host "Updated lab exe env from deploy: $exePath"
    }

    return $true
}

function Get-ResecLabExePathFromEnvironment {
    param(
        [Parameter(Mandatory)]
        [string[]] $EnvironmentVariableNames
    )

    foreach ($name in $EnvironmentVariableNames) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        foreach ($scope in @('Process', 'User', 'Machine')) {
            $raw = [Environment]::GetEnvironmentVariable($name, $scope)
            if ([string]::IsNullOrWhiteSpace($raw)) {
                continue
            }

            try {
                $full = [System.IO.Path]::GetFullPath($raw.Trim())
            }
            catch {
                continue
            }

            if (Test-Path -LiteralPath $full -PathType Leaf) {
                return $full
            }
        }
    }

    return $null
}
