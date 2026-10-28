#Requires -Version 5.1
Set-StrictMode -Version Latest

function Find-LabFtdConsoleHost {
    param(
        [Parameter(Mandatory)]
        [string] $DeployFolder
    )

    foreach ($name in @(
            'FileDetectionExe.exe',
            'FileDetection.exe',
            'FileDetectionExe.dll',
            'FileDetection.dll')) {
        $hits = @(Get-ChildItem -LiteralPath $DeployFolder -Recurse -Filter $name -File -ErrorAction SilentlyContinue)
        if ($hits.Count -eq 0) {
            continue
        }

        return ($hits | Sort-Object { $_.FullName.Length }, FullName | Select-Object -First 1).FullName
    }

    return $null
}

function Invoke-LabFtdConsoleDetection {
    param(
        [Parameter(Mandatory)]
        [string] $ConsoleHostPath,
        [Parameter(Mandatory)]
        [string] $FilePath
    )

    $workingDirectory = [System.IO.Path]::GetDirectoryName($ConsoleHostPath)
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
        throw "Invalid console host path: $ConsoleHostPath"
    }

    Push-Location $workingDirectory
    try {
        if ($ConsoleHostPath.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
            $output = (& $ConsoleHostPath -d $FilePath 2>&1 | Out-String).Trim()
        }
        else {
            $output = (& dotnet $ConsoleHostPath -d $FilePath 2>&1 | Out-String).Trim()
        }
    }
    finally {
        Pop-Location
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        throw "FileDetection console host returned no output for '$FilePath'."
    }

    return $output
}

function Initialize-LabFtdReflectionEngine {
    param(
        [Parameter(Mandatory)]
        [string] $AssemblyPath
    )

    $assemblyDirectory = [System.IO.Path]::GetDirectoryName($AssemblyPath)
    if ([string]::IsNullOrWhiteSpace($assemblyDirectory)) {
        throw "Invalid assembly path: $AssemblyPath"
    }

    $handler = {
        param($sender, $eventArgs)

        $simpleName = ($eventArgs.Name -split ',')[0]
        $candidate = Join-Path $script:LabFtdAssemblyDirectory "$simpleName.dll"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.Reflection.Assembly]::LoadFrom($candidate)
        }

        return $null
    }

    $script:LabFtdAssemblyDirectory = $assemblyDirectory
    $script:LabFtdAssemblyResolveHandler = $handler
    [AppDomain]::CurrentDomain.add_AssemblyResolve($script:LabFtdAssemblyResolveHandler) | Out-Null

    $assembly = [System.Reflection.Assembly]::LoadFrom($AssemblyPath)
    $ruleContainerType = $assembly.GetType('Resec.FileTypeDetection.FileDetection.RuleContainer', $false)
    if ($null -eq $ruleContainerType) {
        throw 'RuleContainer type not found in deployed Resec.FileTypeDetection assembly.'
    }

    $ruleContainer = [Activator]::CreateInstance($ruleContainerType, @($null, $null, $null))
    $globalOpenType = $assembly.GetType('Resec.FileTypeDetection.Util.Global`1', $false)
    if ($null -eq $globalOpenType) {
        throw 'Global<> type not found in deployed Resec.FileTypeDetection assembly.'
    }

    $globalClosed = $globalOpenType.MakeGenericType(@($ruleContainerType))
    $instanceProperty = $globalClosed.GetProperty('Instance', [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static)
    if ($null -eq $instanceProperty) {
        throw 'Global<RuleContainer>.Instance property not found.'
    }

    $instanceProperty.SetValue($null, $ruleContainer, $null)
    return $assembly
}

function Invoke-LabFtdDetectFileReflection {
    param(
        [Parameter(Mandatory)]
        [System.Reflection.Assembly] $Assembly,
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [string] $OriginalName
    )

    $managerType = $Assembly.GetType('Resec.FileTypeDetection.FileDetection.FileDetectionManager', $false)
    if ($null -eq $managerType) {
        throw 'FileDetectionManager type not found.'
    }

    $method = $managerType.GetMethod(
        'FileTypeDetectorGetFileType',
        [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static,
        $null,
        @([string], [string], [bool]),
        $null)
    if ($null -eq $method) {
        throw 'FileTypeDetectorGetFileType method not found.'
    }

    return $method.Invoke($null, @($FilePath, $OriginalName, $true))
}

function Get-LabFtdDetectedExtensionSummary {
    param(
        [Parameter(Mandatory)]
        $FileTypeInfo
    )

    if ($null -eq $FileTypeInfo) {
        return '<null>'
    }

    $extensionsProperty = $FileTypeInfo.GetType().GetProperty('ClassificationExtensions')
    if ($null -eq $extensionsProperty) {
        return [string]$FileTypeInfo
    }

    $value = [string]$extensionsProperty.GetValue($FileTypeInfo, $null)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return '<empty>'
    }

    return $value.Trim()
}

function Test-LabFtdDetectedExtensionMatches {
    param(
        [Parameter(Mandatory)]
        $FileTypeInfo,
        [Parameter(Mandatory)]
        [string] $ExpectedExtensionContains
    )

    $extensions = Get-LabFtdDetectedExtensionSummary -FileTypeInfo $FileTypeInfo
    return $extensions.IndexOf($ExpectedExtensionContains.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Invoke-LabDeployedFileTypeDetection {
    <#
    .SYNOPSIS
      Detect file type using the deployed FileTypeDetection build (console host or in-process load).
    #>
    param(
        [Parameter(Mandatory)]
        [string] $DeployFolder,
        [Parameter(Mandatory)]
        [string] $FilePath,
        [string] $OriginalName
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Fixture file not found: $FilePath"
    }

    $fullPath = [System.IO.Path]::GetFullPath($FilePath)
    if ([string]::IsNullOrWhiteSpace($OriginalName)) {
        $OriginalName = [System.IO.Path]::GetFileName($fullPath)
    }

    $assemblyPath = Get-LabDeployedFileTypeDetectionAssemblyPath -DeployFolder $DeployFolder
    $workingDirectory = [System.IO.Path]::GetDirectoryName($assemblyPath)
    $consoleHost = Find-LabFtdConsoleHost -DeployFolder $DeployFolder

    if (-not [string]::IsNullOrWhiteSpace($consoleHost)) {
        $output = Invoke-LabFtdConsoleDetection -ConsoleHostPath $consoleHost -FilePath $fullPath

        return [PSCustomObject]@{
            Mode = 'console'
            RawOutput = $output
            FileTypeInfo = $null
        }
    }

    Push-Location $workingDirectory
    try {
        $assembly = Initialize-LabFtdReflectionEngine -AssemblyPath $assemblyPath
        $info = Invoke-LabFtdDetectFileReflection -Assembly $assembly -FilePath $fullPath -OriginalName $OriginalName
    }
    finally {
        Pop-Location
    }

    return [PSCustomObject]@{
        Mode = 'reflection'
        RawOutput = (Get-LabFtdDetectedExtensionSummary -FileTypeInfo $info)
        FileTypeInfo = $info
    }
}

function Test-LabFtdConsoleOutputMatchesExtension {
    param(
        [Parameter(Mandatory)]
        [string] $ConsoleOutput,
        [Parameter(Mandatory)]
        [string] $ExpectedExtensionContains
    )

    return $ConsoleOutput.IndexOf($ExpectedExtensionContains.Trim(), [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}
