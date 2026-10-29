# Resec.LabTests

Central home for Resec **lab E2E** scripts, fixtures, and shared configuration. Product repositories (Core, Scan Agent, Mail, FileTypeDetection) stay focused on application code; this repo is what you clone on a test machine together with product checkouts.

Results are reported to the [Test Platform](https://github.com/ResecTech/TestPlatform) HTTP API (same contract as before). Set `TESTPLATFORM_DISABLE=1` to run without reporting.

## Quick start (new lab machine)

1. Clone this repo and each product repo you need (paths are yours to choose).
2. Create local config:
   ```powershell
   cd C:\Work\ResecTech\Resec.LabTests
   .\scripts\Initialize-LabConfig.ps1
   notepad .\config\lab.local.json
   ```
3. Set `products.*.repoRoot` to the git roots of Scan Agent, Core, Mail, and/or FileTypeDetection.
4. Build product bits (Scan Agent DebugClient, Mail E2E tools, etc.) in those repos.
5. Run a test, for example:
   ```powershell
   .\ScanAgent\P0\SA-01-ConnectSourcesDestinationsLoad.ps1
   .\Core\NCP7330-QrImageSanitize.ps1 -PolicyTemplateXml C:\resec\ImportExport\latest.xml
   .\Core\NCP7344-OfficeNoCdrSanitize.ps1
   .\Mail\P0\MA-01-NCP7307-ReconnectOutboundDelivery.ps1
   .\FileTypeDetection\P0\FTD-01-E2E.ps1
   ```

## Layout

| Path | Contents |
| --- | --- |
| `Fixtures/` | **All files passed through products** (shared across suites). See [Fixtures/README.md](Fixtures/README.md). |
| `config/` | `lab.local.json` (machine-specific; gitignored) from `lab.local.json.example` |
| `Common/` | `LabConfig.ps1`, `LabFixtures.ps1`, deploy fixture helpers (`LabTestDeploySuiteDefaults.ps1`) |
| `ScanAgent/` | Scan Agent UI E2E scripts and `Common/` helpers |
| `Core/` | Core `/debug/hook` E2E and QR fixture generator tool |
| `Mail/` | Mail Agent E2E and SimpleMailServer config |
| `FileTypeDetection/` | P0 wrapper that runs the full FTD unit test suite and reports once |

## Configuration

**File:** `config\lab.local.json` (copy from `lab.local.json.example`).

**Environment overrides** (optional; take precedence over JSON):

| Variable | Purpose |
| --- | --- |
| `LAB_TESTS_ROOT` | Root of this repo if not inferred from scripts |
| `LAB_TESTS_CONFIG` | Alternate path to `lab.local.json` |
| `LAB_FIXTURES_ROOT` | Override default `<repo>\Fixtures` |
| `LAB_SCANAGENT_REPO_ROOT` | Scan Agent git root |
| `LAB_CORE_REPO_ROOT` | Core git root |
| `LAB_MAIL_REPO_ROOT` | Mail Agent git root |
| `LAB_FTD_REPO_ROOT` | FileTypeDetection git root |
| `LAB_SCANAGENT_DEBUG_EXE` | Full path to `ScanAgentDebug.exe` |

Existing per-suite variables (`CORE_E2E_*`, `MAIL_E2E_*`, `MAILAGENT_TEST_FILES_ROOT`, `SCANAGENT_TEST_FILES_ROOT`, Test Platform `TESTPLATFORM_*`) still work.

## Fixtures

Default root: **`Fixtures\`** (`Allowed`, `Blocked`, `CDR`, `QR\NCP-7330`, `Office\NCP-7344`, `Mail\E2eAttach`). Scan Agent scripts resolve this tree automatically; legacy **`SA-TestFiles`** on `C:\` is still supported.

Regenerate Core QR images:

```powershell
dotnet run -c Release --project Core\Tools\GenerateQrTestFixtures\GenerateQrTestFixtures.csproj
```

## Deploy fixtures (Lab Test Runner)

Each E2E test script can define **`Get-LabTestDeployRequirements`**, returning deploy script ids (see `Common\LabTestDeploySuiteDefaults.ps1`). Before running a test, **Lab Test Runner** checks that each required product has a successful lab deploy under `{Production download root}\{Product}-{Branch}-{Version}\Deploy\` (`.lab-deploy.json` + payload). Optional **`RequiresRunning`** verifies a matching process is up (used for Core).

Download builds from Product catalog, deploy from **Deploy** in the runner, then run tests.

## Mail E2E tools

From the Mail Agent repo root:

```powershell
dotnet build src\Resec.Agent.Mail.sln -c Debug -p:Platform=x64
```

Then dot-source:

```powershell
. .\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1
```

## Product repo migration

E2E assets previously under `src\Test` (or `tests/`) in product repos now live here. Product trees contain a short `README.md` pointing to this repository.
