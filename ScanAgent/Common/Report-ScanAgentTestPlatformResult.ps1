#Requires -Version 5.1
<#
.SYNOPSIS
  Reports Scan Agent E2E test results to the Test Platform HTTP API.

.DESCRIPTION
  Dot-source this file and call Complete-ScanAgentE2eTest from a test finally block.
  Set TESTPLATFORM_BASE_URL and TESTPLATFORM_FUNCTION_KEY (or TESTPLATFORM_CODE) to report; optional default URL below.
  Set either variable to override; set TESTPLATFORM_DISABLE=1 to skip reporting.

  Environment:
    TESTPLATFORM_BASE_URL     Override default Test Platform URL.
    TESTPLATFORM_FUNCTION_KEY Override default function key (?code=). Alias: TESTPLATFORM_CODE.
    TESTPLATFORM_DISABLE      Set to 1 to skip reporting (ignores defaults).
    TESTPLATFORM_COMPONENT_NAME  Optional; default ScanAgent.
    SCANAGENT_COMPONENT_VERSION  Optional override; E2E reporting sets this from agent.info or installed agent binaries.
    BUILD_BUILDID / GITHUB_RUN_ID  Optional buildId / run correlation.

.NOTES
  On failure, -EvidencePathsOnFailure lists related file names in the result message (no zip upload).
#>
Set-StrictMode -Version Latest

$script:ScanAgentE2eMaxInlineEvidenceBytes = 63 * 1024 * 1024

# Optional default Test Platform URL (East US 2). Function key must come from env — never commit keys.
$script:ScanAgentTestPlatformDefaultBaseUrl = 'https://test-results-eus2-94505680.azurewebsites.net'

function Get-ScanAgentTestPlatformReportConfig {
    if ($env:TESTPLATFORM_DISABLE -eq '1') {
        return $null
    }

    $baseUrl = $env:TESTPLATFORM_BASE_URL
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $script:ScanAgentTestPlatformDefaultBaseUrl
    }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return $null
    }

    $key = $env:TESTPLATFORM_FUNCTION_KEY
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = $env:TESTPLATFORM_CODE
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        Write-Warning 'Test Platform function key is missing; skipping report.'
        return $null
    }

    $component = $env:TESTPLATFORM_COMPONENT_NAME
    if ([string]::IsNullOrWhiteSpace($component)) {
        $component = 'ScanAgent'
    }

    $buildId = $env:BUILD_BUILDID
    if ([string]::IsNullOrWhiteSpace($buildId)) {
        $buildId = $env:GITHUB_RUN_ID
    }

    $version = $env:SCANAGENT_COMPONENT_VERSION
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = $env:TESTPLATFORM_COMPONENT_VERSION
    }

    return @{
        BaseUrl         = $baseUrl.TrimEnd('/')
        FunctionKey     = $key
        ComponentName   = $component.Trim()
        BuildId         = if ([string]::IsNullOrWhiteSpace($buildId)) { $null } else { $buildId.Trim() }
        ComponentVersion = if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version.Trim() }
    }
}

function Start-ScanAgentE2eRunLog {
    param(
        [Parameter(Mandatory)]
        [string] $TestId
    )

    $safeId = ($TestId -replace '[^\w\-]', '_')
    $path = Join-Path $env:TEMP "ScanAgent-E2E-$safeId-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').log"
    Start-Transcript -Path $path -Force | Out-Null
    return $path
}

function Stop-ScanAgentE2eRunLog {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        # Transcript may not be running.
    }
}

function Read-ScanAgentRunLogText {
    param(
        [string] $RunLogPath,
        [string] $RunLog
    )

    if (-not [string]::IsNullOrWhiteSpace($RunLog)) {
        return $RunLog
    }

    if ([string]::IsNullOrWhiteSpace($RunLogPath)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $RunLogPath)) {
        return $null
    }

    return [System.IO.File]::ReadAllText($RunLogPath)
}

function Get-ScanAgentE2eRelatedFileNames {
    param([string[]] $Paths)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $full = $null
        try {
            $full = [System.IO.Path]::GetFullPath($raw.Trim())
        }
        catch {
            $full = $raw.Trim()
        }

        if ([string]::IsNullOrWhiteSpace($full)) {
            continue
        }

        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $names.Add([System.IO.Path]::GetFileName($full))
            continue
        }

        if (Test-Path -LiteralPath $full -PathType Container) {
            foreach ($file in (Get-ChildItem -LiteralPath $full -File -Recurse -ErrorAction SilentlyContinue)) {
                $names.Add($file.Name)
            }
            continue
        }

        $names.Add([System.IO.Path]::GetFileName($full))
    }

    return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Format-ScanAgentE2eRelatedFileNamesMessage {
    param([string[]] $Paths)

    $fileNames = Get-ScanAgentE2eRelatedFileNames -Paths $Paths
    if ($null -eq $fileNames) {
        return $null
    }
    # PS 5.1: one name is a scalar string (no .Count).
    if (@($fileNames).Count -eq 0) {
        return $null
    }

    $bullets = $fileNames | Sort-Object | ForEach-Object { "  - $_" }
    return "Related files:`n" + ($bullets -join [Environment]::NewLine)
}

function Merge-ScanAgentE2eFailureMessageWithPaths {
    param(
        [string] $FailureMessage,
        [string[]] $EvidencePathsOnFailure
    )

    $pathsNote = Format-ScanAgentE2eRelatedFileNamesMessage -Paths $EvidencePathsOnFailure
    if ([string]::IsNullOrWhiteSpace($pathsNote)) {
        return $FailureMessage
    }

    if ([string]::IsNullOrWhiteSpace($FailureMessage)) {
        return $pathsNote
    }

    return "$FailureMessage$([Environment]::NewLine)$([Environment]::NewLine)$pathsNote"
}

function Send-ScanAgentTestPlatformResult {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Config,
        [Parameter(Mandatory)]
        [string] $TestName,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [string] $FailureMessage,
        [DateTimeOffset] $StartedAtUtc,
        [string] $RunId,
        [string] $RunLog,
        [string] $EvidenceZipPath
    )

    $finishedAtUtc = [DateTimeOffset]::UtcNow
    $body = [ordered]@{
        machineName   = $env:COMPUTERNAME
        componentName = $Config.ComponentName
        testName      = $TestName
        outcome       = if ($Passed) { 'Passed' } else { 'Failed' }
        startedAtUtc  = $StartedAtUtc.ToString('o')
        finishedAtUtc = $finishedAtUtc.ToString('o')
    }

    if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
        $body.message = $FailureMessage
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.BuildId)) {
        $body.buildId = $Config.BuildId
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.ComponentVersion)) {
        $body.componentVersion = $Config.ComponentVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $body.runId = $RunId
    }
    if (-not [string]::IsNullOrWhiteSpace($RunLog)) {
        $body.runLog = $RunLog
    }

    $zipPath = $EvidenceZipPath
    $zipBytes = $null
    $useInlineEvidence = $false
    if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
        $zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
        if ($zipBytes.Length -le $script:ScanAgentE2eMaxInlineEvidenceBytes) {
            $body.evidenceZipBase64 = [Convert]::ToBase64String($zipBytes)
            $useInlineEvidence = $true
        }
    }

    $uri = '{0}/api/results?code={1}' -f $Config.BaseUrl, [Uri]::EscapeDataString($Config.FunctionKey)
    $json = $body | ConvertTo-Json -Depth 6 -Compress
    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $json -ContentType 'application/json; charset=utf-8'
    $resultId = $response.id
    $versionSuffix = if ($body.componentVersion) { " version=$($body.componentVersion)" } else { '' }
    Write-Host "[TestPlatform] Reported result id=$resultId outcome=$($body.outcome) test=$TestName$versionSuffix"

    if ($zipBytes -and -not $useInlineEvidence -and $resultId) {
        $evidenceUri = '{0}/api/results/{1}/evidence?code={2}' -f $Config.BaseUrl, [Uri]::EscapeDataString($resultId), [Uri]::EscapeDataString($Config.FunctionKey)
        Invoke-WebRequest -Uri $evidenceUri -Method Post -InFile $zipPath -ContentType 'application/zip' | Out-Null
        Write-Host "[TestPlatform] Uploaded evidence zip ($([math]::Round($zipBytes.Length / 1MB, 2)) MB)."
    }

    return $response
}

function Complete-ScanAgentE2eTest {
    <#
    .SYNOPSIS
      Call from E2E test finally blocks to publish results to Test Platform.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TestId,
        [Parameter(Mandatory)]
        [string] $TestTitle,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [string] $FailureMessage,
        [Parameter(Mandatory)]
        [DateTimeOffset] $StartedAtUtc,
        [string[]] $EvidencePathsOnFailure = @(),
        [string] $RunLogPath,
        [string] $RunLog,
        [string] $RunId
    )

    $config = Get-ScanAgentTestPlatformReportConfig
    if (-not $config) {
        return
    }

    if (Get-Command -Name 'Ensure-ScanAgentE2eComponentVersionRegistered' -ErrorAction SilentlyContinue) {
        $null = Ensure-ScanAgentE2eComponentVersionRegistered
        $config = Get-ScanAgentTestPlatformReportConfig
        if (-not $config) {
            return
        }
    }

    # Close transcript before reading the log file (otherwise ReadAllText fails on Windows).
    Stop-ScanAgentE2eRunLog

    $testName = if ($TestTitle -match $TestId) { $TestTitle } else { "$TestId - $TestTitle" }
    $effectiveRunId = $RunId
    if ([string]::IsNullOrWhiteSpace($effectiveRunId) -and -not [string]::IsNullOrWhiteSpace($config.BuildId)) {
        $effectiveRunId = "$($config.BuildId):$TestId"
    }

    try {
        $reportMessage = $FailureMessage
        if (-not $Passed) {
            $reportMessage = Merge-ScanAgentE2eFailureMessageWithPaths -FailureMessage $FailureMessage `
                -EvidencePathsOnFailure $EvidencePathsOnFailure
        }

        $logText = Read-ScanAgentRunLogText -RunLogPath $RunLogPath -RunLog $RunLog
        Send-ScanAgentTestPlatformResult -Config $config -TestName $testName -Passed $Passed `
            -FailureMessage $reportMessage -StartedAtUtc $StartedAtUtc -RunId $effectiveRunId `
            -RunLog $logText -EvidenceZipPath $null
    }
    catch {
        Write-Warning "Test Platform reporting failed: $($_.Exception.Message)"
    }
}

function Invoke-ScanAgentE2eTestPlatformReportingFinally {
    param(
        [Parameter(Mandatory)]
        [string] $ReportScriptPath,
        [Parameter(Mandatory)]
        [string] $TestId,
        [Parameter(Mandatory)]
        [string] $TestTitle,
        [Parameter(Mandatory)]
        [bool] $Passed,
        [string] $FailureMessage,
        [DateTimeOffset] $StartedAtUtc,
        [string] $RunLogPath,
        [string[]] $EvidencePathsOnFailure = @()
    )

    if (-not (Test-Path -LiteralPath $ReportScriptPath)) {
        Write-Warning "Test Platform report script not found: $ReportScriptPath"
        return
    }

    . $ReportScriptPath
    try {
        $started = if ($StartedAtUtc -eq [DateTimeOffset]::MinValue) { [DateTimeOffset]::UtcNow } else { $StartedAtUtc }
        $evidence = @()
        if (-not $Passed) {
            $evidence = @($EvidencePathsOnFailure | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        Complete-ScanAgentE2eTest -TestId $TestId -TestTitle $TestTitle -Passed:$Passed `
            -FailureMessage $FailureMessage -StartedAtUtc $started -EvidencePathsOnFailure $evidence `
            -RunLogPath $RunLogPath
    }
    finally {
        Stop-ScanAgentE2eRunLog
    }
}
