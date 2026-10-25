# Scan Agent E2E — Test Platform reporting

`Report-ScanAgentTestPlatformResult.ps1` posts E2E outcomes to the [Test Platform](https://github.com/ResecTech/TestPlatform) Function App.

E2E scripts bootstrap **Windows PowerShell 5.1** by dot-sourcing `ScanAgentE2eBootstrap.ps1` at script scope (loads `ScanAgentE2ePs51.ps1`, reporting, and `ScanAgentE2eDebug.ps1`). Do not dot-source those files from inside a function—PS 5.1 keeps that scope local.

- `Get-CollectionCount` / `Get-SanitizationFileEntries` — safe scalar vs array handling (JSON and pipelines).
- `Resolve-ScanAgentDebugPath` — `Resec.LabTests\ScanAgent\ScanAgentDebug.exe` (optional copy), Scan Agent repo `bin\Debug\...`, and DebugClient outputs. Override via `lab.local.json` `optional.scanAgentDebugExe` or `LAB_SCANAGENT_DEBUG_EXE`.
- `ScanAgentE2eCorePolicy.ps1` — Core `/debug/hook` **pushpolicystate** → **importpolicies** (default policies **Test5-a** / **Test5-b**, SMB stores **sa05-smb-in** / **sa05-smb-out** with the same names in both policies but different `c:\temp\SA-05-*` / `c:\test\SA-05-*` folder mappings) → **commdown** (5s) → **commup** → **poppolicystate** for SA-05. Helper: `Load-Sa05CorePolicies.ps1`. Env: `SCANAGENT_SA05_POLICY_TEMPLATE_XML`, optional `SCANAGENT_SA05_TEMPLATE_POLICY_NAME`.
- P0 **SA-08** (`SA-08-AbortMidJobStatusActionBar.ps1`) — Core **pushpolicystate** → **importpolicies** (single policy **Test8-abort**, SMB **sa08-smb-in** / **sa08-smb-out** → `c:\test\SA-08-in` / `c:\test\SA-08-out`) → **commdown**/**commup** → **abortSanitization** mid-job; asserts activity bar + **openRejectedDrawer** lists every Aborted file; **poppolicystate** + restore pre-test `policy.select` in `finally`. Helper: `Load-Sa08CorePolicy.ps1`. Env: same template XML as SA-05 (`SCANAGENT_SA05_POLICY_TEMPLATE_XML`).
- `ScanAgentE2eNcp7328Policy.ps1` — Core hook flow for **NCP7328-one** / **NCP7328-multi** (1 vs 2 SMB roots per panel). Used by P3 `SA-32-NCP7328-RootLocationDriveDropdown.ps1`. Core read-only export: `exportpolicystate` (see `ScanAgentE2eCorePolicy.ps1` `Export-ScanAgentCorePolicyState`).

## E2E output folders

Sanitization destinations for Scan Agent E2E scripts live under **`C:\test`** (not `C:\` root):

- P0 scripts create a unique run folder: `C:\test\SA_TestDest_<guid>\` (removed on success).
- P1 scripts default to a stable per-test folder: `C:\test\SA-14`, `C:\test\SA-15`, etc.

Helpers are in `ScanAgentE2eDestination.ps1` and `ScanAgentE2eNavigation.ps1` (loaded via `ScanAgentE2eBootstrap.ps1`). Destination segment navigation calls `refreshDestinationContent` before each `openFolder` so folders created on disk under `C:\test` appear in the grid.

## Configuration (CI or local)

`ScanAgentE2eBootstrap.ps1` calls `Initialize-ScanAgentE2eTestPlatformFromLabConfig` so **all** Scan Agent E2E scripts (SA-05, SA-08, …) share the same reporting setup. Set `optional.testPlatformFunctionKey` (and optional `testPlatformBaseUrl`) in gitignored `config\lab.local.json`, or use env vars. Default URL is in `Report-ScanAgentTestPlatformResult.ps1` when env/lab URL is unset.

| Variable | Required | Description |
| --- | --- | --- |
| `TESTPLATFORM_BASE_URL` | No | Overrides lab/env/default URL |
| `TESTPLATFORM_FUNCTION_KEY` | Yes* | Function key (`TESTPLATFORM_CODE` alias). *Or `optional.testPlatformFunctionKey` in `lab.local.json`. |
| `TESTPLATFORM_DISABLE` | No | Set to `1` to skip reporting (e.g. offline local runs). |
| `TESTPLATFORM_COMPONENT_NAME` | No | Dashboard product name (default `ScanAgent`). |
| `SCANAGENT_COMPONENT_VERSION` | No | Overrides auto version. Otherwise set from `agent.info` when the debug pipe works, or from installed `Resec.Agent.ScanAgent.exe` / `Resec.Agent.Gateway.dll` in `Complete-ScanAgentE2eTest` (including failed runs). |
| `BUILD_BUILDID` / `GITHUB_RUN_ID` | No | Stored as `buildId`; also used in `runId` when set. |

## Usage in an E2E script

Dot-source the report script **before** `try` so `Invoke-ScanAgentE2eTestPlatformReportingFinally` is in scope in `finally` (PowerShell 5.1).

```powershell
$reportScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Common\Report-ScanAgentTestPlatformResult.ps1'
. $reportScript

$script:TestStartedAtUtc = [DateTimeOffset]::UtcNow
$script:ScenarioFailureMessage = $null
$script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId 'SA-04'

try {
    # ... test body ...
    $script:ScenarioPassed = $true
}
catch {
    $script:ScenarioFailureMessage = $_.Exception.Message
    throw
}
finally {
    try {
        $evidence = @()
        if (-not $script:ScenarioPassed -and $destinationPath -and (Test-Path -LiteralPath $destinationPath)) {
            $evidence += $destinationPath
        }
        Complete-ScanAgentE2eTest -TestId 'SA-04' -TestTitle 'Rejected drawer count matches blocked' `
            -Passed:$script:ScenarioPassed -FailureMessage $script:ScenarioFailureMessage `
            -StartedAtUtc $script:TestStartedAtUtc -EvidencePathsOnFailure $evidence `
            -RunLogPath $script:E2eRunLogPath
    }
    finally {
        Stop-ScanAgentE2eRunLog
    }
    # ... existing teardown ...
}
```

On **failure**, optional `-EvidencePathsOnFailure` entries are expanded to **file names** in the result **message** (folders are scanned recursively; no evidence zip).
