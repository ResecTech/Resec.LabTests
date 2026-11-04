#Requires -Version 5.1
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'LabDeployExeLocation.ps1')

function Get-CoreE2eCoreExePathFromEnvironment {
    return Get-ResecLabExePathFromEnvironment -EnvironmentVariableNames @(
        'RESEC_CORE_EXE_LOCATION',
        'LAB_CORE_EXE'
    )
}

function Get-CoreE2eCoreRepoRootFromEnvironment {
    $exe = Get-CoreE2eCoreExePathFromEnvironment
    if ([string]::IsNullOrWhiteSpace($exe)) {
        return $null
    }

    $dir = [System.IO.Path]::GetDirectoryName($exe)
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return $null
    }

    return $dir
}

function Resolve-CoreE2eEmbedded7ZipPath {
    param(
        [string] $CoreRepoRootOverride = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_7Z_EXE)) {
        $full = [System.IO.Path]::GetFullPath($env:CORE_E2E_7Z_EXE.Trim())
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($CoreRepoRootOverride)) {
        $null = $roots.Add([System.IO.Path]::GetFullPath($CoreRepoRootOverride))
    }

    if (Get-Command Get-LabProductRepoRoot -ErrorAction SilentlyContinue) {
        try {
            $null = $roots.Add([System.IO.Path]::GetFullPath((Get-LabProductRepoRoot -Product Core)))
        }
        catch {
            # Optional when LabConfig is not loaded.
        }
    }

    $fromEnv = Get-CoreE2eCoreRepoRootFromEnvironment
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        $null = $roots.Add($fromEnv)
    }

    foreach ($root in @($roots.ToArray() | Select-Object -Unique)) {
        foreach ($relative in @(
                'EmbeddedWindows\7z.exe',
                'src\Resec.Core.Server\bin\26.2\Debug\EmbeddedWindows\7z.exe',
                'src\Resec.Core.Server\bin\26.1\Debug\EmbeddedWindows\7z.exe'
            )) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }

        $fromBuildOutput = Join-Path $root 'EmbeddedWindows\7z.exe'
        if (Test-Path -LiteralPath $fromBuildOutput -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($fromBuildOutput)
        }
    }

    return $null
}
