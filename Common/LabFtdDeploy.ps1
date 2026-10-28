#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-LabProductionDownloadRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LAB_PRODUCTION_ROOT)) {
        $full = [System.IO.Path]::GetFullPath($env:LAB_PRODUCTION_ROOT.Trim())
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            throw "LAB_PRODUCTION_ROOT not found: $full"
        }

        return $full
    }

    throw 'LAB_PRODUCTION_ROOT is not set. Configure Production download root in Lab Test Runner Setup.'
}

function Test-LabDeployFolderNameMatchesScript {
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string] $DeployScriptId
    )

    $tokens = @($DeployScriptId.Trim())
    if ($DeployScriptId -eq 'FileTypeDetection') {
        $tokens += 'FTD'
    }

    foreach ($token in $tokens) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        for ($index = 0; $index -le $FolderName.Length - $token.Length; $index++) {
            if (-not $FolderName.Substring($index, $token.Length).Equals($token, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $beforeOk = ($index -eq 0) -or ($FolderName[$index - 1] -eq '.' -or $FolderName[$index - 1] -eq '-')
            $afterIndex = $index + $token.Length
            $afterOk = ($afterIndex -ge $FolderName.Length) -or ($FolderName[$afterIndex] -eq '-' -or $FolderName[$afterIndex] -eq '.')
            if ($beforeOk -and $afterOk) {
                return $true
            }
        }
    }

    return $false
}

function Test-LabLocalDownloadFolderHasDeployPayload {
    param(
        [Parameter(Mandatory)] [string] $BuildFolder
    )

    $deployDir = Join-Path $BuildFolder 'Deploy'
    $statePath = Join-Path $deployDir '.lab-deploy.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $deployDir -PathType Container)) {
        return $false
    }

    $payloadFiles = @(Get-ChildItem -LiteralPath $deployDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.lab-deploy.json' })
    return $payloadFiles.Count -gt 0
}

function Get-LabDeployedProductDeployFolder {
    param(
        [Parameter(Mandatory)]
        [string] $DeployScriptId
    )

    $productionRoot = Get-LabProductionDownloadRoot
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($dir in Get-ChildItem -LiteralPath $productionRoot -Directory -ErrorAction Stop) {
        if (-not (Test-LabDeployFolderNameMatchesScript -FolderName $dir.Name -DeployScriptId $DeployScriptId)) {
            continue
        }

        if (-not (Test-LabLocalDownloadFolderHasDeployPayload -BuildFolder $dir.FullName)) {
            continue
        }

        $candidates.Add([PSCustomObject]@{
            BuildFolder = $dir.FullName
            DeployFolder = (Join-Path $dir.FullName 'Deploy')
            LastWriteUtc = $dir.LastWriteTimeUtc
            FolderName = $dir.Name
        })
    }

    if ($candidates.Count -eq 0) {
        throw "No deployed '$DeployScriptId' build under '$productionRoot'. Download from Product catalog, then Deploy."
    }

    $chosen = @($candidates | Sort-Object -Property LastWriteUtc -Descending)[0]
    return [PSCustomObject]@{
        DeployFolder = $chosen.DeployFolder
        BuildFolder = $chosen.BuildFolder
        Label = $chosen.FolderName
    }
}

function Get-LabDeployedFileTypeDetectionDeployFolder {
    $resolved = Get-LabDeployedProductDeployFolder -DeployScriptId 'FileTypeDetection'
    return $resolved.DeployFolder
}

function Get-LabDeployedFileTypeDetectionAssemblyPath {
    param(
        [Parameter(Mandatory)]
        [string] $DeployFolder
    )

    $hits = @(Get-ChildItem -LiteralPath $DeployFolder -Recurse -Filter 'Resec.FileTypeDetection.dll' -File -ErrorAction Stop)
    if ($hits.Count -eq 0) {
        throw "Resec.FileTypeDetection.dll not found under deployed folder: $DeployFolder"
    }

    if ($hits.Count -gt 1) {
        $hits = @($hits | Sort-Object { $_.FullName.Length } | Select-Object -First 1)
    }

    return $hits[0].FullName
}
