# Lab deploy scripts

PowerShell scripts in this folder are run from **Lab Test Runner → Deploy** (or `LabTestRunner.exe deploy`).

## Layout

Place one script per product/agent at the top level only:

```text
Deploy/
  ScanAgent.ps1
  Core.ps1
  Mail.ps1
  FileTypeDetection.ps1
```

The **product name** is taken from the script file name (without `.ps1`). Optional prefix: `Deploy-ScanAgent.ps1` → product `ScanAgent`.

## Runner contract

For each selected script the runner:

1. Discovers scripts under `{Lab tests root}\Deploy\*.ps1` (Deploy UI lists these only; FTP is used from **Product catalog** for downloads, not on the Deploy screen).
2. At run time, picks the **newest** non-empty folder under `{Production download root}` whose name matches the script id (e.g. `Agent.ScanAgent-master-26.2.326` for `ScanAgent.ps1`).
3. Creates `{that folder}\Deploy\` and passes it as **`-TargetFolder`**.
4. Sets lab **system variables** from `config\lab.local.json` (same as E2E tests).
5. Sets **`$version`** from the parsed folder name immediately before invoking the script.
6. Sets `LAB_TESTS_ROOT`, `LAB_PRODUCTION_ROOT`, `TESTPLATFORM_*`, and `TESTPLATFORM_IS_PRODUCTION=1` in the process environment.

### Parameters

```powershell
param(
    [Parameter(Mandatory)] [string] $SourceFolder,
    [Parameter(Mandatory)] [string] $TargetFolder,
    [string] $ProductName,
    [string] $BranchName,
    [string] $VersionName,
    [ValidateSet('deploy', 'is_deployed', 'un_deploy')]
    [string] $Action = 'deploy'
)
```

- **`SourceFolder`**: local FTP download folder for the chosen build (`{Production download root}\{Product}-{Branch}-{Version}\`).
- **`TargetFolder`**: always `{SourceFolder}\Deploy` (created by the runner).
- **`Action`**: `deploy` (default), `is_deployed`, or `un_deploy`. The runner passes `-Action deploy` when you click **Run selected**; it runs **`is_deployed` first** and skips deploy when that build is already installed for the same product, branch, and version.

### Deploy state

After a successful deploy, scripts write **`{TargetFolder}\.lab-deploy.json`** (product, branch, version, `deployedUtc`). Shared helpers live in **`_DeployState.ps1`** (not listed as a deploy script).

- **`is_deployed`**: exit **0** if state matches and payload files exist (placeholder scripts may be state-only); exit **1** if not deployed. Writes one JSON object to **stdout**: `{ "componentName", "requiresRunning": false, "state": { "deployed", "running" } }` (`running` reflects whether the component process is up).
- **`un_deploy`**: remove installed files and delete the state file.

**FileTypeDetection.ps1** implements full deploy (zip extract), state, and un-deploy. Other scripts use placeholders but follow the same action contract.

Before running a test, **Lab Test Runner** runs **`Common\Check-LabTestDeployFixtures.ps1`**, which evaluates **`Get-LabTestDeployRequirements`** and prints a JSON **array** of the same shape (one entry per required component). Exit **0** when every requirement is satisfied.

## CLI example

```powershell
LabTestRunner.exe list-deploy-scripts
LabTestRunner.exe deploy --script ScanAgent
LabTestRunner.exe deploy --script FileTypeDetection --undeploy
LabTestRunner.exe deploy --script FileTypeDetection --script Core
LabTestRunner.exe deploy --gui
```

Select one or more scripts in the Deploy UI (**Run selected** or **Undeploy selected**) or repeat `--script` on the CLI. Download builds from **Product catalog** first; branch and version are taken from the selected local build folder (Deploy UI) or the newest matching folder (CLI).
