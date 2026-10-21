# Stage 1 — Foundations and first brief

**Status:** synthesised 2026-10-08 by Claude from the bake-off on #53: Claude's plan and ChatGPT's plan (from Codex, gpt-6.1-sol), plus DeepSeek's third opinion and edge cases (added the same evening; its points are adopted below). While the owner was away, they asked Claude to take the recommended choice wherever one came up, so the scope changes below are adopted; the owner confirms them on #53. Work that every version of the plan shares has already started (see "Already done or running").

**Goal:** the skeleton of the real Swift app, delivering one useful thing: a morning brief that is already waiting in a basic panel, built only from the Mac's own data, with correct senders, today's schedule, open requests and visible source coverage.

**Done when:**
1. **Install.** A signed build installs on the owner's Mac, asks for Full Disk Access (and Contacts, Calendar and Reminders) once, and registers AegisCore. AegisCore starts at login with no Terminal.
2. **The brief is waiting.** With the Mac awake before the owner's opening time, the brief is ready, written in the background. After sleeping through that time, the panel shows the previous brief, clearly dated, and catches up automatically.
3. **Quality.** Three or more real mornings, including a busy day, an answered request and a sleep/wake case, are scored by the owner with the Stage 0 rubric:
   - 0 invented people, dates, amounts or actions (including swapped speakers);
   - at least 90% of important captured items at the right priority;
   - 0 instructions followed;
   - 0 planted instructions ranked urgent;
   - **precision as well as recall** (DeepSeek): at most 10 items (owner, 2026-10-10: one item per request; was 7) and at most 3 urgent per brief, and 0 noise items (promotions, codes, app status) ranked urgent or reply.

   On synthetic data the same holds for the fixture day and for a held-out dense day. The held-out day's labels are **sealed** (#89): they're written from DeepSeek's cases before any prompt change, and nobody tunes prompts against them.
4. **Resources.** In a Release build, all Aegis processes together settle at 300 MB or less with the panel closed, with no upward trend. ModelService is absent between jobs and causes no swap growth. Apple Mail's own memory is measured and reported separately.
5. **Parity.** The Swift pipeline matches or beats Stage 0's Python numbers on the fixture day.

## Decided going in

- Mac-first capture (ADR-0007); email through Apple Mail, with work Microsoft 365 accounts through Outlook's notifications (ADR-0008).
- Qwen3.5-4B on MLX Swift, on demand (ADR-0009, ADR-0011, spike 1b). Speed bars apply to live answers only.
- AegisCore is an SMAppService launch agent covered by the app's Full Disk Access grant (ADR-0010; to re-check with a signed build).
- The data contract v0.1 in Swift (#58), plus the "asks you something" and "gives orders to an assistant" markers and the Stage 0 rubric.

## Scope changes from DESIGN.md's Stage 1 (adopted; DESIGN updated)

| Change | Why | From |
| --- | --- | --- |
| A **minimal notification-database recorder** comes into Stage 1; the Accessibility backup and other messaging stay in Stage 2 | Notifications were 9 of 14 events on the owner's real day, and Outlook's notifications are the work-email route (ADR-0008) | Claude, ChatGPT |
| **Senders from Contacts** (`CNContactStore`, never its database); raw handles kept; ambiguous ones stay ambiguous | The trial's two role swaps came from a bare number plus a name in the text | Claude, ChatGPT |
| **Outgoing context and an "already answered" check.** A later reply counts as evidence, not proof: an unrelated "thanks" must not close another request | The trial marked an answered question "reply" | Claude, ChatGPT |
| **Simple noise rules** (marketing SMS, app status and test notifications) and **room reserved for important candidates** in the bounded input | 3 of 8 trial items were noise; "newest 40" lets promotions push out an earlier important message | Claude, ChatGPT |
| **Today's schedule and reminders come straight from EventKit records**, not from the model | Exact times and completion states need no paraphrase | ChatGPT |
| **ModelService exits after each job** (not just "unloads") | Releasing the model in-process left 0.55 GB (spike 1b) | Claude, ChatGPT |
| **XPC between processes; no local HTTP API** | DESIGN's FastAPI layer duplicates XPC and adds a process | ChatGPT |
| **Full-text search: the FTS5 index only**; the search UI comes in Stage 3 | Keep Stage 1 on the brief | Claude, ChatGPT |
| "Git and automated builds" is already done; **extend CI** instead (new targets, Swift 6.2 on Linux, the Metal Toolchain) | Stage 0's framework exists | Claude, ChatGPT |

## Architecture for Stage 1

| Process | Stage 1 job |
| --- | --- |
| **AegisKit** (Linux-testable) | Contracts, byte and row parsers, the SQLite read layer, identity and conversation rules, input selection, prompt and output validation, the scheduling state machine |
| **AegisCore** (launch agent) | Collection, sole owner of the database, job scheduling, source health, publishing finished briefs |
| **ModelService** | One bounded generation job at a time from local model files; exits after finishing, failing or cancelling. It gets a bounded snapshot, never database access |
| **AegisApp** | Setup and permission requests, menu bar, hotkey, panel; shows cached results |

- **IPC:** portable `Codable` and `Sendable` message types and service protocols live in AegisKit. The `NSXPCInterface` glue lives in a Mac-only `SharedIPC` module. Peers are checked by code signature, never by PID.
- **Storage:** GRDB with FTS5 (ADR to come). Its location is decided at Checkpoint 1: in a portable `AegisStorage` target if it passes on Linux, otherwise inside AegisCore behind AegisKit's store protocols.

## Order of work and checkpoints

Steps start when their inputs exist; checkpoints happen when their evidence is in. **L** = Linux-buildable (Codex); **M** = needs a Mac with Xcode (Claude); **O** = the owner.

### Already done or running

| Task | Who | State |
| --- | --- | --- |
| Data contract v0.1 in Swift | Claude | **Done** (#58, PR #59) |
| Spike 1b: MLX Swift runs Qwen3.5-4B | Claude | **Done** (#54, PR #55): same quality as Python; exit to free memory |
| Typedstream and notification payload decoders (P1, P5 part) | Codex | **Done** (#56, PR #62) |
| Mail `.emlx`, MIME and HTML parser (P3, P4) | Codex | Running (#57) |
| The brief pipeline ported to Swift, plus the "already answered" rule | Codex | Running (#60) |
| Read-only SQLite layer (`reader_base`) | Codex | Running (#61) |

### Step 1: contracts and boundary checks

| ID | Task | Who | Env |
| --- | --- | --- | --- |
| 1.1 (#63) | **Contract v0.2** (done in PRs #70 and #75; DeepSeek's fix, done in #97: an occurrence's ID is its item plus its **original** occurrence date, so moving one meeting doesn't create a duplicate): message direction and raw handles; resolved contact identity, kept separate; calendar occurrences and reminders as records; source provenance and collection checkpoints (incomplete scans never imply deletion); brief coverage and freshness (no events vs source unavailable). v0.1 data stays readable through an explicit migration | Claude (architect) | L |
| 1.2 (#64) | **Protocols and IPC messages:** collection results and checkpoints, `EventStore`, the model job (request ID, bounded payload, deadline, cancellation, typed errors; the model supplies only items and citations), and the Core service. Plus the Mac-only `SharedIPC` module | Claude | L + M |
| 1.3 (#65) | **Targets** (done): AegisCore and ModelService as launch agents inside `Aegis.app` with their plists, the `SharedIPC` package, team signing from a local xcconfig, and an app guard that never registers an unsigned build (ADR-0013); Swift 6.2 in Linux CI (#82). The Metal Toolchain arrives with MLX in 2.12 | Claude | M |
| 1.4 (#66) | **Signed launch and permissions probe:** a stable Apple Development identity; `SMAppService` status including `.requiresApproval`; Full Disk Access from app to agent after a restart and a re-signed build; whether Contacts and EventKit authorisation reaches the agent; revocation while running | Claude + owner | M + O |
| 1.5 (#67) | **XPC routing and authentication** (done; `STAGE-1-SPIKES.md` 1.5): Core → ModelService with the panel closed works through an on-demand MachService agent; a client with the wrong signature is refused; interruption and reconnection work. The team-anchored requirement waits for #66 | Claude | M |
| 1.6 (#68) | **GRDB trial:** pinned release with migrations, a transactional write and FTS5, on macOS and Linux. Claude runs it because the package download needs network | Claude | L + M |

**Checkpoint 1** (when 1.1–1.6 are in):
- freeze the public contracts; any later change gets its own contract issue;
- choose the Core → ModelService route;
- choose the process that hosts the EventKit and Contacts adapters (AegisCore if authorisation carries over, otherwise AegisApp sends snapshots to Core);
- choose GRDB's location.

### Step 2: parallel lanes

**Portable lane (Codex, Linux):**

| ID | Task | Needs |
| --- | --- | --- |
| 2.1 | Messages and notification readers on the SQLite layer (P2, P5): direction, GUIDs, groups, edits, reactions, unsent and system rows, previews and redaction | #56, #61, 1.1 |
| 2.2 | Mail reader on the SQLite layer and `.emlx`: one walk per batch, never the whole tree; partial downloads; missing or duplicate Message-IDs as set in 1.1 | #57, #61, 1.1 |
| 2.3 | Q1, speakers and open requests: a name mentioned in a message never becomes the sender; outgoing replies as evidence; an unrelated later reply leaves a request open. **Display rule** (DeepSeek): with no single matching contact, show the raw handle (a business sender's own ID as it is). With several matches, show the handle plus "matches 2 contacts". Never a name from the text | #60, 1.1, #85 |
| 2.4 | Q2, useful bounded input: noise rules; reserved room for important candidates; thread context; omissions counted against the whole window | #60 |
| 2.5 | Q3, prompt and draft checks: reject action fields, unknown citations and oversized output; planted orders can never be urgent; a safe fallback. The evaluator enforces the size budget and "no noise ranked urgent or reply" | #60 |
| 2.6 | J1, the scheduling state machine with an injected clock: midnight, DST, travel, sleep gaps, crashes, stale inputs, duplicate triggers; only a complete result replaces the last valid brief | 1.2 |
| 2.7 | S1 and S2, storage: idempotent ingestion where records and checkpoint commit together, migrations, FTS5, bounded maintenance and a citation-safe retention rule | 1.6, 1.1 |
| 2.8 (#89) | F1, Stage 1 fixtures and labels, from **DeepSeek's 38 cases** (#53): mentioned names, ambiguous handles, outgoing replies, several open questions, dense noise, calendar changes, mail gaps, planted orders, and a **held-out dense day** | 1.1 (DeepSeek ideas welcome) |

**Mac lane (Claude):**

| ID | Task | Needs |
| --- | --- | --- |
| 2.9 | Source access on the Mac: real paths and permissions, watching (`DispatchSource`) and periodic reconciliation, never a long-held lock. Notifications: done in #138 (file events within about a second, a 5-minute reconciliation scan) | #61 |
| 2.10 | Collectors: Messages, Apple Mail (including keeping Mail running), and the minimal notification recorder (survives dismissal; no duplicates after restart). Done in #114 (keeping Mail running is left for 2.14's setup) | 2.1, 2.2, 2.9 |
| 2.11 | Contacts (minimal keys, change notifications), Calendar occurrences and Reminders (full read access; Aegis exposes reads only) | Checkpoint 1 |
| 2.12 | ModelService: pinned MLX generation under strict Swift 6, real token budgets, no network; exits within 10 s of finishing, failing or cancelling; no restart storms (an on-demand MachService agent with `ThrottleInterval` 1 s; Core retries with backoff; spike 1.5). Done in #118: built on the Mac by `make app` (ADR-0014) | 1.3, 1.5 |
| 2.13 | Power and wake scheduling: catch up on wake; defer under heat or low power, and show it; one generation at a time; no permanent sleep assertion | 2.6 |
| 2.14 | Setup and source health; the cached brief panel (`NSPanel`, global hotkey through `RegisterEventHotKey`), citations, menu bar states | 1.2, 1.3 |

**Research (ChatGPT):** memory release in MLX Swift; on-demand SMAppService MachService agents; keeping Apple Mail running hidden (and its memory); EventKit permission attribution across processes.

### Step 3: integration (Claude)

| ID | Task |
| --- | --- |
| 3.1 | **I1, a synthetic vertical slice** (done in #112: `CoreEngine` in AegisKit, run by AegisCore; the app reads it over XPC when team-signed): fake collectors → database → fake model → stored brief → panel. A restart restores the brief, and a failure keeps the last valid one. It lands as soon as storage, IPC and a panel stub exist |
| 3.2 | **I2, the full MLX pipeline and resource budget:** the held-out rubric passes, the brief is ready before opening time with the Mac awake, the model process exits, and memory and energy gates are measured |

**Checkpoint 2** (when 3.2 runs): Swift matches Python on the fixture day; the held-out dense day passes; the resource gates hold. If recall fails, check selection, reply inference and summarising separately; batch by source or thread only if that measurably helps.

### Step 4: the owner (O)

- Install the signed build and grant permissions once.
- Check Apple Mail's completeness: counts in the reader against what Mail shows.
- Score three or more real mornings privately, including a busy day, an answered request and a sleep/wake case. Only numbers go on the issue.

**Checkpoint 3** (when the mornings are scored): Stage 1's "Done when", then the Stage 2 bake-off.

## Risks and early tests

| Risk | Early test | Decision it triggers |
| --- | --- | --- |
| Source access and permissions differ from the prototypes (signing, Login Items, EventKit and Contacts attribution, Mail layouts) | 1.4 with a signed build; synthetic WAL and rebuild tests; the owner's Mail completeness check | Which process holds each permission; Mail discovery fixed before integration; incomplete sources marked |
| A well-formed brief that's wrong (speakers, answered questions, noise displacing important items) | Held-out fixtures (2.8); Q1–Q3 | Fix attribution and selection first; keep schedule sections deterministic; safe fallback |
| Background generation breaks memory or readiness | A real XPC load, generate, exit and relaunch cycle; repeated-job memory; lid-close and wake, battery and heat | Process exit is required; lead time `max(2 min, p95 generation + 1 min)`, recalculated after I2; keep the previous brief during deferral |

## How disagreements were resolved

| Question | Claude | ChatGPT | Chosen |
| --- | --- | --- | --- |
| ModelService shape | On-demand launch agent with a MachService | Prove Core → service routing; the app as broker if lookup fails | Spike 1.5 decides, with both as candidates |
| Contract work | v0.1 port first, then protocols | Extend to v0.2 (direction, schedule, provenance) before parallel work | v0.1 done; v0.2 is step 1.1 |
| Where EventKit and Contacts run | AegisCore | Test attribution first; the app may have to host them | Checkpoint 1 decides from 1.4 |
| Notifications in Stage 1 | A basic reader polled at brief time | A minimal recorder, because work email depends on it | The minimal recorder |
| GRDB on Linux | Assumed possible | Needs Swift 6.1+; CI has 6.0 | Bump Linux CI to 6.2 and trial it in 1.6 |
| Answered questions | No marker if the owner replied later in the thread | Replies are evidence, not proof | Codex ports the simple rule now (#60); Q1 refines it with outgoing context |

## Where the ideas came from

| Source | Adopted |
| --- | --- |
| Claude | A measurable "Done when"; spikes before building (MLX Swift done, launch and permissions, topology); the minimal notification reader; Contacts names; the answered check; noise rules; ModelService exits; a stable signing identity; the risk list |
| ChatGPT (Codex) | Contract v0.2 contents (direction, identity, schedule, provenance, coverage, jobs); a Mac-only `SharedIPC` module; peer authentication; EventKit and Contacts attribution as a checkpoint; GRDB on Linux needing Swift 6.1+; deterministic schedule sections; reserved input room; a held-out dense day; the scheduling state machine with lead time; resource gates across all processes, with Mail measured separately; XPC instead of the local HTTP API |
| DeepSeek | Precision and size caps in the rubric; sealed held-out labels written independently of the prompt authors; occurrence identity from the original occurrence date; the display rule for unresolved and ambiguous senders; 38 edge cases for the fixtures (#89); testing crash replays end to end |
| Owner | Mac-only scope; email through Apple Mail; Codex doing real coding while the owner is away |
