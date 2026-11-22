# Email Agent (Resec.Agent.Mail) — minimal functional test plan

**Goal:** few high-signal cases that still cover how mail actually fails in the field. Ticket and legacy CSV mapping live outside this doc.

| Tier | Cases |
|------|------:|
| P0 release gate | 3 |
| P1 pre-release | 5 |
| P2 lab / occasional | 1 |

Each substep has **Do** (exact actions) and **Expect** (pass criteria). Run A, B, … in order in one lab session when you can.

## Lab setup (once per session)

1. Core running; `AppSettings:EnableDebugInterface` = true on Core (for policy import, `agentcommblock*`, and `dbsimulate*`).
2. Mail agent Windows service (or E2E auto-start) registered in WMC as mail relay; note **inbound SMTP port** and **temp folder** from policy.
3. Next hop points at **SimpleMailServer** capture port (default **127.0.0.1:26**) or customer relay lab equivalent.
4. Set `RESEC_MAIL_AGENT_EXE_LOCATION`; dot-source `Resec.LabTests\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1`.
5. Mail agent `appsettings.json` next to exe: `EnableDebugInterface` = true for debug hook on **4505**.

## Common actions

| Action | Do this |
|--------|---------|
| **Send one mail** | SMTP inject to **agent IP:port** (swaks, `SendBulkAttachmentMail.exe`, or sendmail). Use fixtures under `Resec.LabTests\Fixtures\Mail\E2eAttach\` or team `.eml` set. |
| **Verify delivery** | Open **SimpleMailServer** CLI inbox / next-hop capture; confirm subject/recipients/attachment. |
| **Verify WMC** | WebMC → **Mail sanitizations** (or Sanitizations): find message by time/subject; check **Status**, **Policy**, outcome. |
| **Verify agent online** | WebMC → **Deployments** (or Connected agents): mail deployment **Connected**; optional debug `status` → `coreConnectionStatus` = `Authenticated`, `inboundSmtpListening` = true. |
| **Check temp folders** | `GET http://127.0.0.1:4505/debug/hook?command=status` → `tempFolderRoot` + `tempFolderFileCounts`; or list subfolders under temp (see table below). |
| **Core commdown** | `GET https://localhost:4504/debug/hook?command=agentcommblockon` (hold N seconds) then `agentcommblockoff` — or run `Mail/P0/MA-01-SmokeAndInbound.ps1` (step **F1**; add `-IncludeMa02CLongCommdown` to chain `MA-02-C-NCP7307` long hold). |
| **Core DB unavailable (lab)** | `dbsimulateon` / `dbsimulateoff` (or `Set-CoreE2eDatabaseSimulation`) — blocks EF connection open only; MA-02 **E** enables this for the listen soak. |
| **Change mail policy** | WebMC → edit assigned mail policy → **Save**; watch agent log once for apply (no endless repeat). For SIR, CDR, per-recipient, filters: change facet → save → send test mail. |
| **Listen port check** | PowerShell `Test-NetConnection -ComputerName localhost -Port <smtpPort>` or external monitor script; repeat every few minutes. |

---

## How to run tiers

- **P0** — every mail-agent build (~3 sessions; ~2h).
- **P1** — before customer release or when touching SMTP, spool, Gateway, relay, policy, filters, health.
- **P2** — version skew / multi-Core registry occasionally.
- **Automated:** `Mail/P0/MA-01-SmokeAndInbound.ps1` — **MA-01** substeps **A–E** and **F1**; **MA-02 C** long commdown via `-IncludeMa02CLongCommdown`. **F2**, **F3**, **G**, **H** need WMC/lab prep (see script switches).
- **Automated:** `Mail/P0/MA-02-Resilience.ps1` — **MA-02** substeps **A–E** (use `-SkipStep*` for subsets). Step **C** calls `MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1`. Standalone **C**: `Mail/P0/MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1`.

---

## P0 — release gate

| # | ID | Steps | Pass |
|---|-----|-------|------|
| 1 | MA-01 | **Smoke & inbound** —<br><br>**A.** **Do:** Start **Resec.Agent.Mail** service; tail `log-Resec.Agent.Mail-*.log`; open WebMC deployment for this agent. **Expect:** Log shows Gateway **Authenticated**; **one** policy-apply sequence (no repeating apply spam); `Test-NetConnection` to SMTP port succeeds; WebMC shows agent connected.<br><br>**B.** **Do:** Set policy **Send Immediate Response** = **off**. SMTP-send **clean-sample** + PDF/DOCX fixture from `E2eAttach` to agent; capture on SimpleMailServer; open sanitization in WMC. **Expect:** WMC **Pass**; Resec signature in body on capture; attachment opens; run **temp folder check** (all 0).<br><br>**C.** **Do:** Send **one message** with 2+ recipients (To + CC or BCC) in envelope and headers. **Expect:** Capture shows all recipients; WMC recipient list matches.<br><br>**D.** **Do:** SMTP-send **EICAR** or **deny-hash** / policy-blocked attachment fixture. **Expect:** Sending client receives **5xx** (note code); if upstream is M365-like, mail trace shows **no** endless **450** retries.<br><br>**E.** **Do:** SMTP-send fixtures for **empty MAIL FROM** and **`MAIL FROM:<>`** (null reverse-path). **Expect:** SMTP response documented in client/session log (reject or accept per policy); message not silently dropped.<br><br>**F.** **Do:** (1) With mail in flight, run Core **agentcommblockon** ~10s then off — note SMTP code to sender. (2) Fill spool/session cap (parallel sends or NCP-7395 **overload**). (3) Point next hop at bad host; send one mail. **Expect:** **451** during Core block; **452**/4xx when capped (completed SMTP reply, not disconnect); **421** or visible failure for bad relay.<br><br>**G.** **Do:** Set policy **Send Immediate Response** = **on**; save; send clean mail; watch client SMTP dialog and agent log. **Expect:** **250**/early success before delivery finishes; mail still on next hop; grep log for `SemaphoreFullException` = none; **temp folder check** = 0.<br><br>**H.** **Do:** Set policy **process each recipient separately** = **on**; save; send **multi-recipient** mail from step C again; compare WMC job count vs bulk mode. **Expect:** Behavior matches facet (multiple sanitizations or splits if configured); all recipients served; **temp folder check** = 0. | All **Expect** met. |
| 2 | MA-02 | **Resilience** —<br><br>**A.** **Do:** With the mail agent idle, run **Check temp folders** (debug `status` or Explorer). **Expect:** SanitizationInput, SanitizationOutput, SmtpInboundSpool = **0**; SmtpFailed = **0** (unless you later run MA-14). *(Standalone step — not chained to MA-01.)*<br><br>**B.** **Do:** Send **5–10** mails quickly (`SendBulkAttachmentMail` or loop); wait until **at least some** sanitizations are non-terminal on Core (`GET /debug/hook?command=runningsanitizations&subjectContains=<burst prefix>`) or, without Core debug, agent-side in-flight signals (temp counts, `inboundSanitizationsInProgress`, SendBulk still sending). **Restart** mail agent Windows service **once** during that window; wait until the burst finishes; check folders. **Expect:** SendBulk completes without a stuck hang; agent returns **Authenticated** on debug `status`; no persistent SanitizationOutput lock errors in log; folders **0** when idle.<br><br>**C.** **Do:** Run `Mail/P0/MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1` (or manual commdown ≤30s and ≥30s while SMTP sending). After script ends, **Check temp folders** and **Listen port check**. **Expect:** Inbound got **451** during outage; port still listening; mail delivered to capture after recovery; folders **0**.<br><br>**D.** **Do:** Restart **Core** service (or **agentcommblockon** ≥5 min) **without** restarting mail agent; after Core is up, send one clean mail. **Expect:** Mail delivers without you manually restarting mail agent; debug `status` returns Authenticated.<br><br>**E.** **Do:** While Core **DB is unavailable** (`dbsimulateon` in automation, or real SQL maintenance), every **5 min** for 15 min run **Listen port check** on agent SMTP port (do not restart agent). **Expect:** Port remains open; if it fails, log as failure (NCP-7217 class). Script runs `dbsimulateoff` in `finally`. | All **Expect** met. |
| 3 | MA-03 | **Outbound & capacity** —<br><br>**A.** **Do:** In mail policy, set next hop list: entry 1 = dead IP:25, entry 2 = working SimpleMailServer; save; send clean mail; then set **only** dead hops; send again. **Expect:** First mail on capture; second shows failure in WMC and agent log (DAD/timeout text), not missing row.<br><br>**B.** **Do:** Configure next hop hostname with **TLS + certificate validation** per policy; point at lab TLS relay; send mail. **Expect:** Delivered; agent log shows TLS (no cert bypass errors).<br><br>**C.** **Do:** Lower spool/session limits in `appsettings.json` **MailProcessing** (lab only) or use debug **overload**; open **20+ parallel** SMTP sessions or rapid sequential sends until reject. **Expect:** New sessions receive SMTP **4xx**/**452** within seconds; agent process stays up; after stopping load, next single mail **Pass**.<br><br>**D.** **Do:** After **C**, WebMC → **System Health** → expand Core → **Agents** → expand mail deployment; note spool/disk rows. **Expect:** Spool utilization and disk status plausible (e.g. not **Degraded** disk on large volume with plenty of free GB). | All **Expect** met. |

---

## P1 — pre-release

| # | ID | Steps | Pass |
|---|-----|-------|------|
| 1 | MA-10 | **Attachments & enforcement** —<br><br>**A.** **Do:** Turn **CDR** on in mail policy; send PDF + DOCX fixture. **Expect:** Files on next hop open cleanly; signature in body.<br><br>**B.** **Do:** Send large **pptx** test deck (team fixture). **Expect:** WMC Pass; spot-check slides on next hop (not blank/broken deck).<br><br>**C.** **Do:** Send `.msg`, `.eml`, nested **zip/7z/rar** fixtures one at a time. **Expect:** Each reaches Pass or documented block in WMC.<br><br>**D.** **Do:** Same blocked-type attach with policy **Remove disallowed** vs **Block**; send twice. **Expect:** Remove: stripped/delivered per policy; Block: blocked outcome + correct notification.<br><br>**E.** **Do:** Add **blocked sender/domain** in policy; send from blocked then allowed address. **Expect:** Blocked fails/rejects; allowed delivers.<br><br>**F.** **Do:** Send mail that triggers **admin notification** on block; check admin mailbox count. **Expect:** Exactly **one** notification email.<br><br>**G.** **Do:** Send **password-protected zip** fixture; do not submit password. **Expect:** Sender SMTP **250**; user receives portal link only; no extra admin “blocked” messages to user/admins. | All **Expect** met. |
| 2 | MA-11 | **Routing & WMC** —<br><br>**A.** **Do:** Send two mails addressed to profiles that map to **different** assignment rules (different From/To per lab matrix). **Expect:** Each WMC row shows the correct **Policy** name.<br><br>**B.** **Do:** Run team **Invalid Recipients** `.eml` set through agent one file at a time. **Expect:** WMC status/outcome matches documented matrix for each file.<br><br>**C.** **Do:** Enable **To rewrite** / destination redirect facet; send to address that should rewrite. **Expect:** Capture shows rewritten recipient; WMC audit matches.<br><br>**D.** **Do:** Pick **held/blocked** mail in WMC → **Release**; pick another → **Resubmit**. **Expect:** Release arrives at original destination; Resubmit runs new sanitization.<br><br>**E.** **Do:** Enable **attachment summary** filename in policy; send mail with 2+ attachments. **Expect:** Outbound capture includes summary attachment with configured name. | All **Expect** met. |
| 3 | MA-12 | **Clients & load** —<br><br>**A.** **Do:** Send from Outlook desktop or OWA: HTML body, RTF, meeting invite; optional encrypted attach. **Expect:** WMC Pass; readable on next hop.<br><br>**B.** **Do:** Set mail service logon to **Local System**; restart service; send clean mail. **Expect:** Pass on next hop; no `NullReference` in agent log.<br><br>**C.** **Do:** `SendBulkAttachmentMail` or loop **30** small messages; watch Task Manager working set for agent process. **Expect:** All complete in WMC; memory returns near baseline; service running.<br><br>**D.** **Do:** WMC filter last hour → sort by status; search duplicate subjects/Message-Ids; note any **Running** >30 min. **Expect:** No duplicate Pass rows for same logical send; long runners fail or complete with visible outcome. | All **Expect** met. |
| 4 | MA-13 | **Inbound SMTP edge** —<br><br>**A.** **Do:** From lab host that **fails SPF** for envelope domain, send mail with **SPF block** enabled in agent settings/policy. **Expect:** Reject or block per config; agent log mentions SPF.<br><br>**B.** **Do:** Configure **recipient regex** filter in policy to allow only `*@labdomain`; SMTP RCPT TO one allowed and one denied address (same session or two). **Expect:** Allowed RCPT accepted; denied RCPT gets policy SMTP error.<br><br>**C.** **Do:** *(If LDAP facet configured)* Send from LDAP-allowed vs LDAP-denied sender. **Expect:** Allowed delivers path proceeds; denied blocked. *(Else skip.)*<br><br>**D.** **Do:** Enable **inbound TLS** on listener; connect with `openssl s_client -starttls smtp` or TLS-capable client; EHLO/MAIL/DATA minimal message. **Expect:** TLS handshake OK; message sanitizes like cleartext.<br><br>**E.** **Do:** Stop agent; copy **5** known-good `.eml` into `{temp}\SanitizationInput\`; start agent; wait 5 min idle. **Expect:** Files consumed; WMC shows sanitizations; **temp folder check** = 0. | All **Expect** met. |
| 5 | MA-14 | **Outbound failure & instrumentation** —<br><br>**A.** **Do:** Set all next hops invalid; send one mail; list `SmtpFailed` and outbound failure log folder from policy/appsettings. **Expect:** WMC failure/DAD; failure artifacts present where configured.<br><br>**B.** **Do:** Point next hop at **non-accepting** host (black-hole) or throttle; send one mail; wait up to **3 min**. **Expect:** WMC/log shows timeout (e.g. 120s class); upstream not stuck in infinite defer.<br><br>**C.** **Do:** Set `InboundSmtpLogs` / `OutboundSmtpLogs` **Enabled** true in agent appsettings; restart; send 3 mails; check recording folders size. **Expect:** New session files; total size under configured cap after cleanup interval.<br><br>**D.** **Do:** *(Optional)* Stop mail agent A; send via agent B in multi-agent lab; restore A. **Expect:** Document routing; no unexplained permanent loss in WMC. | All **Expect** met. |

---

## P2 — occasional

| # | ID | Steps |
|---|-----|-------|
| 1 | MA-20 | **Compatibility & debug** —<br><br>**A.** **Do:** Install previous-train mail agent MSI/exe against current Core; send clean mail. **Expect:** WMC Pass.<br><br>**B.** **Do:** Put 2 Core addresses in registry; stop reachable Core; confirm agent connects to other entry. **Expect:** Reconnect without manual edit. *(Skip if single Core.)*<br><br>**C.** **Do:** `telnet agent 25`, type `EHLO test`. **Expect:** Greeting/banner matches mail policy SMTP text.<br><br>**D.** **Do:** After 5 successful mails, `GET .../debug/hook?command=status` (and **stats** if available). **Expect:** Counts and connection fields match listener/port/folder reality. |

---

## Fixtures (one kit)

Paths are under `Resec.LabTests\Fixtures\` unless noted.

| Batch | Contents |
|-------|----------|
| Positive | `Mail\E2eAttach\clean-sample.txt`, `minimal-inbound.eml`; `Office\NCP-7344\simple.docx` (step **B** DOCX; PDF optional — add `Mail\E2eAttach\*.pdf` or use an Allowed/CDR PDF when policy permits) |
| Negative | `Blocked\Infected\eicar.b65` (step **D**); policy **deny-hash** needs a named hash rule + matching file (not in repo — add under `Blocked\` or document hash); `Blocked\FileTypeNotAllowed\sigcheck.exe` for block-by-type; step **E** uses raw SMTP `MAIL FROM:<>` |
| Edge | SPF-fail send path; regex/LDAP policy snippets documented in lab wiki |
| Portal | Password-protected zip |
| Infra | Dual next hop in policy; TLS relay; Core debug for commdown |

Policy toggles for session: SIR on/off, CDR, per-recipient, filters (MA-13), recording (MA-14).

### MA-01 automation (`Mail/P0/MA-01-SmokeAndInbound.ps1`)

| # | Item | Requirement |
|---|------|----------------|
| 1 | Core | `EnableDebugInterface` = true; steps **F1** use `agentcommblockon/off` |
| 2 | Mail agent | `EnableDebugInterface` = true on **:4505** (temp folders, step **A**) |
| 3 | Policy | E2E scripts import lab policy (Send Immediate Response off, next hop **127.0.0.1:26**, `mail_agent`); `-SkipCorePolicySetup` to manage policy yourself |
| 4 | Tools | `MAIL_E2E_*_EXE` or `C:\Resec\Mail Test Tools\` builds |
| 5 | WMC REST | Optional; default `resec_admin` / `resec_admin` for step **B** Pass check |
| 6 | Manual / skipped | **F2** spool cap, **F3** bad relay, **G** SIR on, **H** per-recipient — enable switches when lab is prepped (script logs **SKIP** until then) |

### MA-02 automation (`Mail/P0/MA-02-Resilience.ps1`)

| # | Plan step | Script / helper |
|---|-----------|-----------------|
| 1 | **A** — idle temp (standalone baseline) | `Invoke-Ma02StepA` → `Assert-MailAgentE2eIdleTempFolders` |
| 2 | **B** — 5–10 mails + restart while some still in flight | `Invoke-Ma02StepB`; `Wait-CoreE2eRunningSanitizationForSubject` (`runningsanitizations`); agent fallback `Wait-MailAgentE2eBurstInFlight`; restart service; idle temp folders |
| 3 | **C** — commdown ≤30s / ≥30s, 451, capture, listen, temp **0** | Child `MA-02-C-NCP7307-ReconnectOutboundDelivery.ps1` (`-Ma02CScenarios` / `-Scenarios`) |
| 4 | **D** — Core outage **without** agent restart; clean mail + **Authenticated** | `Invoke-Ma02StepD` — `agentcommblockon/off` hold (default **300s**, `-StepDCommdownHoldSeconds`) |
| 5 | **E** — listen check every 5 min for 15 min | `Invoke-Ma02StepE` with Core `dbsimulateon` + `Invoke-MailAgentE2eListenPortSoak`; `-SkipCoreDatabaseSimulation` for listen-only |
| 6 | Skipped steps | `-SkipStepA` … `-SkipStepE` |

Helpers: `Mail/Common/MailAgentE2eMa02.ps1`, `Mail/Common/MailAgentE2eMailAgentDebug.ps1`. Service name: `MAIL_E2E_MAIL_AGENT_SERVICE_NAME`. Lab policy matches **MA-01**. MA-01 chain: `-IncludeMa02CLongCommdown` (long **C** only).

### Temp folder check (after deliver)

| Folder | Expect when idle after Pass |
|--------|----------------------------|
| SanitizationInput | 0 |
| SanitizationOutput | 0 |
| SmtpInboundSpool | 0 |
| SmtpFailed | 0 (except after MA-14 A) |

---

## Out of scope

- Full 2 MTA × 3 Core production soak (MA-14 D optional only)
- WMC-only UI cosmetic issues
- 1000+ message flood
- Non-Windows agent hosting
- Jira/CSV traceability in this file

---

## References

- `Resec.LabTests/Mail/Common/README.md`
- `Resec.Core.Server/docs/core-debug-api.md`
- [Resec.Agent.Mail](https://github.com/ResecTech/Resec.Agent.Mail) · [Resec.LabTests](https://github.com/ResecTech/Resec.LabTests) `Mail/`