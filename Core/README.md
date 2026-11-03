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
