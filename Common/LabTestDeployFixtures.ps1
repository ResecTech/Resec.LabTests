#Requires -Version 5.1
<#
  Helpers for lab deploy fixture checks (deploy script id, production root, process running).
  Dot-source from Check-LabTestDeployFixtures.ps1 and deploy scripts.
#>
Set-StrictMode -Version Latest

function Get-LabDeployScriptProcessName {
    param(
        [Parameter(Mandatory)]
        [string] $ComponentName
    )

    switch ($ComponentName.Trim()) {
        'ScanAgent' { return 'Resec.Agent.ScanAgent' }
        'Mail' { return 'Resec.Agent.Mail' }
        'Core' { return 'Resec.Core.Server' }
        'FileTypeDetection' { return 'Resec.FileTypeDetection' }
        default { return $null }
    }
}

function Test-LabDeployComponentProcessRunning {
    param(
        [Parameter(Mandatory)]
        [string] $ComponentName
    )

    $processName = Get-LabDeployScriptProcessName -ComponentName $ComponentName
    if ([string]::IsNullOrWhiteSpace($processName)) {
        return $false
    }

    return @(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-LabDeployFolderMatchTokens {
    param(
        [Parameter(Mandatory)]
        [string] $DeployScriptId
    )

    $id = $DeployScriptId.Trim()
    $tokens = New-Object System.Collections.Generic.List[string]
    $null = $tokens.Add($id)
    if ([string]::Equals($id, 'ScanAgent', [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $tokens.Add('Agent.ScanAgent')
    }
    elseif ([string]::Equals($id, 'Mail', [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $tokens.Add('Agent.Mail')
    }
    elseif ([string]::Equals($id, 'FileTypeDetection', [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = $tokens.Add('FTD')
    }

    return @($tokens.ToArray())
}

function Test-LabDeployFolderNameMatchesToken {
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string] $Token
    )

    if ([string]::IsNullOrWhiteSpace($FolderName) -or [string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }

    for ($i = 0; $i -le ($FolderName.Length - $Token.Length); $i++) {
        if (-not $FolderName.Substring($i, $Token.Length).Equals($Token, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $beforeOk = ($i -eq 0) -or ($FolderName[$i - 1] -eq '.' -or $FolderName[$i - 1] -eq '-')
        $afterIndex = $i + $Token.Length
        $afterOk = ($afterIndex -ge $FolderName.Length) -or ($FolderName[$afterIndex] -eq '-' -or $FolderName[$afterIndex] -eq '.')
        if ($beforeOk -and $afterOk) {
            return $true
        }
    }

    return $false
}

function Test-LabDeployFolderMatchesScript {
    param(
        [Parameter(Mandatory)] [string] $FolderName,
        [Parameter(Mandatory)] [string] $DeployScriptId
    )

    foreach ($token in Get-LabDeployFolderMatchTokens -DeployScriptId $DeployScriptId) {
        if (Test-LabDeployFolderNameMatchesToken -FolderName $FolderName -Token $token) {
            return $true
        }
    }

    return $false
}

function ConvertFrom-LabDeployLocalDownloadFolderName {
    param(
        [Parameter(Mandatory)]
        [string] $FolderName
    )

    $parts = @($FolderName.Split('-'))
    if ($parts.Count -lt 3) {
        return $null
    }

    $versionName = $parts[$parts.Count - 1]
    $branchName = $parts[$parts.Count - 2]
    $productName = ($parts[0..($parts.Count - 3)] -join '-')
    if ([string]::IsNullOrWhiteSpace($productName) -or
        [string]::IsNullOrWhiteSpace($branchName) -or
        [string]::IsNullOrWhiteSpace($versionName)) {
        return $null
    }

    return [PSCustomObject]@{
        FolderPath  = $null
        ProductName = $productName
        BranchName  = $branchName
        VersionName = $versionName
    }
}

function Get-LabDeployLocalBuilds {
    param(
        [Parameter(Mandatory)]
        [string] $ProductionDownloadRoot,
        [Parameter(Mandatory)]
        [string] $DeployScriptId
    )

    $root = [System.IO.Path]::GetFullPath($ProductionDownloadRoot.Trim())
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
        $name = $dir.Name
        if (-not (Test-LabDeployFolderMatchesScript -FolderName $name -DeployScriptId $DeployScriptId)) {
            continue
        }

        if (-not @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count) {
            continue
        }

        $parsed = ConvertFrom-LabDeployLocalDownloadFolderName -FolderName $name
        if ($null -eq $parsed) {
            continue
        }

        $parsed | Add-Member -NotePropertyName FolderPath -NotePropertyValue $dir.FullName -Force
        $parsed | Add-Member -NotePropertyName LastWriteUtc -NotePropertyValue $dir.LastWriteTimeUtc -Force
        $null = $results.Add($parsed)
    }

    return @(
        $results.ToArray() |
            Sort-Object -Property @{ Expression = { $_.VersionName }; Descending = $true }, LastWriteUtc -Descending
    )
}

function Get-LabDeployTargetFolder {
    param(
        [Parameter(Mandatory)]
        [string] $BuildFolderPath
    )

    Join-Path ([System.IO.Path]::GetFullPath($BuildFolderPath)) 'Deploy'
}

function Test-LabDeployRequirementFixtureSatisfied {
    param(
        [Parameter(Mandatory)]
        [string] $ProductionDownloadRoot,
        [Parameter(Mandatory)]
        [string] $DeployScriptId,
        [bool] $RequiresRunning
    )

    $builds = Get-LabDeployLocalBuilds -ProductionDownloadRoot $ProductionDownloadRoot -DeployScriptId $DeployScriptId
    foreach ($build in $builds) {
        $targetFolder = Get-LabDeployTargetFolder -BuildFolderPath $build.FolderPath
        if (Test-LabDeployIsBuildDeployed -TargetFolder $targetFolder -DeployScriptId $DeployScriptId -ProductName $build.ProductName -BranchName $build.BranchName -VersionName $build.VersionName) {
            $running = Test-LabDeployComponentProcessRunning -ComponentName $DeployScriptId
            if ($RequiresRunning -and -not $running) {
                return [PSCustomObject]@{
                    Satisfied   = $false
                    Build       = $build
                    Deployed    = $true
                    Running     = $false
                }
            }

            return [PSCustomObject]@{
                Satisfied = $true
                Build     = $build
                Deployed  = $true
                Running   = $running
            }
        }
    }

    $running = Test-LabDeployComponentProcessRunning -ComponentName $DeployScriptId
    return [PSCustomObject]@{
        Satisfied = $false
        Build     = $null
        Deployed  = $false
        Running   = $running
    }
}

function New-LabDeployRequirementFixtureDto {
    param(
        [Parameter(Mandatory)]
        [string] $ComponentName,
        [Parameter(Mandatory)]
        [bool] $RequiresRunning,
        [Parameter(Mandatory)]
        [bool] $Deployed,
        [Parameter(Mandatory)]
        [bool] $Running
    )

    return [ordered]@{
        componentName   = $ComponentName.Trim()
        requiresRunning = $RequiresRunning
        state           = [ordered]@{
            deployed = $Deployed
            running  = $Running
        }
    }
}

function Write-LabDeployRequirementFixtureJson {
    param(
        [Parameter(Mandatory)]
        [string] $ComponentName,
        [Parameter(Mandatory)]
        [bool] $Deployed,
        [bool] $RequiresRunning = $false
    )

    $running = Test-LabDeployComponentProcessRunning -ComponentName $ComponentName
    $dto = New-LabDeployRequirementFixtureDto -ComponentName $ComponentName -RequiresRunning $RequiresRunning -Deployed $Deployed -Running $running
    Write-Output ($dto | ConvertTo-Json -Compress -Depth 5)
}
