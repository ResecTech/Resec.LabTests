# Core lab E2E

PowerShell tests drive a **running Resec Core** instance through **`/debug/hook`** (lab-only; `EnableDebugInterface = True`).

## NCP-7330 — image QR

```powershell
cd <Resec.LabTests>\Core
.\NCP7330-QrImageSanitize.ps1 -PolicyTemplateXml C:\resec\ImportExport\ImportExport_latest.xml
```

Fixtures: `..\Fixtures\QR\NCP-7330\`. Override with `CORE_E2E_FIXTURE_ROOT` or `-FixtureRoot`.

Regenerate images: `dotnet run -c Release --project Tools\GenerateQrTestFixtures\GenerateQrTestFixtures.csproj`

## NCP-7344 — Office without CDR

```powershell
cd <Resec.LabTests>\Core
.\NCP7344-OfficeNoCdrSanitize.ps1
```

Fixtures: `..\Fixtures\Office\NCP-7344\`. Policy: POST **`importpolicies`** with JSON from `Policies\NCP7344-office-nocdr-lab.importpolicies.json` (embedded `policyRawData`, CDR off — no WebMC Import/Export XML). Override with `-PolicyImportJson` or `CORE_E2E_POLICY_IMPORT_JSON`. On failure, zips Core Serilog (`logpath`) + output for Test Platform evidence.

## NCP-7334 — RPM (bsdtar)

```powershell
cd <Resec.LabTests>\Core
.\NCP7334-RpmSanitize.ps1
```

Fixtures: `..\Fixtures\Archives\NCP-7334\` (`resec-rpm-test-1.0-1.noarch.rpm`). Reuses the NCP-7344 no-CDR lab policy import. Requires embedded **bsdtar** on the Core host. Asserts passthrough output (unchanged SHA-256) for the clean fixture.

## NCP-7352 — job email notification (blocked template)

```powershell
cd <Resec.LabTests>\Core
.\NCP7352-JobEmailNotificationBlocked.ps1
```

Uses **`pushsystempropertystate`** / **`importsystemproperties`** / **`popsystempropertystate`** to point Core alert SMTP at **127.0.0.1** (default port **2525**, env `CORE_E2E_SMTP_PORT`). Starts **SimpleMailServer.exe --cli** from **`Tools\SimpleMailServer`** to capture the job notification (env `MAIL_E2E_SIMPLE_MAIL_SERVER_EXE` or `-SimpleMailServerPath`). If you already run a local SMTP listener, use **`-SkipStartSmtpCapture`**.

Policy: `Policies\NCP7352-email-notification-blocked.importpolicies.json` (unknown file types blocked + Email Notification facet with distinct HTML markers). Runs **two** sanitizations: unknown bytes → blocked email template; `Fixtures\FileTypeDetection\sample.txt` (or generated `.txt`) → success template. Use `-SkipSuccessScenario` for blocked-only. Requires Core with the NCP-7352 JobReporter fix and debug system-property commands.

## NCP-7360 — Password Portal status after encrypted archive block

```powershell
cd <Resec.LabTests>\Core
.\NCP7360-PortalBlockedArchiveStatus.ps1
```

Policy: `Policies\NCP7360-portal-encrypted-archive-block.importpolicies.json` (block archive on disallowed embedded files, sanitization report for encrypted/blocked, unknown types blocked). Enables **Portal_Enabled** via `importsystemproperties` (uses existing **Portal_Secret** for `/v1/portal` `apiToken`, or sets a lab fallback when empty). Builds an AES-encrypted zip at runtime (password **1111**, see `Fixtures\Blocked\Encrypted\NCP-7360\manifest.json`), runs debug **sanitize**, submits the password through **`/v1/portal/submit-file-data`**, and asserts **`/v1/portal/file-data`** is **Blocked**, not **Passed** — reproduces [NCP-7360](https://resec.atlassian.net/browse/NCP-7360) until Core/portal outcome bubbling is fixed.

## NCP-7374 — Cross-cluster temp file (`sanitizecrosscluster`)

```powershell
cd <Resec.LabTests>\Core
.\NCP7374-CrossClusterSanitize.ps1
```

Exercises DEBUG **`sanitizecrosscluster`** with **`crossClusterMode=inprocess`** (portal enqueue + worker leg on one Core). Fixtures: `..\Fixtures\CrossCluster\NCP-7374\` (reuses `Office\NCP-7344\` Office files via manifest `relativeSource`). Policy: same **`NCP7344-office-nocdr-lab`** importpolicies JSON. Asserts **`processingServer`** and **`crossClusterQueueName`** (`DEBUG-crosscluster-inprocess`), and **forbids** `Temp\*.x already exists` / matching IOException lines in outcome and Serilog ([NCP-7374](https://resec.atlassian.net/browse/NCP-7374)). Use **`-ParallelStress`** for repeated runs; copy Jira repro files into the fixture folder for optional QA parity; **`-CrossClusterMode rabbit`** needs MQ and a second Core.

## NCP-7374 — Cross-portal PutFile repro (`ExistingFile` / temp `-N.x`)

```powershell
cd <Resec.LabTests>\Core
.\NCP7374-CrossPortalPutFileRepro.ps1
```

Targets the ticket failure path: **CDR worker output** + **`Local::`** store + synthetic **`portalServerOverride`** (DEBUG `reproNcp7374CrossPortalPutFile`) → Rabbit **`SendPutFileRequest`** → **`ExistingFile.GetExternalPathToFile`**. Policy: **`NCP7374-office-cdr-local-putfile-lab`** (`Common\CoreE2eNcp7374PutfilePolicy.ps1`). Manifest: `..\Fixtures\CrossCluster\NCP-7374\putfile-repro-manifest.json`. Default expects **repro signals** on unpatched Core; after the fix, run **`.\NCP7374-CrossPortalPutFileRepro.ps1 -AssertBugFixed`**. `sanitizecrosscluster` defaults **`simulateMqPutFileSuccess: true`** so PutFile does not wait ~5 minutes for a missing portal consumer (pass **`simulateMqPutFileSuccess: false`** on the hook body to exercise real MQ timeout).

## NCP-7373 — Email embedded xlsx removal after CDR timeout (no self file-lock)

```powershell
cd <Resec.LabTests>\Core
.\NCP7373-EmailEmbeddedAttachmentRemoval.ps1
```

Policy: `Policies\NCP7373-email-embedded-cdr-timeout-lab.importpolicies.json` (1s CDR budget, remove disallowed embedded files). Fixture: `..\Fixtures\Mail\NCP-7373\` — builds a multipart EML with `Office\NCP-7344\simple.xlsx` when `ncp7373-lab-embedded-xlsx.eml` is not present; drop the Jira repro EML into that folder for full parity. Requires Core with DEBUG `includeEmbeddedSummary` on sanitize and NCP-7373 lock-release logging. Asserts `embeddedObjects` outcomes, structured removal log line, and **no** `Failed to delete embedded file` warnings ([NCP-7373](https://resec.atlassian.net/browse/NCP-7373)).

## NCP-7362 — WMC From column when EML has no From

```powershell
cd <Resec.LabTests>\Core
.\NCP7362-WmcEmptyFromAddress.ps1
```

WMC REST login defaults to **resec_admin** / **resec_admin** (same as Core `AdminUser` / `AdminPassword` on a fresh install). Override with `CORE_E2E_WMC_*` or `-WmcUser` / `-WmcPassword` when needed.

Fixture: `..\Fixtures\Mail\NCP-7362\` (Jira `RDP verification.eml` — blank **From**, **To** `ben@resec.co`). Reuses the NCP-7344 no-CDR lab policy import. After debug **sanitize**, logs into WebMC REST and asserts **`POST /v1/sanitizations/email`** returns empty **mailFromAddress** and does not duplicate the recipient into **From** ([NCP-7362](https://resec.atlassian.net/browse/NCP-7362)).

## NCP-7365 — policy assignment conditions (simulate + file size)

```powershell
cd <Resec.LabTests>\Core
.\NCP7365-PolicyAssignmentConditions.ps1
```

Imports lab policies and one enabled assignment rule per **PolicyConditions** schema field (agent type, file/mail/user identity fields, file size operators). Exercises **`POST /v1/policies/conditions/simulate`** with positive and negative context for each field (same API WebMC **Simulation** uses). **File: Size** rules use the WebMC wire shape (`target` magnitude + `unit`, e.g. `500`/`MB`, `4`/`KB`) so [NCP-7365](https://resec.atlassian.net/browse/NCP-7365) (Core ignoring `unit`) fails until fixed. Then re-imports with **only** the **file_size > 4 KB** rule and runs debug **sanitize** (1 KiB vs 5 KiB) so agent/user rules cannot match first (`-SkipSanitizeFileSizeScenario` for simulate-only runs). If Core is not listening on port 4504, the script starts **`Resec.Core.exe`** from `RESEC_CORE_EXE_LOCATION` or `lab.local.json` (`-SkipAutoStartCore` to disable).

**Cold start:** Full Core init (scanners, RabbitMQ, port 11073) often takes **1–2 minutes**. Poll **`command=ready`** until **`coreInitialized`** is true before simulate/import. Auto-started Core console output goes to temp **`CoreE2e-autostart-*.{stdout,stderr}.log`** (not the test transcript). After **`Listening for connections on port 11073`**, only periodic **MemoryGuard** lines in Serilog are normal idle behavior — not a hung startup. Confirm readiness: `Invoke-RestMethod 'https://localhost:4504/debug/hook?command=ready' -SkipCertificateCheck`.
