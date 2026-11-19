# REST API client (Resec.Agent.RestAPI) — minimal functional test plan

**Goal:** few high-signal cases that cover how the REST API / RDP stack fails in the field, including **v2** (Gateway/RDP) and **v3** (Votiro-compatible disarmer) surfaces from [Swagger UI](https://127.0.0.1:8443/swagger/index.html).

| Tier | Cases |
|------|------:|
| P0 release gate | 3 |
| P1 pre-release | 6 |
| P2 lab / occasional | 2 |

Each substep has **Do** (exact actions) and **Expect** (pass criteria). Run A, B, … in order in one lab session when you can.

## Lab setup (once per session)

1. Core running; `AppSettings:EnableDebugInterface` = true (policy import / `agentcommblockon|off`).
2. WMC → REST API deployment **Connected**; policy rule `agent_type` = `rest_api` (E2E default: `RA-01-rest-api-lab` via `RestApi\Common\RestApiE2eCorePolicy.ps1`).
3. Set `RESEC_RESTAPI_EXE_LOCATION` to built or installed `Resec.Agent.RestAPI.exe`; HTTPS listener default **8443** (`RestApiE2eDefaultHttpsBase` = `https://127.0.0.1:8443`).
4. Lab auth header: `AuthorizationToken: SWFtOlRva2Vu` (or WMC-configured API key — see **API keys** in P1).
5. Open Swagger → definition **Rest API v2** and **Rest API v3**; confirm path list matches tables in **API surface** below.
6. HKLM `SOFTWARE\Resec Technologies`: note `ServerAddress` / `ServerPort` (11073); use **COMPUTERNAME**, not `localhost`, for remote-Core regressions (NCP-7372).

## API surface (Swagger baseline)

**v2** — regression & RDP

| Method | Path |
|--------|------|
| GET | `/api/v2/IsConnected` |
| GET | `/api/v2/entraLoginConfig` |
| GET | `/api/v2/GetPolicyList` |
| GET | `/api/v2/getPolicyPart` |
| POST | `/api/v2/authenticateUser` |
| POST | `/api/v2/logout` |
| POST | `/api/v2/sync/sanitization` |
| GET | `/api/v2/sync/sanitization/{id}` |
| GET | `/api/v2/sync/abortRequest/{abortToken}` |
| POST | `/api/v2/async/sanitization` |
| GET | `/api/v2/async/sanitization/{uuid}` |
| GET | `/api/v2/async/sanitization/{uuid}/file` |
| POST | `/api/v2/sanitization/{uuid}/submitFilesData` |
| POST | `/api/v2/submitUrl` |
| GET | `/api/v2/sanitization/{uuid}/detailedOutcome` |
| GET | `/api/v2/sanitization/{sanitizationId}/detailedOutcome` |
| GET | `/api/v2/sanitization/{uuid}/filesData` |

**v3** — Votiro-compatible (NCP-7216)

| Method | Path |
|--------|------|
| GET | `/api/v3/about` |
| POST | `/api/v3/upload` |
| POST | `/api/v3/upload-sync` |
| GET | `/api/v3/status/{requestId}` |
| GET | `/api/v3/report/{requestId}` |
| GET | `/api/v3/download/{requestId}` |
| GET | `/api/v3/abort/{abortToken}` |

## Common actions

| Action | Do this |
|--------|---------|
| **REST call** | Swagger *Try it out*, `Invoke-RestMethod`, or Postman to `https://127.0.0.1:8443` with header `AuthorizationToken`. PS 5.1: dot-source `RestApi\Common\RestApiE2eBootstrap.ps1` and use `Enable-RestApiE2eTlsBypass`. |
| **Verify WMC** | WebMC → **Sanitizations**: filter REST API deployment; check **Status**, **Policy**, **User and domain**, download/submit URL tags when applicable (NCP-7266). |
| **Verify agent online** | `GET /api/v2/IsConnected` → `true`; WMC deployment **Connected**; log `Communicator::Connect` with expected `serverAddresses`. |
| **Check temp folders** | Policy temp root (+ `D:` variant for NCP-6133); after successful jobs, inbound/working subfolders **0** when idle (NCP-5426 class). |
| **Core commdown** | `POST https://localhost:4504/debug/hook?command=agentcommblockon` (~10–30s) then `agentcommblockoff` — `CoreE2eDebugHook.ps1`. |
| **Change REST policy** | WMC → edit REST API policy → **Save**; send another sanitization without restarting agent (NCP-6920 / NCP-6491 stale-policy window). |
| **Listen port check** | `Test-NetConnection -ComputerName 127.0.0.1 -Port 8443` every few minutes during long polls. |

---

## How to run tiers

- **P0** — every REST API build (~2–3h).
- **P1** — before customer release or when touching Gateway, sanitization jobs, auth, tags, HTTPS, v3 upload/download, policy apply.
- **P2** — v3 retention, multi-key auth, version skew, optional non-`C:` temp.
- **Automated:** `RestApi\P0\RA-01-NCP7372-RegistryCoreEndpoint.ps1` = **RA-01 A–C** (registry + connect log + `IsConnected`).

---

## P0 — release gate

| # | ID | Steps | Pass |
|---|-----|-------|------|
| 1 | RA-01 | **Smoke, HTTPS & Core binding** —<br><br>**A.** **Do:** Start **Resec.Agent.RestAPI** (service or exe); tail `C:\Resec\Logs\RestApi\log-*.log`; open Swagger **v2**. **Expect:** Kestrel listening on **8443** with HTTPS (NCP-6537); no startup crash from config/serialization (NCP-5984); `Test-NetConnection` to 8443 succeeds.<br><br>**B.** **Do:** Set HKLM `ServerAddress` = **COMPUTERNAME** (not `localhost`); restart REST API; grep log for `Communicator::Connect`. **Expect:** `serverAddresses` contains computer name, not spurious localhost-only when remote Core is intended (NCP-7372); or run `RA-01-NCP7372-RegistryCoreEndpoint.ps1`.<br><br>**C.** **Do:** `GET /api/v2/IsConnected` with valid `AuthorizationToken`. **Expect:** Body `true`; WMC shows REST deployment connected; repeated GET does not crash process (NCP-6225).<br><br>**D.** **Do:** `GET /api/v2/IsConnected` with missing/wrong token. **Expect:** **401** or documented error — not **500** / process exit.<br><br>**E.** **Do:** Stop Core; within 60s call `IsConnected` 3×; restart Core without restarting REST API; poll `IsConnected` up to 3 min. **Expect:** Agent stays up; `IsConnected` returns `true` after Core is healthy (NCP-5357 retry class); no unhandled exception in log. | All **Expect** met. |
| 2 | RA-02 | **v2 sync & async sanitization** —<br><br>**A.** **Do:** `POST /api/v2/sync/sanitization` multipart with `Fixtures\Office\NCP-7344\simple.docx` or `simple.xlsx`; include policy part from `GET /api/v2/GetPolicyList` / lab default. **Expect:** **200** with terminal outcome **Pass** (or policy-documented block); WMC row for REST API with correct policy name (NCP-5895 user identity when RDP auth used).<br><br>**B.** **Do:** Repeat sync upload **without** optional `Tags` header (NCP-6560). **Expect:** **200** or clear **400** — not **500** NullReference.<br><br>**C.** **Do:** `POST /api/v2/async/sanitization` same file; poll `GET /api/v2/async/sanitization/{uuid}` until terminal state; download `GET .../file` if Pass. **Expect:** Status leaves **Running** within policy timeout (NCP-6301 / CC-1057); downloaded bytes match sanitized output; WMC not stuck **Running** forever.<br><br>**D.** **Do:** Submit `Fixtures\Blocked\Infected\eicar.b65` async. **Expect:** Terminal **Blocked**/**Fail** with message; client receives completed job, not hung poll.<br><br>**E.** **Do:** After **C** or **D**, **Check temp folders**. **Expect:** Working directories empty when idle (NCP-5426). | All **Expect** met. |
| 3 | RA-03 | **Resilience & policy** —<br><br>**A.** **Do:** Start async job (**RA-02 C**); during **Running**, Core **agentcommblockon** 15s then off; continue poll. **Expect:** Job completes or fails with visible comm outcome — agent process survives; `IsConnected` true after recovery.<br><br>**B.** **Do:** Send **5** async jobs in parallel; **restart** REST API service once mid-flight; wait for all terminal WMC states. **Expect:** No permanent **Running** orphans; log free of task double-complete crashes (NCP-6319 class on shared Gateway code paths).<br><br>**C.** **Do:** Change material REST policy facet (e.g. blocked extension list); **Save**; submit sync file without restarting agent. **Expect:** New behavior on next job within reasonable window (not 10+ min stale — NCP-6491 / NCP-6920); agent remains connected.<br><br>**D.** **Do:** Edit policy in WMC → save → watch agent log once. **Expect:** Single apply sequence, not endless repeat (NCP-6993 logging/policy apply). | All **Expect** met. |

---

## P1 — pre-release

| # | ID | Steps | Pass |
|---|-----|-------|------|
| 1 | RA-10 | **Auth, Entra & session** —<br><br>**A.** **Do:** `GET /api/v2/entraLoginConfig` (NCP-6563). **Expect:** JSON config matches WMC Entra settings or empty/disabled when not configured.<br><br>**B.** **Do:** `POST /api/v2/authenticateUser` with lab card/user matrix; then submit sync sanitization. **Expect:** WMC **User and domain** populated; Core log shows auth success aligned with client (NCP-6425 / CC-1112 — no spurious login failure).<br><br>**C.** **Do:** `POST /api/v2/logout`; repeat sanitization without re-auth when policy requires user. **Expect:** Documented challenge or block — session cleared, not silent wrong user (NCP-6171).<br><br>**D.** **Do:** `POST /api/v2/authenticateUser` with bad credentials. **Expect:** Clear failure response (NCP-6554 — not hang with no backend indication). | All **Expect** met. |
| 2 | RA-11 | **submitUrl, tags & WMC details** —<br><br>**A.** **Do:** `POST /api/v2/submitUrl` with allowed HTTPS lab URL + `Tags` JSON including submit/download URL tags. **Expect:** WMC sanitization details show **User And Domain** and **Download URL** where configured (NCP-7266).<br><br>**B.** **Do:** `POST /api/v2/sanitization/{uuid}/submitFilesData` for encrypted archive `Fixtures\Blocked\Encrypted\1111.7z` (password once). **Expect:** At most **one** password prompt cycle per file (NCP-6513); invalid password allows retry (NCP-6571).<br><br>**C.** **Do:** Sync upload with `Tags` including client IP facet (NCP-6564). **Expect:** Tags visible in WMC / detailed outcome. | All **Expect** met. |
| 3 | RA-12 | **Outcomes & abort** —<br><br>**A.** **Do:** After Pass async job, `GET /api/v2/sanitization/{uuid}/detailedOutcome` and `GET .../{sanitizationId}/detailedOutcome` (NCP-7095). **Expect:** JSON includes outcome fields needed for integrations; IDs consistent with WMC.<br><br>**B.** **Do:** `GET /api/v2/sanitization/{uuid}/filesData` on job with embedded children. **Expect:** Embedded file list correct (NCP-6642 log/data class).<br><br>**C.** **Do:** Start long async job; call `GET /api/v2/sync/abortRequest/{abortToken}` from create response (NCP-5985). **Expect:** Job reaches **Aborted**/terminal within timeout; no Gateway deadlock. | All **Expect** met. |
| 4 | RA-13 | **Policy parts & blocks** —<br><br>**A.** **Do:** `GET /api/v2/getPolicyPart` for portal/password facet used by RDP. **Expect:** Payload matches WMC; blocked-file message present when applicable (NCP-6561 **BlockedFileMessage**).<br><br>**B.** **Do:** Trigger policy block; read async poll body. **Expect:** Friendly blocked outcome text (NCP-7196), not raw exception string.<br><br>**C.** **Do:** `GET /api/v2/GetPolicyList`. **Expect:** List includes assigned REST policy; agent does not attach wrong agent-type profile (NCP-5333 DW-profile class). | All **Expect** met. |
| 5 | RA-14 | **Capacity, temp & HTTPS** —<br><br>**A.** **Do:** Sync-sanitize large fixture (> policy “large file” threshold, NCP-6991). **Expect:** Completes or documented async handoff — not `destination access denied` timeout on valid temp.<br><br>**B.** **Do:** *(If lab allows)* Point REST policy temp to **`D:\Resec\RestApiTemp`**; run **RA-02 C**; **Check temp folders**. **Expect:** Pass path works off `C:` (NCP-6133 / CC-997).<br><br>**C.** **Do:** Verify `appsettings.json` HTTPS certificate binding; restart agent. **Expect:** Listens TLS without manual cert hack (NCP-6537); save path failures do not return success (NCP-6334). | All **Expect** met. |
| 6 | RA-15 | **v3 disarmer API** —<br><br>**A.** **Do:** Swagger **v3** → `GET /api/v3/about`. **Expect:** Version/build metadata; documents upload flow.<br><br>**B.** **Do:** `POST /api/v3/upload` multipart clean file; poll `GET /api/v3/status/{requestId}` until done; `GET /api/v3/report/{requestId}`; `GET /api/v3/download/{requestId}`. **Expect:** End-to-end Pass; report reflects Core data (NCP-7216); download retained until fetched per policy (v3 retention fix).<br><br>**C.** **Do:** `POST /api/v3/upload-sync` with small file. **Expect:** Single response with terminal status.<br><br>**D.** **Do:** Start v3 async upload; `GET /api/v3/abort/{abortToken}`. **Expect:** Terminal abort; no async cancel race (af46d3f / v3 abort).<br><br>**E.** **Do:** v3 upload blocked file. **Expect:** Report shows block; download behavior matches Votiro-compatible contract. | All **Expect** met. |
| 7 | RA-16 | **Interrupted upload** —<br><br>**A.** **Do:** Begin `POST /api/v2/async/sanitization` with a **large** multipart upload (large team fixture or client-side throttle); when transfer is roughly **halfway**, **cut the client connection** (cancel request, close socket, or kill the uploading process). Wait 2 min idle; **Check temp folders** and WMC. **Do:** Submit the **same** file again via a **complete** `POST /api/v2/async/sanitization` and poll to terminal state. **Expect:** Aborted upload yields **no** permanent WMC **Running** orphan and **no** agent crash; `GET /api/v2/IsConnected` still **true**; temp folders **0** when idle after the wait; the second upload completes with a normal terminal outcome (**Pass**/**Fail**/**Blocked**) — not an indefinite poll. | All **Expect** met. |

---

## P2 — occasional

| # | ID | Steps |
|---|-----|-------|
| 1 | RA-20 | **API keys & platform** —<br><br>**A.** **Do:** Configure **multiple API keys** in WMC system property (NCP-5048 / NCP-5903); call `IsConnected` and one sanitization with each key. **Expect:** All keys accepted; invalid key rejected.<br><br>**B.** **Do:** Install previous-train REST API against current Core; run **RA-02 A** sync. **Expect:** WMC Pass.<br><br>**C.** **Do:** Compare Swagger **v2** and **v3** operation count to this doc **API surface** table after upgrade. **Expect:** No undocumented removed routes without release notes.<br><br>**D.** **Do:** *(When NCP-7384 implemented)* Inspect health/UI for **service token expiration** warning before expiry. **Expect:** Alert visible within configured lead time. |
| 2 | RA-21 | **Encoding & misc regressions** —<br><br>**A.** **Do:** Sync upload file with **URL-encoded Hebrew** (or other non-ASCII) filename (NCP-2779). **Expect:** WMC and download name decoded correctly.<br><br>**B.** **Do:** `getPolicyPart` after policy edit requiring RDP exclusion facet (NCP-6633 / CC-1204 workaround class). **Expect:** Client honors exclusion without crash.<br><br>**C.** **Do:** Guest / `promptForUserOnFirstConnection` matrix if enabled (NCP-6661). **Expect:** Login UI completes — no infinite hang. |

---

## Fixtures (one kit)

| Batch | Contents |
|-------|----------|
| Positive | `Fixtures\Office\NCP-7344\simple.docx`, `simple.xlsx`; `Fixtures\Allowed\Passed\interface vlan shutdown.txt` |
| Negative | `Fixtures\Blocked\Infected\eicar.b65`; `Fixtures\Blocked\FileTypeNotAllowed\` sample |
| Encrypted | `Fixtures\Blocked\Encrypted\1111.7z`, password-protected office from same tree |
| Large | Team “large file” fixture or generated file above policy threshold |
| v3 | Same positive PDF/DOCX for `upload` / `upload-sync` |

Policy toggles for session: block vs remove, CDR on/off, temp path on `D:`, Entra login, API key rotation.

### Temp folder check (after deliver)

| Area | Expect when idle after Pass |
|------|----------------------------|
| Policy temp inbound/working | **0** files |
| Failed/quarantine (if configured) | Only when testing failure (RA-02 D, RA-14) |

---

## Regression map (Jira + GitHub, ~1 year)

Use when scoring risk for a build touching `Resec.Agent.REST_API` ([commits](https://github.com/ResecTech/Resec.Agent.REST_API/commits)).

| Ticket | Theme | Covered in |
|--------|--------|------------|
| NCP-7372 | Registry `ServerAddress` → wrong Core | RA-01 B, automated RA-01 |
| NCP-6225 | Crash on server connection | RA-01 C–E |
| NCP-6301 / CC-1057 | Async jobs never complete | RA-02 C |
| NCP-6920 | Disconnect after policy change | RA-03 C |
| NCP-6491 | Stale policy ~10 min | RA-03 C |
| NCP-6537 | Missing HTTPS in appsettings | RA-01 A, RA-14 C |
| NCP-6560 | NRE when Tags omitted | RA-02 B |
| NCP-7266 | submitUrl tags / WMC details | RA-11 A |
| NCP-7095 | detailedOutcome endpoints | RA-12 A |
| NCP-7216 | v3 Votiro API | RA-15, API surface v3 |
| NCP-6133 / CC-997 | Temp on non-`C:` drive | RA-14 B |
| NCP-6425 / CC-1112 | RDP auth encoding | RA-10 B |
| NCP-6171 | Wrong user on sanitizations | RA-10 C |
| NCP-6513 / NCP-6571 | Encrypted file prompts | RA-11 B |
| NCP-6334 | Success when save fails | RA-14 C |
| NCP-5903 / NCP-5048 | Custom / multiple API keys | RA-20 A |
| NCP-5985 / v3 abort | Async abort races | RA-12 C, RA-15 D |
| NCP-7384 | Token expiration health *(pending)* | RA-20 D |

Representative GitHub fixes (same window): `0e3b41e` NCP-7372 registry; `733822d` NCP-6301 jobs; `b1d0788` NCP-6225 connection crash; `404c5c8` NCP-6560 Tags NRE; `6699b6f`/`76e738d` NCP-7216 v3; `af46d3f` v3 abort/cancel; `a0e622b` NCP-7266 submitUrl tags; `5b57e38` NCP-6133 temp drive.

---

## Out of scope

- Full RDP browser UI pixel checks (Google download quirks, tooltips — many NCP-65xx UI-only tickets)
- Linux REST API host soak (NCP-5886) on Windows-only lab
- 1000+ parallel upload flood
- WMC spinner / page load perf (NCP-7264)
- Jira CSV export automation

---

## References

- `Resec.LabTests\RestApi\README.md`
- `Resec.LabTests\RestApi\Common\RestApiE2ePs51.ps1`
- `Resec.Core.Server/docs/core-debug-api.md`
- Swagger: `https://127.0.0.1:8443/swagger/index.html` (definitions **Rest API v2**, **Rest API v3**)
- [Resec.Agent.REST_API](https://github.com/ResecTech/Resec.Agent.REST_API) · [Resec.LabTests](https://github.com/ResecTech/Resec.LabTests) `RestApi/`