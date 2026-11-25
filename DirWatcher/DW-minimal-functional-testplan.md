# Directory Watcher (Resec.Agent.DirWatcher) — minimal functional test plan

**Goal:** High-signal cases that cover how Directory Watcher fails in the field, with **no duplicate scenarios**. Mapped from QTest **`DW_TestCases.xlsx`**, Jira (last 12 months), and [Resec.Agent.DirWatcher](https://github.com/ResecTech/Resec.Agent.DirWatcher) commits.

| Tier | Plan IDs | Scripts |
|------|----------|--------:|
| P0 release gate | 3 | 3 |
| P1 pre-release | 2 | 2 |
| P2 extended | 1 | 1 |
| **Total** | **6** | **6** |

Each **plan ID = one script**. Phases **A, B, …** run **in order** inside that script. Every phase has **Do** (setup and actions) and **Expect** (assertions). Outcomes are verified via **incoming / temp / clean / rejected folders**, **DirWatcher log** (`log-DirWatcher*.log`), and debug hooks **`connection.state`** / **`tracking.state`** on port **4506** (not WebMC UI).

### Merge map (what was consolidated)

| New ID | Replaces | Rationale |
|--------|----------|-----------|
| **DW-01** | Old DW-01 + DW-02 | Single ingest lifecycle script |
| **DW-02** | Old DW-03 + DW-11 **A** | All reject modes with other policy facets |
| **DW-03** | Old DW-04 + DW-14 | Resilience + job observability on same runs |
| **DW-10** | Old DW-10 + DW-11 **B–C** | Paths/write + delay + multipolicy |
| **DW-11** | Old DW-12 + DW-13 | Relay, parallel, profiles, open files |
| **DW-20** | Old DW-20 + DW-21 | Skew, soak, 1K bulk |

## Lab setup (once per session)

1. Core running with `AppSettings:EnableDebugInterface` = true (`https://localhost:4504/debug/hook`).
2. `pushpolicystate` → `importpolicies` (lab DW policy) → assign `agent_type` = `dir_watcher` → restart DW or comm nudge.
3. Note policy paths: **incoming root**, **DW temp**, **rejected root**, **clean destination** (local or SMB).
4. `DIRWATCHER_ENABLE_DEBUG_INTERFACE=true`; optional `lab.local.json`: `dirWatcherExe`, `coreClusterAddresses`, `coreClusterFailoverAddress`.
5. Fixtures under `Resec.LabTests\Fixtures\` (e.g. `FileTypeDetection\sample.txt`, `Blocked\NCP-7361\unknown-blocked.dat`).

---

## How to run

| Tier | When | Scripts |
|------|------|---------|
| **P0** | Every DW build (~2.5h) | **DW-01** → **DW-02** → **DW-03** |
| **P1** | Pre-release | **DW-10**, **DW-11** as needed |
| **P2** | Nightly / RC | **DW-20** |

### Plan ID ↔ script

| ID | Script |
|----|--------|
| DW-01 | `DirWatcher\P0\DW-01-IngestLifecycleAndConnect.ps1` |
| DW-02 | `DirWatcher\P0\DW-02-PolicyFacets.ps1` |
| DW-03 | `DirWatcher\P0\DW-03-ResilienceAndObservability.ps1` |
| DW-10 | `DirWatcher\P1\DW-10-PathsTimingAndWrite.ps1` |
| DW-11 | `DirWatcher\P1\DW-11-RelayProfilesAndOpenFiles.ps1` |
| DW-20 | `DirWatcher\P2\DW-20-SkewSoakAndBulkGate.ps1` |

### Traceability — QTest ↔ plan

| QTest `case_id` | Title (abridged) | Phase |
|-----------------|------------------|-------|
| 153 | Connection to all cluster servers | DW-01 A |
| 189 | Same file twice (short period) | DW-01 E |
| 190 | Same file in temp and root | DW-01 B |
| 165 | Rejected files save modes | DW-02 C–E |
| 185, 196 | Empty folders | DW-02 A–B |
| 193 | Periodic File Check Stop Regex | DW-02 F |
| 257 | Proceed after server restart | DW-03 B |
| 261 | Reconnect to another cluster machine | DW-03 C |
| 184, 198 | Process pre-existing files | DW-10 A |
| 186, 197 | Ignore empty files | DW-10 B |
| 187–201, 199, 200 | Overwrite on write | DW-10 C |
| 202–204, 203 | Modify sanitized file time | DW-10 D |
| 194 | Delay processing files | DW-10 E |
| 192 | Replace user by subfolder | DW-10 F |
| 188 | Sanitization using DW as relay | DW-11 A |
| 847 | Parallel folders monitoring | DW-11 B |
| 258 | Parallel monitoring, kill DW in turn | DW-11 C |
| 160 | Profile limitations | DW-11 D |
| 164 | Scanning of an opened file | DW-11 E |
| 214 | Client vs new server compatibility | DW-20 A |
| 191 | New file every minute × 12h | DW-20 D |

---

## P0 — release gate

### DW-01 — Connect + ingest lifecycle

**Script:** `P0\DW-01-IngestLifecycleAndConnect.ps1`  
**Themes:** QTest **153**, **189**, **190**; NCP-6372, 6595, 7126, 7340, 7370, 7375, 7376, 6828

| Phase | Do | Expect |
|-------|-----|--------|
| **A — Connect & monitoring** | 1. `pushpolicystate`; import DW lab policy with known **incoming** path.<br>2. Set HKLM **Server address** to `coreClusterAddresses` from lab config (semicolon-separated Core host:port list — use real lab URLs, not accidental localhost-only).<br>3. Start DirWatcher with `DIRWATCHER_ENABLE_DEBUG_INTERFACE=true` (or restart service after registry change).<br>4. Poll `GET …4506/debug/hook?command=connection.state` until stable.<br>5. Optional: reconnect test — restart DW 2–3 times and confirm hook still reaches a cluster member (QTest **153** rotation smoke). | Process starts with no unhandled exception (NCP-6595). Log shows Gateway **Authenticated** (not stuck reconnect loop). `connection.state`: `coreConnectionStatus` = **Authenticated** (or `coreConnected` true); `directoryWatcherPhase` = **Monitoring**; `monitoringRootFolders` includes the policy **incoming** path. Active Core matches registry / connect log (NCP-6372). Policy applied once per connect cycle (no endless re-apply spam). |
| **B — Startup: same file in incoming + temp** | 1. **Stop** DirWatcher.<br>2. Copy one fixture (e.g. `sample.txt`) to **both** policy **incoming** and policy **DW temp** with the **same file name**.<br>3. Re-import or ensure **Process pre-existing files** = on for this policy.<br>4. Start DirWatcher; write `logmark` for this phase.<br>5. Watch incoming path until file leaves source. | Exactly **one** sanitize completes: file appears on **clean destination** with same basename. **Incoming** copy of the file is cleared. **Temp** is **empty** within the configured timeout after pass (no stale duplicate, no `file_1` staged name). **Not** two passes / two outcomes for one logical file (NCP-7375; QTest **190**). |
| **C — Source cleared on sanitize start** | 1. With DW still monitoring, place a **new unique** clean fixture in **incoming** only (new GUID in filename).<br>2. Within **10 seconds** of processing start, poll `Test-Path` on the exact drop path.<br>3. Wait for file on **clean** SMB/local destination.<br>4. Scan DW log slice after `logmark` for this drop. | **Incoming drop path** becomes absent while job is in flight (NCP-7340). Clean output exists and opens/readable. Log contains success outcome (`HandleScannedFile: … outcome:`). Log has **no** line containing **`duplicate final outcome`** (NCP-7370). Outcome is logged (job actually ran — NCP-7126 smoke). |
| **D — Tracking idle** | 1. After phase **C** completes, wait until DW is idle (no files in incoming for that subtree).<br>2. `GET …4506/debug/hook?command=tracking.state&message=<incoming drop path>`. | `tracking.state` shows no stuck **in-flight** entry for that path; no mapper warning spam. Policy **temp** folder has no completed work left behind (only empty or legitimately in-flight if another job runs). |
| **E — Same file dropped again from root** | 1. After phase **C** pass, copy the **same bytes** / same basename again to the **incoming root** (not a subfolder).<br>2. Wait for second clean output.<br>3. Assert incoming cleared again. | Second full pass: second clean artifact (or overwrite per policy); second outcome in log; source clears again (NCP-7376; QTest **189**). |
| **F — Rapid re-drop (dedupe)** | 1. New unique basename under incoming.<br>2. Run **two** `Copy-Item` to the **same full path** within **5 seconds**.<br>3. Count `HandleScannedFile` outcomes for that basename in the log slice. | **One** logical sanitize outcome for the rapid double copy (NCP-6828). Not two independent success outcomes for a single logical drop. |
| **G — DW restart + second drop** | 1. Stop and start DirWatcher process (same registry, no edit).<br>2. Confirm `connection.state` → monitoring again.<br>3. Drop another clean file. | Monitoring resumes without manual registry fix. Second file reaches **clean** destination with pass outcome in log. |

**Pass DW-01:** All phase **Expect** rows satisfied.

---

### DW-02 — Policy facets (folders, delete, reject, regex)

**Script:** `P0\DW-02-PolicyFacets.ps1`  
**Themes:** QTest **165**, **185**, **193**; NCP-7343, 7345, 7361, 7377, 6083

| Phase | Do | Expect |
|-------|-----|--------|
| **A — Process empty folders** | 1. Import policy: **Process empty folders** = on; **Delete processed folders after X minutes** = 0 for first sub-phase (incoming retained).<br>2. Create an **empty** folder tree under incoming (e.g. `empty-branch\leaf\`).<br>3. Start or nudge DW; wait for periodic / OsHook processing.<br>4. Repeat variant with **Delete after X** = 1 + periodic check enabled; wait threshold + lab slack (~1 min). | Empty structure replicated to **clean destination** (NCP-7343, **6083**, QTest **185**). With delete=0: empty folder may remain under incoming after dest copy. With delete+X+periodic: incoming empty folder tree removed per facet. |
| **B — Delete processed folder with file** | 1. Import policy with **Delete processed folders after X minutes** (e.g. X=1) and periodic file check on.<br>2. Under incoming, create subfolder with **one small file** inside.<br>3. Wait for file sanitize and folder age past threshold. | File reaches **clean** dest; file leaves incoming path. **Empty subfolder** under incoming is removed by periodic cleanup (NCP-7345). |
| **C — Rejected: save to single folder (0)** | 1. Import policy: **Unknown File** blocked (or equivalent); **Rejected File Behavior** = **0** (single folder).<br>2. Drop `Fixtures\Blocked\NCP-7361\unknown-blocked.dat` into incoming.<br>3. Wait bounded time for reject handling. | **No** file on **clean** destination. File appears under policy **rejected root** (flat). Failure outcome in log (NCP-7361; QTest **165** mode 1). |
| **D — Rejected: save by reason (1)** | 1. Re-import with **Rejected File Behavior** = **1**.<br>2. Drop same blocked fixture again. | File under rejected tree in **reason-named subfolder** (QTest **165** mode 2). Still not on clean dest. |
| **E — Rejected: don't save (3)** | 1. Re-import with **Don't Save**.<br>2. Drop blocked fixture. | Sanitization **fails** (outcome in log / no clean output). **No** file anywhere under rejected folder. |
| **F — Periodic stop regex** | 1. Import: **Periodic File Check Stop Regex** = pattern matching `stop` (e.g. `.*\\stop.*`); **Process pre-existing** off if required by lab script.<br>2. Place clean files under `incoming\allow\` and under `incoming\stop\`.<br>3. Start DW or wait for periodic scan. | Files under **`stop`** never appear on clean dest. Files under **allow** pass normally (NCP-7377; QTest **193**). |

**Pass DW-02:** All phase **Expect** rows satisfied.

---

### DW-03 — Resilience, bulk smoke, observability

**Script:** `P0\DW-03-ResilienceAndObservability.ps1`  
**Themes:** QTest **257**, **261**; NCP-6630, 7385, 7348, 6455, 6301, 6225

| Phase | Do | Expect |
|-------|-----|--------|
| **A — Bulk + comm drop (smoke)** | 1. Import standard DW lab policy under fresh work root.<br>2. Stage **8** small unique files in incoming (script may generate tree).<br>3. While copies still running or immediately after, call Core `agentcommblockon`, hold **10–30 s**, then `agentcommblockoff`.<br>4. Wait until all basenames exist on **clean** dest or timeout.<br>5. If `-AssertNoOrphanJobContext`, grep DW/Core log for orphan JobContext. | All **8** files sanitized (NCP-7385 / **6455** class). No permanent stuck **File content required** state for this smoke count. No orphan JobContext when assertion enabled. *(Full **1000** file gate lives in DW-20 E.)* |
| **B — Core restart, DW keeps running** | 1. Leave DirWatcher **running**.<br>2. Stop Core process; wait for `command=ready` = false / hook down.<br>3. Start Core again; wait `coreInitialized=true`.<br>4. **Do not** restart DW.<br>5. Drop one clean file to incoming.<br>6. Optional: WMC REST `sanitizations/details` for that job window. | After Core is back, `connection.state` shows DW connected again. Drop reaches **clean** dest without restarting DW (NCP-6630; QTest **257**). REST/detail shows **terminal completed** state, not perpetual Running (NCP-6301). |
| **C — Cluster failover** *(optional)* | 1. If `lab.local.json` defines `coreClusterFailoverAddress`: stop primary Core; set HKLM to list with **survivor first**; restart DW or wait for reconnect.<br>2. Drop clean file.<br>3. If no second Core in lab, script logs **SKIP** and continues. | When configured: DW sanitizes via surviving Core (QTest **261**). When skipped: phase marked skipped, script does not fail. |
| **D — Policy log path** | 1. `importpolicies` with **Directory Watcher log path** facet set to a dedicated folder (not default `C:\Resec\Logs\…`).<br>2. Apply policy to DW; run one sanitize.<br>3. List `*.log` in configured folder; optional `logpath` DW hook. | New log lines for that run appear under **configured path** (NCP-7348), not only default install log directory. |
| **E — REST agent during Core outage** *(if REST in lab)* | 1. During phase **B** Core downtime/restore window, poll REST `GET /api/v2/IsConnected` (or health endpoint).<br>2. After Core up, confirm DW job still observable. | REST process does not crash (NCP-6225). `IsConnected` returns true after Core restore when agent is configured. |

**Pass DW-03:** All non-skipped phase **Expect** rows satisfied.

---

## P1 — pre-release

### DW-10 — Paths, timing, write facets

**Script:** `P1\DW-10-PathsTimingAndWrite.ps1`  
**Themes:** QTest **184–204**, **194**, **192**; NCP-6072, 7315

| Phase | Do | Expect |
|-------|-----|--------|
| **A — Process pre-existing files** | 1. Import with **Process pre-existing files** = **off**.<br>2. Place clean files in incoming **before** starting DW.<br>3. Start DW; confirm no processing.<br>4. Turn facet **on** via re-import; restart or periodic rescan.<br>5. Repeat with **local→local** and **SMB→SMB** incoming/dest if lab provides both. | Files sit untouched until facet enabled + rescan/drop (QTest **184** / **198**). After enable, they sanitize. |
| **B — Ignore empty files** | 1. Import **Ignore empty files** = **off**; drop 0-byte + 1 MB file together.<br>2. Re-import with facet **on**; repeat mixed batch. | Off: both process. On: only non-empty reaches clean dest (QTest **186** / **197**). |
| **C — Overwrite on write** | 1. Pre-place a file on **clean** dest with known name.<br>2. Import **Overwrite existing file on write** = **on**; drop same name from incoming — test **local**, **SMB**, and **mapped** dest paths per lab layout.<br>3. Re-import with overwrite **off**; repeat. | On: destination file replaced in place. Off: new name variant on dest (e.g. suffix). SMB path completes without stored-file read errors (NCP-6072; QTest **187–201**, **199**, **200**). |
| **D — Modify sanitized file time** | 1. Note source `LastWriteTime` on PDF, Office, text, small archive.<br>2. Import facet **off**; sanitize; compare dest times.<br>3. Import facet **on**; sanitize; compare.<br>4. If relay dest in policy, repeat for relay path (QTest **203**). | Off: dest times match source. On: dest times ≈ sanitize time (Qtest **195**, **202–204**). |
| **E — Delay processing** | 1. Import **Delay processing files** = **10** seconds.<br>2. `logmark`; drop one file; capture first ingest log timestamp. | ~**10 s** between drop detection and ingest/sanitize start in log (QTest **194**). |
| **F — Multipolicy / user by subfolder** | 1. Import multipolicy rules mapping **2nd-level subfolder** → user/domain metadata.<br>2. Drop files under two different subfolder branches. | Job metadata / log shows **user** (or tag) matching each subfolder rule; original path preserved in audit fields (QTest **192**). |
| **G — Invalid destination store** | 1. Attempt `importpolicies` body with **empty or invalid SMB destination store name** (lab JSON). | Import fails clearly **or** DW on next connect logs **DestinationName** / store-missing error without silent broken monitoring (NCP-7315). |

**Pass DW-10:** All phase **Expect** rows satisfied.

---

### DW-11 — Relay, parallel, profiles, open files

**Script:** `P1\DW-11-RelayProfilesAndOpenFiles.ps1`  
**Themes:** QTest **160**, **164**, **188**, **258**, **847**; NCP-6617, 6068

| Phase | Do | Expect |
|-------|-----|--------|
| **A — DirWatcher as relay** | 1. Import relay policy bundle (incoming → relay DW staging → final SMB clean).<br>2. Drop clean file to primary incoming.<br>3. Tail relay DW log if separate instance. | File reaches final **clean** dest. Relay log shows staging paths. Main DW log does not sit in perpetual **init** during relay save (NCP-6617; QTest **188**). |
| **B — Parallel incoming roots** | 1. Import policy with **two distinct incoming roots** (parallel monitoring / AllowParallelMonitoring per product semantics).<br>2. Drop one file per root concurrently. | Both files reach correct destinations without cross-root deadlock (QTest **847**). |
| **C — Two DW instances, shared SMB incoming** | 1. Start **two** DirWatcher processes (different debug ports / `DIRWATCHER_E2E_DEBUG_BASE_URL`).<br>2. Both monitor **same** SMB incoming.<br>3. Kill instance A; continue drops; restart A; later kill B; drain queue. | Files eventually reach dest; surviving instance continues (QTest **258**; NCP-6068). Duplicates on dest acceptable per lab QTest note. |
| **D — Profile limitations** | 1. Import multiple assignment rules (user, group, computer, OU) using Core policy simulate pattern (NCP-7365 style).<br>2. Connect DW under each lab identity context. | Each context receives the **intended** policy id / facets (QTest **160**). |
| **E — Open file on share** | 1. Import **Process pre-existing files** = on.<br>2. Open **DOCX** on incoming SMB with exclusive `FileStream` (simulate user editor).<br>3. Start or continue DW monitoring.<br>4. Close stream; wait. | No sanitize while lock held (QTest **164** for DOCX). After close, file reaches clean dest. *(Document PDF may start earlier per QTest — record observed type.)* |

**Pass DW-11:** All phase **Expect** rows satisfied.

---

## P2 — extended

### DW-20 — Skew, soak, bulk gate

**Script:** `P2\DW-20-SkewSoakAndBulkGate.ps1`  
**Themes:** QTest **191**, **214**; NCP-6601, 6614, 6140, 7340

| Phase | Do | Expect |
|-------|-----|--------|
| **A — Previous train DW** | 1. Set `dirWatcherExe` (or env) to **previous release** build.<br>2. Run the same steps as **DW-01 C** (single drop, source clear, clean output). | Sanitize completes against **current** Core (QTest **214**). |
| **B — Version skew matrix** | 1. CI/env matrix (e.g. DW 26.1 + Core 26.2).<br>2. Re-run **DW-01 C** and **DW-02 A** (empty folder). | Source clears on sanitize (NCP-7340 regression). Empty folder behavior unchanged. |
| **C — Mapped / removable incoming** | 1. `subst` or lab mapped drive; point **incoming** facet at that drive letter.<br>2. Re-import; start DW. | `connection.state` lists root **or** log documents drive access check (NCP-6140). Monitoring does not silently skip configured root. |
| **D — 12-hour soak** | 1. Loop: copy new unique clean file every **60 seconds** for **12 hours** (parameterized shorter in dev).<br>2. Periodic `connection.state` / memory sample. | Every file on clean dest. No accumulating stuck **init** / **File content required** in logs (NCP-6614; QTest **191**). Process memory stable per lab threshold. |
| **E — 1000-file bulk gate** | 1. Run bulk helper with `BulkFileCount=1000`, early `agentcommblockon/off`, Gateway **≥ 26.2.115**.<br>2. Wait for full drain. | All outputs on clean dest; no stuck Running jobs in logs (NCP-6601). |

**Pass DW-20:** All phase **Expect** rows satisfied (or scheduled soak failure triaged separately).

---

## Regression coverage (last ~12 months)

| Key | Theme | Covered in |
|-----|-------|------------|
| NCP-7385 | Stuck File content required / bulk | DW-03 A, DW-20 E |
| NCP-7377 | Stop regex | DW-02 F |
| NCP-7376 | Re-drop root file | DW-01 E |
| NCP-7375 | Temp + source startup | DW-01 B |
| NCP-7370 | Duplicate final outcome | DW-01 C |
| NCP-7361 / reject modes | Rejected save | DW-02 C–E |
| NCP-7348 | Policy log path | DW-03 D |
| NCP-7340 | Source not cleared | DW-01 C, DW-20 B |
| NCP-7345 / 7343 | Folders | DW-02 A–B |
| NCP-6828 | Double processing | DW-01 F |
| NCP-6630 | Core restart | DW-03 B |
| NCP-6601 | 1K bulk | DW-20 E |
| NCP-6614 | Soak stuck | DW-20 D |
| NCP-6372 / 6595 / 7126 | Connect / start / ingest | DW-01 A, C |
| NCP-6072 / 7315 | SMB write / bad store | DW-10 C, G |
| NCP-6617 / 6068 | Relay / multi-DW | DW-11 A, C |
| NCP-6301 / 6225 | REST/WMC job health | DW-03 B–E |
| NCP-6140 | Mapped drive | DW-20 C |

---

## Out of scope

- Full production SMB ACL matrix, WMC UI-only checks, non-Windows DW host
- Exhaustive encrypted-office password UI (Scan Agent / Kiosk plan)
- NCP-6133 REST temp on D: — Rest API plan unless REST co-deployed

---

## Appendix — ticket P0 helpers → phases

| Helper | Phase |
|--------|--------|
| `DW-07-NCP7375-…` | DW-01 B |
| `DW-01-NCP7340-…` | DW-01 C |
| `DW-05-NCP7376-…` | DW-01 E |
| `DW-02-NCP7343-…` | DW-02 A |
| `DW-03-NCP7345-…` | DW-02 B |
| `DW-04-NCP7361-…` | DW-02 C–D |
| `DW-06-NCP7377-…` | DW-02 F |
| `DW-08-NCP7385-…` | DW-03 A (8 files), DW-20 E (1000) |

---

## References

- `Resec.LabTests/DirWatcher/Common/README.md`
- QTest: `DW_TestCases.xlsx`
- [Resec.Agent.DirWatcher](https://github.com/ResecTech/Resec.Agent.DirWatcher) commits