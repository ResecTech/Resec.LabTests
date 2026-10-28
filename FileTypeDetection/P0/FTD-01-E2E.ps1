#Requires -Version 5.1
<#
.SYNOPSIS
  P0 smoke test: detect file types on lab fixtures using the deployed FileTypeDetection build.

.DESCRIPTION
  Uses the Lab Test Runner deploy under LAB_PRODUCTION_ROOT (not the FTD git repo).
  Fixture list: Fixtures\FileTypeDetection\manifest.json

  Test Platform configuration:
    TESTPLATFORM_BASE_URL          Optional; defaults to the shared dev-test endpoint.
    TESTPLATFORM_FUNCTION_KEY      Required to report (unless TESTPLATFORM_DISABLE=1). Alias: TESTPLATFORM_CODE.
    TESTPLATFORM_COMPONENT_NAME    Optional; defaults to FileTypeDetection.
    TESTPLATFORM_DISABLE           Set to 1 to run without reporting.
    TESTPLATFORM_COMPONENT_VERSION Optional; otherwise read from deployed Resec.FileTypeDetection.dll.
    BUILD_BUILDID / GITHUB_RUN_ID  Optional build and run correlation.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FtdRunLog {
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    Write-Output $Message
}

function Get-LabTestDeployRequirements {
    Import-LabDeploySuiteDefaultsFromScriptRoot -ScriptRoot $PSScriptRoot
    return Get-FileTypeDetectionDeployRequirements
}

$testId = 'FTD-01'
$testName = 'FTD-01 - e2e'
$componentName = 'FileTypeDetection'
$defaultBaseUrl = 'https://test-results-eus2-94505680.azurewebsites.net'
$startedAtUtc = [DateTimeOffset]::UtcNow
$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
. (Join-Path $labTestsRoot 'Common\LabFixtures.ps1')
. (Join-Path $labTestsRoot 'Common\LabFtdDeploy.ps1')
. (Join-Path $labTestsRoot 'Common\LabFtdDetection.ps1')

function Initialize-FtdTestPlatformFromLabConfig {
    if ($env:TESTPLATFORM_DISABLE -eq '1') {
        return
    }

    if ([string]::IsNullOrWhiteSpace($env:TESTPLATFORM_FUNCTION_KEY) -and
        [string]::IsNullOrWhiteSpace($env:TESTPLATFORM_CODE)) {
        $fromLab = Get-LabOptionalString -SettingName 'testPlatformFunctionKey' -EnvironmentVariable 'TESTPLATFORM_FUNCTION_KEY'
        if (-not [string]::IsNullOrWhiteSpace($fromLab)) {
            $env:TESTPLATFORM_FUNCTION_KEY = $fromLab
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:TESTPLATFORM_BASE_URL)) {
        $fromLabUrl = Get-LabOptionalString -SettingName 'testPlatformBaseUrl' -EnvironmentVariable 'TESTPLATFORM_BASE_URL'
        if (-not [string]::IsNullOrWhiteSpace($fromLabUrl)) {
            $env:TESTPLATFORM_BASE_URL = $fromLabUrl
        }
    }
}

function Get-TestPlatformConfig {
    Initialize-FtdTestPlatformFromLabConfig

    if ($env:TESTPLATFORM_DISABLE -eq '1') {
        return $null
    }

    $baseUrl = $env:TESTPLATFORM_BASE_URL
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $defaultBaseUrl
    }

    $functionKey = $env:TESTPLATFORM_FUNCTION_KEY
    if ([string]::IsNullOrWhiteSpace($functionKey)) {
        $functionKey = $env:TESTPLATFORM_CODE
    }
    if ([string]::IsNullOrWhiteSpace($functionKey)) {
        Write-FtdRunLog '[TestPlatform] Cloud reporting skipped (function key not configured).'
        return $null
    }

    $configuredComponentName = $env:TESTPLATFORM_COMPONENT_NAME
    if (-not [string]::IsNullOrWhiteSpace($configuredComponentName)) {
        $script:componentName = $configuredComponentName.Trim()
    }

    $buildId = $env:BUILD_BUILDID
    if ([string]::IsNullOrWhiteSpace($buildId)) {
        $buildId = $env:GITHUB_RUN_ID
    }

    return @{
        BaseUrl     = $baseUrl.TrimEnd('/')
        FunctionKey = $functionKey.Trim()
        BuildId     = if ([string]::IsNullOrWhiteSpace($buildId)) { $null } else { $buildId.Trim() }
    }
}

function Get-DeployedComponentVersion {
    param(
        [Parameter(Mandatory)]
        [string] $DeployFolder
    )

    if (-not [string]::IsNullOrWhiteSpace($env:TESTPLATFORM_COMPONENT_VERSION)) {
        return $env:TESTPLATFORM_COMPONENT_VERSION.Trim()
    }

    $assemblyPath = Get-LabDeployedFileTypeDetectionAssemblyPath -DeployFolder $DeployFolder
    $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($assemblyPath).FileVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    return $version.Trim()
}

function Send-TestPlatformResult {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Config,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [string] $Message,
        [string] $RunLog,
        [string] $ComponentVersion
    )

    $body = [ordered]@{
        machineName   = $env:COMPUTERNAME
        componentName = $componentName
        testName      = $testName
        outcome       = if ($Passed) { 'Passed' } else { 'Failed' }
        startedAtUtc  = $startedAtUtc.ToString('o')
        finishedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $body.message = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($RunLog)) {
        $body.runLog = $RunLog
    }
    if (-not [string]::IsNullOrWhiteSpace($ComponentVersion)) {
        $body.componentVersion = $ComponentVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.BuildId)) {
        $body.buildId = $Config.BuildId
        $body.runId = "$($Config.BuildId):$testId"
    }

    $json = $body | ConvertTo-Json -Depth 6 -Compress
    $uri = '{0}/api/results' -f $Config.BaseUrl
    $headers = @{
        'x-functions-key' = (Get-NormalizedTestPlatformFunctionKey -Raw $Config.FunctionKey)
    }
    $versionSuffix = if (-not [string]::IsNullOrWhiteSpace($ComponentVersion)) { " version=$ComponentVersion" } else { '' }
    Write-FtdRunLog "[TestPlatform] Reporting to cloud ($($Config.BaseUrl)) outcome=$($body.outcome) test=$testName$versionSuffix"
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $json -ContentType 'application/json; charset=utf-8'
    $resultId = $response.id
    Write-FtdRunLog "[TestPlatform] Reported to cloud: result id=$resultId outcome=$($body.outcome) test=$testName$versionSuffix"
}

function Get-NormalizedTestPlatformFunctionKey {
    param([string] $Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ''
    }

    $key = $Raw.Trim()
    if ($key -match '[?&]code=([^&]+)') {
        return [Uri]::UnescapeDataString($matches[1])
    }

    if ($key.StartsWith('code=', [StringComparison]::OrdinalIgnoreCase)) {
        return $key.Substring(5).Trim()
    }

    return $key
}

function Get-FtdLabCases {
    $fixturesRoot = Get-LabFileTypeDetectionFixturesRoot
    $manifestPath = Join-Path $fixturesRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing FTD lab manifest: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $manifest.cases -or @($manifest.cases).Count -eq 0) {
        throw "FTD lab manifest has no cases: $manifestPath"
    }

    return @($manifest.cases)
}

$runLogBuilder = New-Object System.Text.StringBuilder
function Add-FtdRunLogLine {
    param([string] $Line)
    [void]$runLogBuilder.AppendLine($Line)
    Write-FtdRunLog $Line
}

$passed = $false
$failureMessage = $null
$deployFolder = $null
$componentVersion = $null

try {
    $deployInfo = Get-LabDeployedProductDeployFolder -DeployScriptId 'FileTypeDetection'
    $deployFolder = $deployInfo.DeployFolder
    $componentVersion = Get-DeployedComponentVersion -DeployFolder $deployFolder

    Add-FtdRunLogLine "Deployed FileTypeDetection: $($deployInfo.Label)"
    Add-FtdRunLogLine "Deploy folder: $deployFolder"
    if ([string]::IsNullOrWhiteSpace($componentVersion)) {
        Add-FtdRunLogLine 'FileTypeDetection version: (not found on deployed assembly)'
    }
    else {
        Add-FtdRunLogLine "FileTypeDetection version: $componentVersion"
    }

    $fixturesRoot = Get-LabFileTypeDetectionFixturesRoot
    Add-FtdRunLogLine "Fixtures root: $fixturesRoot"

    $failures = New-Object System.Collections.Generic.List[string]
    $caseIndex = 0
    foreach ($case in Get-FtdLabCases) {
        $caseIndex++
        $relativePath = [string]$case.relativePath
        $expected = [string]$case.expectedExtensionContains
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [string]::IsNullOrWhiteSpace($expected)) {
            $failures.Add("Case ${caseIndex}: manifest entry is missing relativePath or expectedExtensionContains.")
            continue
        }

        $fixturePath = Join-Path $fixturesRoot $relativePath
        Add-FtdRunLogLine "[$caseIndex] Detecting: $relativePath"

        $detection = Invoke-LabDeployedFileTypeDetection -DeployFolder $deployFolder -FilePath $fixturePath
        $matched = $false
        if ($detection.Mode -eq 'console') {
            Add-FtdRunLogLine "[$caseIndex] Result: $($detection.RawOutput)"
            $matched = Test-LabFtdConsoleOutputMatchesExtension -ConsoleOutput $detection.RawOutput -ExpectedExtensionContains $expected
        }
        else {
            Add-FtdRunLogLine "[$caseIndex] Result extensions: $($detection.RawOutput)"
            $matched = Test-LabFtdDetectedExtensionMatches -FileTypeInfo $detection.FileTypeInfo -ExpectedExtensionContains $expected
        }

        if (-not $matched) {
            $failures.Add("Case ${caseIndex} ($relativePath): expected extension containing '$expected'; got '$($detection.RawOutput)'.")
        }
    }

    if ($failures.Count -gt 0) {
        $failureMessage = ($failures -join [Environment]::NewLine)
        throw "FTD detection failed on $($failures.Count) case(s)."
    }

    $passed = $true
    Add-FtdRunLogLine 'FTD P0 e2e passed.'
}
catch {
    if ($null -eq $failureMessage) {
        $failureMessage = $_.Exception.Message
    }

    Add-FtdRunLogLine "FTD P0 e2e failed. $failureMessage"
}
finally {
    $runLog = $runLogBuilder.ToString()
    if ($env:TESTPLATFORM_DISABLE -eq '1') {
        Write-FtdRunLog '[TestPlatform] Cloud reporting disabled (TESTPLATFORM_DISABLE=1).'
    }
    else {
        $config = Get-TestPlatformConfig
        if ($config) {
            try {
                if ($null -eq $componentVersion -and $null -ne $deployFolder) {
                    $componentVersion = Get-DeployedComponentVersion -DeployFolder $deployFolder
                }

                Send-TestPlatformResult -Config $config -Passed:$passed -Message $failureMessage `
                    -RunLog $runLog -ComponentVersion $componentVersion
            }
            catch {
                $hint = if ($_.Exception.Message -match '401') {
                    ' Check the Test Platform function key in Lab Test Runner Setup (or optional.testPlatformFunctionKey in lab.local.json), or set TESTPLATFORM_DISABLE=1 to skip reporting.'
                }
                else {
                    ''
                }

                Write-FtdRunLog "[TestPlatform] Cloud reporting failed: $($_.Exception.Message).$hint"
            }
        }
    }
}

if ($passed) {
    exit 0
}

exit 1
