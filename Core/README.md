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

## NCP-7362 — WMC From column when EML has no From

```powershell
cd <Resec.LabTests>\Core
.\NCP7362-WmcEmptyFromAddress.ps1
```

WMC REST login defaults to **resec_admin** / **resec_admin** (same as Core `AdminUser` / `AdminPassword` on a fresh install). Override with `CORE_E2E_WMC_*` or `-WmcUser` / `-WmcPassword` when needed.

Fixture: `..\Fixtures\Mail\NCP-7362\` (Jira `RDP verification.eml` — blank **From**, **To** `ben@resec.co`). Reuses the NCP-7344 no-CDR lab policy import. After debug **sanitize**, logs into WebMC REST and asserts **`POST /v1/sanitizations/email`** returns empty **mailFromAddress** and does not duplicate the recipient into **From** ([NCP-7362](https://resec.atlassian.net/browse/NCP-7362)).
