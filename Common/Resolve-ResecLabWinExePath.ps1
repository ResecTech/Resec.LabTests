#Requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-ResecLabWinExePath {
    param(
        [Parameter(Mandatory)]
        [string] $CandidatePath
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $null
    }

    $full = $null
    try {
        $full = [System.IO.Path]::GetFullPath($CandidatePath.Trim())
    }
    catch {
        return $null
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return $null
    }

    $ext = [System.IO.Path]::GetExtension($full)
    if ($ext.Equals('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }

    if ($ext.Equals('.dll', [StringComparison]::OrdinalIgnoreCase)) {
        $dir = [System.IO.Path]::GetDirectoryName($full)
        $exePath = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($full) + '.exe')
        if (Test-Path -LiteralPath $exePath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($exePath)
        }
    }

    return $null
}