# DirWatcher lab E2E

PowerShell E2E scripts for **Resec Directory Watcher** against a lab Core with `/debug/hook` policy injection.

## Prerequisites

| # | Requirement |
|---|-------------|
| 1 | Core running with `EnableDebugInterface=True` (port 4504). |
| 2 | DirWatcher installed, registered to Core (process may be started by the test if not already running). |
| 3 | `config\lab.local.json` (optional `DirWatcher.repoRoot` for docs only). |
| 4 | Set `LAB_DIRWATCHER_EXE` if DirWatcher is not under Program Files. |

## Tests

| # | Script | Ticket |
|---|--------|--------|
| 1 | `P0\DW-01-NCP7340-SourceMovedToTempOnSanitize.ps1` | NCP-7340 — incoming file must leave source within 10s; clean output on SMB dest (temp not asserted — short-lived). |
| 2 | `P0\DW-02-NCP7343-ProcessEmptyFolders.ps1` | NCP-7343 — **Process empty folders** → clean SMB output; phase 1 asserts incoming **retained** (delete after X min = 0); phase 2 asserts incoming removed via **Delete processed folders after X minutes** + periodic file check (default X=1, up to ~1 min test slack after threshold). |
| 3 | `P0\DW-03-NCP7345-DeleteProcessedFolderWithFile.ps1` | NCP-7345 — folder **with a file** under incoming; file sanitizes and leaves source; empty subfolder removed by **Delete processed folders after X minutes** + periodic file check (default X=1, same wait slack as DW-02). |

Example:

```powershell
cd C:\Work\ResecTech\Resec.LabTests
.\DirWatcher\P0\DW-01-NCP7340-SourceMovedToTempOnSanitize.ps1
```

For **version skew** regression (e.g. DW 26.2 + Core 26.1), deploy the trains under test, then run the same script — it does not pin versions; folder behavior is what it asserts.

## Policy

Tests import a lab policy via Core `importpolicies` (see `Common\DirWatcherE2eCorePolicy.ps1`), assign it to `dir_watcher`, restart DirWatcher (default), and wait for `Monitoring folder:` in `C:\Resec\Logs\Directory Watcher` before dropping the fixture. Optional `-UseAgentCommNudge` runs Core `agentcommblockon/off` instead of relying on restart alone.
