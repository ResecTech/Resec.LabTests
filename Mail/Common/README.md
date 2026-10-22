# Mail Agent E2E — Test Platform reporting

`Report-MailAgentTestPlatformResult.ps1` posts E2E outcomes to the [Test Platform](https://github.com/ResecTech/TestPlatform) Function App (same contract as Scan Agent).

E2E scripts bootstrap **Windows PowerShell 5.1** by dot-sourcing `MailAgentE2eBootstrap.ps1` at script scope. Do not dot-source Common files from inside a function—PS 5.1 keeps that scope local.

## Fixtures

| Path | Purpose |
| --- | --- |
| `Fixtures\Mail\E2eAttach\` | Attachments for `SendBulkAttachmentMail` |
| `MAILAGENT_TEST_FILES_ROOT` / `LAB_FIXTURES_ROOT` | Optional fixture root override(s) |

## Configuration (CI or local)

| Variable | Description |
| --- | --- |
| `TESTPLATFORM_BASE_URL` | Override Test Platform URL |
| `TESTPLATFORM_FUNCTION_KEY` | Function key (`TESTPLATFORM_CODE` alias) |
| `TESTPLATFORM_DISABLE` | `1` to skip reporting (do not set for dashboard visibility) |
| `TESTPLATFORM_COMPONENT_NAME` | Default `MailAgent` |
| `MAILAGENT_COMPONENT_VERSION` | Optional version string for dashboard |
| `MAIL_E2E_CORE_DEBUG_BASE_URL` | Core debug base URL (default `https://localhost:4504`) |
| `MAIL_E2E_MAIL_AGENT_DEBUG_BASE_URL` | Mail agent debug base URL (default `http://127.0.0.1:4505`) |
| `MAIL_E2E_TEMP_FOLDER` | Mail agent policy temp folder (SanitizationOutput parent); optional if debug `status` exposes `tempFolderRoot` |
| `MAIL_E2E_SIMPLE_MAIL_SERVER_EXE` | Full path to `SimpleMailServer.exe` (after `-SimpleMailServerPath` param) |
| `MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE` | Full path to `SendBulkAttachmentMail.exe` (after `-SendBulkAttachmentMailPath` param) |

## E2E utility paths

E2E scripts resolve each tool in order: explicit script parameter → environment variable → repo `bin` / publish outputs → `PATH`.

To discover built tools on the current machine and set the session variables:

```powershell
. .\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1
```

Use `-Force` to replace variables that are already set. Implementation: `MailAgentE2ePaths.ps1` (`Set-MailAgentE2eToolEnvironment`).

## Lab prerequisites (NCP-7307 reconnect scenario)

1. Core running with `AppSettings:EnableDebugInterface` = `True`.
2. Mail agent running with root `EnableDebugInterface` = `true` (debug hook on **127.0.0.1:4505**); registered as relay **mail**; policy next hop → SimpleMailServer port (default **26**).
3. Build **SimpleMailServer** and **SendBulkAttachmentMail** (or use publish single-file outputs).
4. MA-01 starts (or verifies) **SimpleMailServer.exe --cli** on the capture port (default **127.0.0.1:26**), then runs **two** scenarios: short commdown hold (default **10s**, `MA-01-Short`) and long hold (default **30s**, `MA-01-Long`). Use `-Scenarios Short|Long|All` to filter; tune holds via `-ShortCommDownHoldSeconds` / `-LongCommDownHoldSeconds`.

## Core debug

See `Resec.Core.Server/docs/core-debug-api.md`. Scripts use `commdown` / `commup` during outbound staging.

## Mail agent debug

When `EnableDebugInterface` is enabled, `GET http://127.0.0.1:4505/debug/hook?command=<name>` supports `version`, `logpath`, `exepath`, `status`, and `exit`. The `status` command includes Gateway connectivity: `coreConnectionStatus` (`Disconnected` / `Connected` / `Authenticated`), `coreConnecting`, `coreSessionPhase`, plus `coreConnected` (authenticated ready). E2E helpers live in `MailAgentE2eMailAgentDebug.ps1` (`Wait-MailAgentDebugReady`, `Wait-MailAgentDebugReconnect` after Core `commup`, staging folder from `status.tempFolderRoot`, failure evidence from `logpath`).
