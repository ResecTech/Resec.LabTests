#Requires -Version 5.1
Set-StrictMode -Version Latest

function Set-ResecLabExeLocationUserEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ExePath,

        [Parameter(Mandatory)]
        [string[]] $EnvironmentVariableNames,

        [switch] $Quiet
    )

    $full = [System.IO.Path]::GetFullPath($ExePath.Trim())
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Executable not found: $full"
    }

    $names = @(
        $EnvironmentVariableNames |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($names.Count -eq 0) {
        throw 'At least one environment variable name is required.'
    }

    $markerPayload = [ordered]@{ }
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $full, 'User')
        Set-Item -Path "Env:$name" -Value $full -ErrorAction SilentlyContinue
        $markerPayload[$name] = $full
        if (-not $Quiet) {
            Write-Host "Set user env ${name}=$full"
        }
    }

    Write-Output ("RESEC_LAB_DEPLOY_EXE_ENV=" + ($markerPayload | ConvertTo-Json -Compress))
}
