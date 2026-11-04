# DirWatcher lab E2E

PowerShell E2E scripts for **Resec Directory Watcher** against a lab Core with `/debug/hook` policy injection.

## Prerequisites

| # | Requirement |
|---|-------------|
| 1 | Core running with `EnableDebugInterface=True` (port 4504). |
| 2 | DirWatcher installed, registered to Core. E2E starts DW with `DIRWATCHER_ENABLE_DEBUG_INTERFACE=true` (HTTP debug on **4506**); no appsettings change required. |
| 3 | `config\lab.local.json` (optional `DirWatcher.repoRoot`, `dirWatcherDebugBaseUrl`). |
| 4 | Build DirWatcher locally (sets user **`RESEC_DW_EXE_LOCATION`** and **`LAB_DIRWATCHER_EXE`**), or set one of those env vars / `lab.local.json` `dirWatcherExe` if not under Program Files. Restart Lab Test Runner or open a new shell after the first build so User env is visible. |

## Tests

| # | Script | Ticket |
|---|--------|--------|
| 1 | `P0\DW-01-NCP7340-SourceMovedToTempOnSanitize.ps1` | NCP-7340 — incoming file must leave source within 10s; clean output on SMB dest (temp not asserted — short-lived). |
| 2 | `P0\DW-02-NCP7343-ProcessEmptyFolders.ps1` | NCP-7343 — **Process empty folders** → clean SMB output; phase 1 asserts incoming **retained** (delete after X min = 0); phase 2 asserts incoming removed via **Delete processed folders after X minutes** + periodic file check (default X=1, up to ~1 min test slack after threshold). |
| 3 | `P0\DW-03-NCP7345-DeleteProcessedFolderWithFile.ps1` | NCP-7345 — folder **with a file** under incoming; file sanitizes and leaves source; empty subfolder removed by **Delete processed folders after X minutes** + periodic file check (default X=1, same wait slack as DW-02). |
| 4 | `P0\DW-04-NCP7361-RejectedFileSavedOnFailure.ps1` | NCP-7361 - policy-blocked unknown fixture (`Fixtures\Blocked\NCP-7361\unknown-blocked.dat`) must land under **Rejected Folder** for behavior **0** (single folder) or **1** (by reason). Run behavior **1** explicitly: `-RejectedBehavior 1`. Script uses fixed 5s rejected / 2s clean waits (ignores Lab Test Runner timeout overrides). |

Example:

```powershell
cd C:\Work\ResecTech\Resec.LabTests
.\DirWatcher\P0\DW-01-NCP7340-SourceMovedToTempOnSanitize.ps1
.\DirWatcher\P0\DW-04-NCP7361-RejectedFileSavedOnFailure.ps1
.\DirWatcher\P0\DW-04-NCP7361-RejectedFileSavedOnFailure.ps1 -RejectedBehavior 1
```

For **version skew** regression (e.g. DW 26.2 + Core 26.1), deploy the trains under test, then run the same script — it does not pin versions; folder behavior is what it asserts.

## Policy

Tests import a lab policy via Core `importpolicies` (see `Common\DirWatcherE2eCorePolicy.ps1`), assign it to `dir_watcher`, restart DirWatcher (default), and wait for monitoring via DirWatcher **`connection.state`** on `/debug/hook` (fallback: `Monitoring folder:` in `C:\Resec\Logs\Directory Watcher`). Helpers: `Common\DirWatcherE2eAgentDebug.ps1`. Optional `-UseAgentCommNudge` runs Core `agentcommblockon/off` instead of relying on restart alone.

When a scenario **starts or restarts** DirWatcher (headless, no console), **`finally` teardown stops that process** so orphaned `DirWatcher.exe` instances do not linger. If DirWatcher was **already running** before the script began, teardown leaves it alone. Use **`-LeaveDirWatcherRunning`** to keep a scenario-started instance running for manual follow-up.
