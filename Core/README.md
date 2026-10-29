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
