# Lab E2E test authoring

Checklist and conventions for new PowerShell E2E scripts in **Resec.LabTests**. Use this when adding a ticket repro, a regression guard, or extending an existing suite (Core, Scan Agent, Mail, DirWatcher, FileTypeDetection).

Scripts run against **real lab deployments** and optionally post to the [Test Platform](https://github.com/ResecTech/TestPlatform) HTTP API. They are not unit tests: keep them focused on user-visible or integration behavior the ticket describes.

**Mindset:** E2E scripts are lab tools, not museum pieces. Prefer **cleanup**, **clear logs**, and **small product/debug improvements** when they make tests reliable and labs livable. If the only way to assert behavior is brittle scraping or huge timeouts, stop and discuss adding a narrow debug hook or log line in Core or an agent (with human approval) instead of fighting the gap in PowerShell alone.

## Before you write

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Reproduce the ticket in one scenario** | One clear pass/fail path beats many weak assertions. Name the script and `TestId` after the ticket when possible (`NCP7360-…`, `Core-NCP7360`). |
| 2 | **Pick the right surface** | Core-only bugs often need `/debug/hook` only; Portal bugs may need Core REST (`/v1/portal/…`) or Scan Agent UI + Core policy. Do not duplicate coverage that belongs in product unit tests. |
| 3 | **List prerequisites in comment-based help** | Core `EnableDebugInterface`, deployment row in DB, extra tools (7-Zip, SimpleMailServer), fixture paths, policy import shape. Fail fast with actionable errors. |
| 4 | **Define deploy requirements** | Implement `Get-LabTestDeployRequirements` so Lab Test Runner knows which product deploys to verify. Core typically uses `Get-CoreDeployRequirements` (`RequiresRunning = $true`). See `Common\LabTestDeploySuiteDefaults.ps1`. |
| 5 | **Fixtures vs generated data** | Prefer checked-in files under `Fixtures\` with a small `manifest.json` when passwords or notes matter. Generate at runtime only when size/secrets make static files awkward (document password in manifest). |

## Script structure (PowerShell 5.1)

| # | Item | Why it matters |
|---|------|----------------|
| 1 | `#Requires -Version 5.1` | Lab runners and CI use Windows PowerShell 5.1, not PowerShell 7-only syntax. |
| 2 | `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` | Surprises become failures instead of silent `$null`. |
| 3 | **Dot-source helpers at script scope** | Reporting, debug hooks, and bootstrap must not be loaded inside a function (PS 5.1 scope). Scan Agent: start from `ScanAgentE2eBootstrap.ps1`. |
| 4 | **`try` / `catch` / `finally`** | Set `$script:ScenarioPassed = $true` only on success. Capture `$script:ScenarioFailureMessage` in `catch`. Teardown and Test Platform reporting belong in `finally` so they run on failure too. |
| 5 | **Exit codes** | Document `Exit 0 = passed; exit 1 = failed` in `.NOTES`. Use `exit 0` / `exit 1` explicitly when the runner keys off exit code. |
| 6 | **`Write-TestStep` (or equivalent)** | Timestamped steps make transcripts and Test Platform `runLog` usable without re-running locally. |

## Test Platform reporting (easy to forget)

Reporting is shared via `Report-*TestPlatformResult.ps1` (Core and Scan Agent wrappers both expose `Complete-ScanAgentE2eTest` and `Invoke-ScanAgentE2eTestPlatformReportingFinally`).

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Dot-source the report script before `try`** | `finally` must call reporting helpers that were loaded at script scope. |
| 2 | **`$script:TestId` and `$script:TestTitle`** | Stable dashboard names; title should include ticket id for search. |
| 3 | **Start of `try`:** `$script:TestStartedAtUtc = [DateTimeOffset]::UtcNow` | Required for result duration. |
| 4 | **Start of `try`:** `$script:E2eRunLogPath = Start-ScanAgentE2eRunLog -TestId $script:TestId` | Transcript captured on **failure** only (success deletes the log in `finally`). |
| 5 | **`finally`:** `Invoke-ScanAgentE2eTestPlatformReportingFinally` | Pass `-Passed`, `-FailureMessage`, `-StartedAtUtc`, `-RunLogPath`, and on failure `-EvidencePathsOnFailure` / `-EvidenceZipPath`. |
| 6 | **Component version** | Test Platform expects `componentVersion` on results. **Core:** after `Wait-CoreE2eReady`, call debug hook `version` and set `$env:CORE_COMPONENT_VERSION` (see `NCP7352`, `NCP7344`, `NCP7360`). **Scan Agent:** version is usually resolved in `Complete-ScanAgentE2eTest` via `Ensure-ScanAgentE2eComponentVersionRegistered` when the debug pipe works. **DirWatcher:** same pattern with `Ensure-DirWatcherE2eComponentVersionRegistered`. Do not skip version on Core scripts. |
| 7 | **Config** | `TESTPLATFORM_FUNCTION_KEY` (or `lab.local.json` `optional.testPlatformFunctionKey`). Use `TESTPLATFORM_DISABLE=1` for offline runs. See root [README.md](../README.md) and suite `Common/README.md` files. |
| 8 | **Build correlation** | Optional `BUILD_BUILDID` / `GITHUB_RUN_ID` for `buildId` and `runId`. |

## Cleanup and disk use

Repeated E2E runs fill `%TEMP%`, `C:\test`, SMTP capture folders, and evidence zips unless **`finally`** teardown is deliberate. Treat cleanup as part of the test contract, not an afterthought.

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Run output folder** | Use a unique path (`CoreE2e-<ticket>-<guid>` under `%TEMP%`, or `C:\test\SA-14`-style for Scan Agent). **On success:** `Remove-Item -Recurse -Force` in `finally` after reporting. **On failure:** print the path so someone can inspect once, then delete manually or re-run with a fix. |
| 2 | **Intermediate files** | Remove large generated fixtures inside the run (e.g. encrypted zips under `$outputRoot`) when the scenario no longer needs them, if they are not required for failure evidence. |
| 3 | **Evidence zip** | `New-CoreE2eFailureEvidenceZip` writes under `%TEMP%`. Reporting removes the zip after upload/inline send when using `Invoke-ScanAgentE2eTestPlatformReportingFinally` — do not leave duplicate copies elsewhere. |
| 4 | **Transcripts** | `Start-ScanAgentE2eRunLog` writes under `%TEMP%`. Success path deletes the log in reporting `finally`; failed runs attach content to Test Platform then stop transcript — avoid starting multiple transcripts per process. |
| 5 | **Child processes** | Stop SimpleMailServer capture, scenario-started DirWatcher, extra Scan Agent instances, etc. in `finally`. Use explicit switches (`-LeaveDirWatcherRunning`, `-SkipStartSmtpCapture`) only when debugging. |
| 6 | **Sanitize outputs** | When debug `sanitize` writes to `-OutputPath`, delete pass artifacts on success if they are not assertions. Do not accumulate sanitized copies under fixed paths across runs. |
| 7 | **Optional `-KeepArtifacts`** | For local iteration only, a switch that skips deletion is fine; default must stay **clean up on success**. |
| 8 | **Shared lab machines** | Pop policy/system-property stacks even when reporting fails (order: report → pop stacks → delete folders). Orphan lab policies and temp trees hurt everyone on the same host. |

## Lab state hygiene

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Policy stack** | Prefer `pushpolicystate` → `importpolicies` → … → `poppolicystate` in `finally`. Track `$script:PolicyStackPushed`. Offer `-SkipPolicyImport` / `-PolicyId` for repeated local iteration. |
| 2 | **System properties stack** | Same for SMTP, Portal flags, etc.: `pushsystempropertystate` / `importsystemproperties` / `popsystempropertystate`. |
| 3 | **Core comm nudge** | After policy changes that agents must reload, use established helpers (`commdown`/`commup` or restart) — copy an existing test in the same suite. |
| 4 | **Processes you start** | DirWatcher E2E stops scenario-started `DirWatcher.exe` in `finally` unless `-LeaveDirWatcherRunning`. Mail/Core SMTP capture: stop sessions in `finally`. |
| 5 | **Temp output** | See **Cleanup and disk use** — do not rely on “we’ll clean the disk later.” |

## Debug APIs — gaps and extensions

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Know what exists** | Core lab: `Resec.Core.Server/docs/core-debug-api.md` (`/debug/hook` on port 4504 when `EnableDebugInterface=True`). Agents: named-pipe/HTTP debug with one canonical `op` per command (no alias sprawl). |
| 2 | **Before writing a fragile test** | If you need state that is not exposed (no hook, no REST field, no log line), **ask the human** whether to add a small DEBUG-only command or response field rather than parsing WMC, DB, or random log grep. |
| 3 | **What to propose** | Prefer read-only introspection (`export…`, `status`, structured JSON) or idempotent lab helpers already in the family (`pushpolicystate`, `importsystemproperties`, `sanitize`). New hooks must be **lab-only**, documented in `core-debug-api.md` or agent `commands`, and covered by a minimal unit test where the product repo already tests debug handlers. |
| 4 | **When E2E is the wrong layer** | Pure logic bugs belong in product unit tests. E2E is for deployment shape, timing, Portal/UI, policy import, and cross-component flows. |
| 5 | **Impossible or absurd cost** | Say so in the ticket or PR: list the missing API and the smallest change that would unlock automation. Do not merge a flaky script that only passes on one machine. |

## Logging and observability

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Script steps** | `Write-TestStep` (timestamped) on every phase: policy import, sanitize start/end, poll iteration, assert. Failures should show *where* time was spent. |
| 2 | **Core correlation** | `Write-CoreE2eDebugLogMark` (`logmark`) before/after long waits or password submit so Serilog lines align with script steps — especially when attaching `logpath` evidence on failure. |
| 3 | **Poll loops** | Log every N seconds or on state change (portal file-data, SMTP wait, DW folder removal), not silent spin until timeout. |
| 4 | **Assert messages** | Include outcome enums, `sanitizationId`, internal names, and short detail snippets in `throw` text — Test Platform `message` and local console should be enough to triage without re-run. |
| 5 | **Product logging** | If failure modes are opaque in logs, propose a **single** additional Information-level line in Core/agent code (sanitization id + decision), DEBUG-only if needed. Small logging PRs often beat bigger E2E workarounds. |

## When scripts are not enough (small product changes)

Product code is not untouchable for lab quality. Reasonable companions to a new E2E script:

| # | Change | Example |
|---|--------|---------|
| 1 | **DEBUG hook** | Return job outcome + portal root outcome in one `sanitize` poll response so the script does not guess from tree leaves. |
| 2 | **Fix production bug** | NCP-7360-style: correct `/v1/portal/file-data` root outcome; E2E then guards regression. |
| 3 | **Agent debug `op`** | Expose folder path or connection state DirWatcher tests already need via `DirWatcherE2eAgentDebug.ps1` patterns. |
| 4 | **Shared helper in LabTests** | Extract repeated portal signature or policy import into `Core/Common` instead of duplicating 200 lines — still keep product changes on the human’s roadmap when hooks are missing. |

Get explicit approval before adding DEBUG surface area or changing production API behavior; document the new command in the product debug doc and link from the test’s comment-based help.

## Failure evidence

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Core Serilog** | `Get-CoreE2eDebugLogPathEvidence -HookUrl $hookUrl` (debug `logpath`) — attach on failure. |
| 2 | **Artifacts** | Include `$outputRoot` (and UI captures / SMTP capture folders when relevant) in `-EvidencePathsOnFailure`. |
| 3 | **Evidence zip (Core)** | `New-CoreE2eFailureEvidenceZip` for Test Platform inline or upload when zip is large. Scan Agent often lists file names in the message only. |
| 4 | **`logmark` in long polls** | See **Logging and observability** — use marks before evidence collection so zip/log bundles are readable. |

## Policies and JSON imports

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Dedicated `*Policy.ps1` helper** | Keeps `importpolicies.json` path, placeholder policy id, and raw facet lines in one place (`CoreE2eNcp7360Policy.ps1`, etc.). |
| 2 | **Facet comment syntax** | Must match Core facet template names (`;Facet Basic:…`, not display names). Wrong comments silently misconfigure policy. |
| 3 | **Associations** | Lab JSON often needs deployment/policy associations — copy shape from a sibling ticket test. |
| 4 | **Idempotent policy name** | Use a unique lab policy `name` so imports do not collide with production-named policies on shared lab DBs. |

## Assertions

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Assert what the user sees** | Portal `sanitizationState` / outcome enums, Scan Agent grid text, email body markers — not internal-only fields unless the ticket is API-specific. |
| 2 | **Negative checks** | When the bug is “shows success incorrectly”, assert **not** Passed as well as expected Blocked/Failed. |
| 3 | **Timeouts** | Parameterize `-SanitizeTimeoutSec`, portal poll timeouts, SMTP wait — lab load varies. |
| 4 | **Scalar vs array** | JSON from REST/debug may return one object or an array; use suite helpers (`Get-CollectionCount`, etc.) before indexing `[0]`. |

## Configuration and paths

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **`config\lab.local.json`** | Product repo roots, optional exe paths, Test Platform key. Created via `scripts\Initialize-LabConfig.ps1`. |
| 2 | **Env overrides** | Document `CORE_E2E_*`, `MAIL_E2E_*`, `LAB_*_REPO_ROOT`, fixture roots in script help. |
| 3 | **Hook URL** | Default from lab config; `-CoreDebugHookUrl` override. Portal REST base URL must match management port (helpers in `CoreE2ePortalApi.ps1`). |

## Documentation and maintenance

| # | Item | Why it matters |
|---|------|----------------|
| 1 | **Suite README** | Add a short section to `Core/README.md`, `DirWatcher/Common/README.md`, or Scan Agent doc with run example, policy path, and ticket link. |
| 2 | **Scan Agent bundle version** | When changing shared Scan Agent E2E behavior, bump `$script:ScanAgentE2eLabBundleVersion` in `ScanAgentE2eBootstrap.ps1` so labs know they pulled script fixes. |
| 3 | **Do not commit secrets** | Portal secrets, SMTP passwords, and `lab.local.json` stay local; use lab fallbacks only where tests already document them. |

## Reference scripts

| # | Suite | Example | Good for |
|---|--------|---------|----------|
| 1 | Core | `Core/NCP7344-OfficeNoCdrSanitize.ps1` | Policy import, sanitize loop, version, evidence zip, reporting `finally` |
| 2 | Core | `Core/NCP7352-JobEmailNotificationBlocked.ps1` | System properties stack, SMTP capture, multi-scenario |
| 3 | Core | `Core/NCP7360-PortalBlockedArchiveStatus.ps1` | Portal REST + debug hook, runtime fixture, version reporting |
| 4 | Scan Agent | `ScanAgent/Common/README.md` | Bootstrap, reporting, destination folders, Core policy helpers |
| 5 | DirWatcher | `DirWatcher/P0/DW-01-…` | Agent debug hook, Core policy, process teardown |

## Pre-merge self-check

1. Run with Test Platform enabled once; confirm console line includes `version=…` for Core (or Scan Agent component version).
2. Run with `TESTPLATFORM_DISABLE=1`; confirm pass and fail paths and pop-policy/system-property cleanup.
3. **After a successful run**, confirm temp output / `C:\test` run folders and evidence zips are gone (no silent accumulation over 10 repeats).
4. Induce a deliberate failure; confirm evidence/log attachment or related-files message; confirm evidence zip is removed after report when applicable.
5. Lab Test Runner (if used): deploy requirements resolve without editing the script.
6. If the test depended on a new debug command or log line, product doc and human sign-off are noted in the PR or ticket.
