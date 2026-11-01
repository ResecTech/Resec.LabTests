# SimpleMailServer (lab E2E)

Headless or WinForms SMTP listener used by **Mail** and **Core** lab E2E scripts (`--cli` saves incoming mail and writes `simple-mail-server-status.json`).

## Build

```powershell
cd C:\Work\ResecTech\Resec.LabTests\Tools\SimpleMailServer
dotnet build -c Debug
# or Publish → bin\publish\single-file\SimpleMailServer.exe (FolderProfile)
```

E2E scripts resolve the exe via `Mail\Common\MailAgentE2ePaths.ps1` (LabTests `Tools\SimpleMailServer` first), env `MAIL_E2E_SIMPLE_MAIL_SERVER_EXE`, or `-SimpleMailServerPath`.

## Headless config

Shared lab defaults: `Mail\Config\simple-mail-server.appsettings.json` (port, save folder, response delay). Override per run with `--config`, `--port`, `--save-folder`, etc. (see MA-01 / `MailAgentE2eSimpleMailServer.ps1`).

Moved from `Resec.Agent.Mail` — **SendBulkAttachmentMail** remains in the Mail Agent repo.
