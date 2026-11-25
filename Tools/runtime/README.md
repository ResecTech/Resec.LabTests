# Lab E2E runtime tools (win-x64)

Self-contained executables for machines **without the .NET SDK**. E2E scripts resolve these automatically via `Common\LabRuntimeTools.ps1` (`Tools\runtime\win-x64\`).

| File | Role |
| --- | --- |
| `SimpleMailServer.exe` | SMTP capture (`--cli`) for Mail and Core E2E |
| `SendBulkAttachmentMail.exe` | Inbound bulk SMTP to the mail agent |
| `SendEml.exe` | Optional MA-01 step E (`BulkMailConfig.json` beside exe when using defaults) |
| `ScanAgentDebug.exe` | Scan Agent UI E2E debug client |
| `lab-tools.manifest.json` | SHA256 fingerprints after refresh |

**Product agents** (Core, Mail, Scan Agent, etc.) are **not** stored here — use Lab Test Runner **Product catalog** download and **Deploy**.

## Refresh (maintainers with SDK)

```powershell
cd C:\Work\ResecTech\Resec.LabTests
.\scripts\Publish-LabRuntimeTools.ps1
```

Optional `-MailRepoRoot` / `-ScanAgentRepoRoot` when repos are not siblings of LabTests. Commit changes under `win-x64\` when tool behavior or dependencies change.