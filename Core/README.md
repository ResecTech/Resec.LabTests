# Core lab E2E

PowerShell tests drive a **running Resec Core** instance through **`/debug/hook`** (lab-only; `EnableDebugInterface = True`).

## NCP-7330 — image QR

```powershell
cd <Resec.LabTests>\Core
.\NCP7330-QrImageSanitize.ps1 -PolicyTemplateXml C:\resec\ImportExport\ImportExport_latest.xml
```

Fixtures: `..\Fixtures\QR\NCP-7330\`. Override with `CORE_E2E_FIXTURE_ROOT` or `-FixtureRoot`.

Regenerate images: `dotnet run -c Release --project Tools\GenerateQrTestFixtures\GenerateQrTestFixtures.csproj`
