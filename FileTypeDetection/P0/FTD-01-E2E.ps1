#Requires -Version 5.1
<#
.SYNOPSIS
  Runs the complete FileTypeDetection unit-test suite and reports one aggregate P0 result.

.DESCRIPTION
  The test runner deliberately does not use fail-fast. It parses the generated TRX and includes
  every failed unit test in the Test Platform result message and run log.

  Test Platform configuration:
    TESTPLATFORM_BASE_URL          Optional; defaults to the shared dev-test endpoint.
    TESTPLATFORM_FUNCTION_KEY      Required to report (unless TESTPLATFORM_DISABLE=1). Alias: TESTPLATFORM_CODE.
    TESTPLATFORM_COMPONENT_NAME    Optional; defaults to FileTypeDetection.
    TESTPLATFORM_DISABLE           Set to 1 to run without reporting.
    TESTPLATFORM_COMPONENT_VERSION Optional; otherwise read from the built FTD assembly.
    BUILD_BUILDID / GITHUB_RUN_ID  Optional build and run correlation.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testId = 'FTD-01'
$testName = 'FTD-01 - e2e'
$componentName = 'FileTypeDetection'
$defaultBaseUrl = 'https://test-results-eus2-94505680.azurewebsites.net'
$startedAtUtc = [DateTimeOffset]::UtcNow
$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\'))
. (Join-Path $labTestsRoot 'Common\LabConfig.ps1')
$repositoryRoot = Get-LabFileTypeDetectionProductRoot
$testProject = Join-Path $repositoryRoot 'src\FileTypeDetection\Resec.FileTypeDetection.Tests\Resec.FileTypeDetection.Tests.csproj'
$resultsDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "FTD-E2E-$([Guid]::NewGuid().ToString('N'))"
$trxFileName = "$testId.trx"
$trxPath = Join-Path $resultsDirectory $trxFileName
$consoleLogPath = Join-Path $resultsDirectory "$testId.log"

function Get-TestPlatformConfig {
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
        Write-Warning 'Test Platform function key is missing; skipping report.'
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

function Get-ComponentVersion {
    if (-not [string]::IsNullOrWhiteSpace($env:TESTPLATFORM_COMPONENT_VERSION)) {
        return $env:TESTPLATFORM_COMPONENT_VERSION.Trim()
    }

    $assemblyPath = Join-Path $repositoryRoot "src\FileTypeDetection\FileTypeDetection\bin\$Configuration\net10.0\Resec.FileTypeDetection.dll"
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        return $null
    }

    $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($assemblyPath).FileVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    return $version.Trim()
}

function Get-TrxResults {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    [xml] $trx = [System.IO.File]::ReadAllText($Path)
    $resultNodes = @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $failedNodes = @($resultNodes | Where-Object { $_.outcome -eq 'Failed' })
    $failureDetails = New-Object System.Collections.Generic.List[string]

    foreach ($failure in $failedNodes) {
        $name = [string] $failure.testName
        $messageNode = $failure.SelectSingleNode("./*[local-name()='Output']/*[local-name()='ErrorInfo']/*[local-name()='Message']")
        $stackNode = $failure.SelectSingleNode("./*[local-name()='Output']/*[local-name()='ErrorInfo']/*[local-name()='StackTrace']")
        $message = if ($null -eq $messageNode -or [string]::IsNullOrWhiteSpace($messageNode.InnerText)) {
            'No failure message was recorded.'
        }
        else {
            $messageNode.InnerText.Trim()
        }

        $detail = "$name$([Environment]::NewLine)$message"
        if ($null -ne $stackNode -and -not [string]::IsNullOrWhiteSpace($stackNode.InnerText)) {
            $detail += "$([Environment]::NewLine)$($stackNode.InnerText.Trim())"
        }
        $failureDetails.Add($detail)
    }

    return [pscustomobject]@{
        Total          = $resultNodes.Count
        Passed         = @($resultNodes | Where-Object { $_.outcome -eq 'Passed' }).Count
        Failed         = $failedNodes.Count
        Skipped        = @($resultNodes | Where-Object { $_.outcome -eq 'NotExecuted' }).Count
        FailureDetails = @($failureDetails)
    }
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

    $uri = '{0}/api/results?code={1}' -f $Config.BaseUrl, [Uri]::EscapeDataString($Config.FunctionKey)
    $json = $body | ConvertTo-Json -Depth 6 -Compress
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType 'application/json; charset=utf-8'
    Write-Host "[TestPlatform] Reported result id=$($response.id) outcome=$($body.outcome) test=$testName"
}

New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

$dotnetExitCode = 1
$result = $null
$failureMessage = $null
$runLog = $null

try {
    Write-Host "Running complete FTD unit-test suite: $testProject"
    & dotnet test --project $testProject --configuration $Configuration --results-directory $resultsDirectory `
        --minimum-expected-tests 1 --no-ansi --no-progress --stop-on-fail off `
        --report-xunit-trx --report-xunit-trx-filename $trxFileName 2>&1 |
        Tee-Object -FilePath $consoleLogPath
    $dotnetExitCode = $LASTEXITCODE

    if (Test-Path -LiteralPath $trxPath -PathType Leaf) {
        $result = Get-TrxResults -Path $trxPath
        $summary = "Total: $($result.Total), Passed: $($result.Passed), Failed: $($result.Failed), Skipped: $($result.Skipped)"
        Write-Host $summary

        if ($result.Failed -gt 0) {
            $numberedFailures = for ($index = 0; $index -lt $result.FailureDetails.Count; $index++) {
                "[$($index + 1)/$($result.FailureDetails.Count)] $($result.FailureDetails[$index])"
            }
            $failureMessage = "$summary$([Environment]::NewLine)$([Environment]::NewLine)" + ($numberedFailures -join "$([Environment]::NewLine)$([Environment]::NewLine)")
        }
        elseif ($dotnetExitCode -ne 0) {
            $failureMessage = "$summary$([Environment]::NewLine)dotnet test exited with code $dotnetExitCode without recording a failed test."
        }
        elseif ($result.Total -eq 0) {
            $failureMessage = 'dotnet test completed without executing any tests.'
            $dotnetExitCode = 1
        }
    }
    else {
        $failureMessage = "dotnet test exited with code $dotnetExitCode and did not produce the expected TRX file '$trxPath'."
        $dotnetExitCode = 1
    }
}
catch {
    $failureMessage = "FTD unit-test execution failed: $($_.Exception.Message)"
    $dotnetExitCode = 1
}
finally {
    if (Test-Path -LiteralPath $consoleLogPath -PathType Leaf) {
        $runLog = [System.IO.File]::ReadAllText($consoleLogPath)
    }
    if ($result -and $result.FailureDetails.Count -gt 0) {
        $runLog += "$([Environment]::NewLine)$([Environment]::NewLine)All failed tests:$([Environment]::NewLine)$([Environment]::NewLine)"
        $runLog += ($result.FailureDetails -join "$([Environment]::NewLine)$([Environment]::NewLine)")
    }

    $passed = $dotnetExitCode -eq 0 -and $result -and $result.Failed -eq 0 -and $result.Total -gt 0
    $config = Get-TestPlatformConfig
    if ($config) {
        try {
            Send-TestPlatformResult -Config $config -Passed:$passed -Message $failureMessage `
                -RunLog $runLog -ComponentVersion (Get-ComponentVersion)
        }
        catch {
            Write-Warning "Test Platform reporting failed: $($_.Exception.Message)"
        }
    }
}

if ($passed) {
    Write-Host 'FTD P0 e2e passed.'
    exit 0
}

Write-Error "FTD P0 e2e failed. $failureMessage"
exit 1
