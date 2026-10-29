# Shared lab fixtures

All files passed through Resec products during lab E2E live here. Product scripts resolve this folder via `Get-LabFixturesRoot` (default: `<Resec.LabTests>\Fixtures`).

| Path | Typical use |
| --- | --- |
| `Allowed/` | Scan Agent sanitize pass / reconstruction scenarios |
| `Blocked/` | Blocked, infected, encrypted, file-type rejection |
| `CDR/` | Content transformation (SVG, CSV, Office, etc.) |
| `QR/NCP-7330/` | Core debug-hook image QR regression |
| `Office/NCP-7344/` | Core debug-hook Office with CDR disabled (NCP-7344) |
| `Mail/E2eAttach/` | Mail Agent bulk inbound attachments |
| `FileTypeDetection/` | Deployed FTD lab detection cases (`manifest.json`) |

Override root: `LAB_FIXTURES_ROOT`, `config\lab.local.json` → `optional.fixturesRoot`, or legacy `SCANAGENT_TEST_FILES_ROOT` / `MAILAGENT_TEST_FILES_ROOT` (semicolon-separated).

Legacy Scan Agent layouts: a folder named `SA-TestFiles` on `C:\` with the same `Allowed` / `Blocked` / `CDR` children is still discovered when the repo `Fixtures` folder is not used.
