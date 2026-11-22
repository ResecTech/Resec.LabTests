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
| `MAIL_E2E_RELAY_NAME` | Core relay computer name for lab policy (default `mail`) |
| `CORE_E2E_DEBUG_HOOK_URL` | Full Core `/debug/hook` URL (optional; otherwise derived from core debug base) |
| `MAIL_E2E_MAIL_AGENT_DEBUG_BASE_URL` | Mail agent debug base URL (default `http://127.0.0.1:4505`) |
| `MAIL_E2E_TEMP_FOLDER` | Mail agent policy temp folder (SanitizationOutput parent); optional if debug `status` exposes `tempFolderRoot` |
| `MAIL_E2E_SIMPLE_MAIL_SERVER_EXE` | Full path to `SimpleMailServer.exe` (after `-SimpleMailServerPath` param) |
| `MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE` | Full path to `SendBulkAttachmentMail.exe` (after `-SendBulkAttachmentMailPath` param) |
| `RESEC_MAIL_AGENT_EXE_LOCATION` / `LAB_MAIL_AGENT_EXE` | Full path to `Resec.Agent.Mail.exe` for E2E auto-start |
| `MAILAGENT_E2E_NO_AUTOSTART` | `1` to disable mail agent auto-start (MA-01) |

## E2E utility paths

E2E scripts resolve each tool in order: explicit script parameter → environment variable → LabTests `Tools\SimpleMailServer` or Mail repo build outputs (legacy) → `PATH`.

To discover built tools on the current machine and set the session variables:

```powershell
. .\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1
```

Use `-Force` to replace variables that are already set. Implementation: `MailAgentE2ePaths.ps1` (`Set-MailAgentE2eToolEnvironment`).

## MA-01 smoke and inbound

```powershell
.\Mail\P0\MA-01-SmokeAndInbound.ps1
```

MA-01 (and MA-02-C) **push / import / pop** a lab Core policy via `/debug/hook`: **Send Immediate Response** off, next hop `127.0.0.1:26`, `agent_type` `mail_agent`, permissive Basic, scanners off (step **D** uses `Scripts=False` and `Executables=False`, `NumPropType_DisallowedFilesInArchivesBehavior=0`, and blocked `.vbs` fixture for inbound 5xx). Rebuild **SendBulkAttachmentMail** after Mail repo changes (MailKit `Timeout` aligns with Send Immediate Response off waits). Use `-SkipCorePolicySetup` only when you manage policy yourself. **SendEml.exe** is needed only for MA-01 step **E**. Use `-SkipStepE` or build SendEml / set `MAIL_E2E_SEND_EML_EXE` before step E. Optional WMC Pass check uses `resec_admin` / `resec_admin` (or `CORE_E2E_WMC_*`). `-IncludeMa02CLongCommdown` chains `MA-02-C-NCP7307` long scenario after F1. Helper: `MailAgentE2eCorePolicy.ps1`.

## Lab prerequisites (MA-02 C / NCP-7307 reconnect scenario)

1. Core running with `AppSettings:EnableDebugInterface` = `True`.
2. Mail agent registered as relay **mail** (override `MAIL_E2E_RELAY_NAME`). Lab policy import sets **Email Agent Settings** (`StrPropType_ScannedFileEmailLocationRelayComputer`) for the export destination and **Relay Settings** (`StrPropType_RelayName` on the `Relay Settings` facet) so Core registers the connected mail agent and uses direct PutFile instead of a 300s RabbitMQ relay wait. Stop **Resec.Agent.ScanAgent** during MA-01 when possible (Scan Agent cannot process mail PutFile messages). MA-01 logs a **warning** if it is running; use `-FailOnRunningScanAgent` to fail fast. E2E scripts set next hop → SimpleMailServer port (default **26**) via lab policy import. MA-01 **auto-starts** `Resec.Agent.Mail.exe` when the debug hook is down (sets `EnableDebugInterface` in appsettings next to the exe). Use `-SkipStartMailAgent` or `MAILAGENT_E2E_NO_AUTOSTART=1` to require a pre-running agent.
3. Build **SimpleMailServer** (`Resec.LabTests\Tools\SimpleMailServer`) and **SendBulkAttachmentMail** (Mail repo), or use publish single-file outputs.
4. `MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1` starts (or verifies) **SimpleMailServer.exe --cli** on the capture port (default **127.0.0.1:26**), then runs **two** scenarios: short commdown hold (default **10s**, TestId `MA-02-C-Short`) and long hold (default **30s**, `MA-02-C-Long`). Use `-Scenarios Short|Long|All` to filter; tune holds via `-ShortCommDownHoldSeconds` / `-LongCommDownHoldSeconds`.

## Core debug

See `Resec.Core.Server/docs/core-debug-api.md`. Scripts use `commdown` / `commup` during outbound staging.

## Mail agent debug

When `EnableDebugInterface` is enabled, `GET` or `POST` `http://127.0.0.1:4505/debug/hook` accepts a **canonical** `command` (case-insensitive). Discover names with `command=commands`.

| # | Command | Notes |
|---|---------|-------|
| 1 | `commands` | List supported canonical ops |
| 2 | `version` | Agent + Gateway versions |
| 3 | `logpath` | Active log folder and file |
| 4 | `exepath` | Running executable path |
| 5 | `status` | E2E readiness (Gateway, SMTP listener, counts) |
| 6 | `stats` | `MailOperationalMetrics` snapshot + health checks |
| 7 | `logmark` | Requires `message` (query or JSON body); log line `DEBUG: E2E logmark: …` |

MA-01 mirrors each console `[STEP]` into **Core** and **mail agent** logs via `Write-MailAgentE2eCorrelationLogMark` (`MA-01 | …`). Bulk-send wait ticks log status summaries the same way. Grep both logs for `E2E logmark` and align timestamps with script output.

Policy apply wait emits `policy | wait 5s | stall after session default` when the mail log stops after `Current policy set to N (session default)` and `cannot enable syslog` without `Email agent configuration applied` / `ReturnImmediateResponse) is disabled`. That pattern is usually **not** a bad assignment rule: Core often shows `debug-mail-agent-ma-lab` and `Num of policies:1` while the agent wedged during `PoliciesReceived` (e.g. agentcomm nudge during first connect made it worse). `Ensure-MailAgentE2eLabPolicyOnAgent` waits for apply **before** any nudge; if stall persists, restart **Resec.Core** and the mail agent, then re-run.
| 8 | `overload` | Lab-only: `mode=off\|spoolfull\|spoolcap\|sessions\|processing` (`maxMessages` with `spoolcap`) |
| 9 | `exit` | Schedule process exit |

Legacy aliases (`ver`, `logfile`, `getstatus`, `stop`, …) are **not** supported.

The `status` command includes Gateway connectivity: `coreConnectionStatus` (`Disconnected` / `Connected` / `Authenticated`), `coreConnecting`, `coreSessionPhase`, plus `coreConnected` (authenticated ready). E2E helpers live in `MailAgentE2eMailAgentDebug.ps1` (`Ensure-MailAgentE2eProcessRunning`, `Wait-MailAgentDebugReady`, `Wait-MailAgentDebugReconnect`, `Add-MailAgentE2eLogMark`, `Set-MailAgentDebugOverload`, staging folder from `status.tempFolderRoot`, failure evidence from `logpath`).
