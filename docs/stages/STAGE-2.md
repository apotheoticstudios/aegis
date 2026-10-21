# Stage 2 — Notification capture and messaging

**Status:** planned 2026-10-09 by Claude from a three-way bake-off: Claude's plan, ChatGPT's (Codex, gpt-6.1-sol, read-only run) and DeepSeek's (web chat). Stage 2 starts at Stage 1's Checkpoint 3, when the owner's three mornings are scored. Issues are created when each step starts, not all at once.

**Goal:** record every notification the Mac receives, so dismissing one never loses it, with each source isolated and its health visible.

**Done when:**
1. **Synthetic matrix.** Scripted test notifications, each with a unique ID, are all captured or explained: dismissed at 0, 0.5, 1 and 5 s; bursts; grouped and replaced notifications; Focus on; hidden previews; an app with banners off. Counts and latencies only (ChatGPT, DeepSeek).
2. **A normal day on the owner's Mac.** Database, Accessibility and direct-source counts reconcile with no unexplained misses. The owner returns counts, latency distributions and failure categories only.
3. **Isolation.** A broken or reformatted source never stops the others and shows as such in the panel.
4. **Resources.** All always-on processes together still idle at 300 MB or less with the new recorders.

## Already done in Stage 1

The database recorder's core landed early (#138): kqueue events on the Notification Center store, its WAL and folder; a scan about 1 s after a change, at most one per 5 s; a 5-minute reconciliation scan; stable IDs. Messages notifications already merge with their chat.db records. Stage 2 hardens this instead of rebuilding it.

## Order of work and checkpoints

**L** = Linux-buildable (Codex); **M** = needs a Mac with Xcode (Claude); **O** = the owner.

### Step 0: evidence and decisions

| ID | Task | Who |
| --- | --- | --- |
| 0.1 | **Accessibility observer probe.** Does an `AXObserver` get the app's Accessibility grant in AegisCore, as Full Disk Access does (#66), or only in the app? Which observer notifications fire for banners (`AXObserverAddNotification` may return unsupported)? Includes a tree-dump mode to compare after macOS updates (DeepSeek). Stage 0 proved reading banners, not event-driven observation (ChatGPT). Counts only | M + O |
| 0.2 | **WhatsApp store feasibility.** Table and column names, row counts, encryption, history scope (a companion device holds only synced history; DeepSeek) and `@lid` identifiers. Structure only, never content | M + O |
| 0.3 | **Telegram decision** (below) | O |
| 0.4 | **The supported delivery matrix:** macOS versions and the cases Done-when 1 covers (ChatGPT) | Claude |

**Checkpoint A** (when 0.1–0.4 are in): where the Accessibility recorder runs; WhatsApp direct reader yes or no; Telegram path.

**0.1 result (owner's run, 2026-10-10, counts and element roles only):** Accessibility granted to the app reaches the agent, as Full Disk Access does. Observing Notification Center's UI process (`com.apple.notificationcenterui`) works: every registration succeeded, and each banner fired one `AXWindowCreated` (5 of 5 in the app; the probe's agent watched 12 s in every 15 s and saw 4). A banner is `AXWindow/AXSystemDialog` › `AXHostingView` › `AXScrollArea` › `AXGroup/AXNotificationCenterBanner` with two `AXStaticText` children (title and body). **Decision:** the Accessibility recorder runs in AegisCore, observing on its main run loop (#141); no XPC hand-off.

**0.3 decision (owner, 2026-10-10):** no Telegram collector; the owner doesn't use Telegram. Its Mac notifications, if any, are captured like any app's. Tasks for Telegram are dropped.

**0.2 result (owner's run, 2026-10-10, structure only):** the WhatsApp Mac store is plain SQLite, so the direct reader (2.6, 2.10) goes ahead. `ChatStorage.sqlite` has `ZWAMESSAGE` (text, from-me, message date, chat session, group member, stanza ID, from/to JIDs, push name, parent message, media item), `ZWACHATSESSION` (contact JID, partner name, session type), `ZWAGROUPMEMBER`, `ZWAPROFILEPUSHNAME` and `ZWAMEDIAITEM` (captions). Senders use `@s.whatsapp.net`, `@lid` and `@g.us` JIDs; `ContactsV2.sqlite`'s `ZWAADDRESSBOOKCONTACT` maps `ZLID` to `ZWHATSAPPID` and phone numbers (DeepSeek's `@lid` point confirmed; `LID.sqlite` also exists). The Mac holds only a small, recent slice of history (a companion device), which suits a daily brief. Open: whether WhatsApp must keep running to receive messages, as Mail does.

### Step 1: contracts (Claude, L)

| ID | Task |
| --- | --- |
| 1.1 | **Contract v0.3.** Separate recorder identities and checkpoints for database, Accessibility and direct sources, so an Accessibility scan can never declare database coverage complete (ChatGPT). Observation records with persisted IDs and links to a canonical event; ambiguous links stay separate (ChatGPT). A dismissal state on notification events (DeepSeek). Source health: disabled, permission denied, unsupported format, transient failure, stale, healthy; last successful scan kept apart from last captured event (all three). `whatsapp` as a source if 0.2 passes. Never-read apps applied at capture, not display (Claude) |
| 1.2 | **Storage:** provenance and links persisted and migrated; an observation and its checkpoint commit together; dismissal never deletes; a retention rule for the permanent log (Claude, ChatGPT) |

### Step 2: parallel lanes

| ID | Task | Lane | Needs |
| --- | --- | --- | --- |
| 2.1 | Schema fingerprints for every reader; unknown format reports "unsupported format" and reads nothing (all three) | L | 1.1 |
| 2.2 | Synthetic capture harness: a manifest of expected IDs; reports missing IDs and latency, never bodies (ChatGPT); an `osascript` self-test (DeepSeek) | L + M | 1.1 |
| 2.3 | Recorder failures visible, bounded retries: today `NotificationRecorder` swallows errors with `try?` (ChatGPT) | L + M | 1.1 |
| 2.4 | Health supervision with a fake clock: stalls, recovery, retry caps, no busy loops; recovery differs per collector (DeepSeek) | L | 1.1 |
| 2.5 | Conservative merge v2: database, Accessibility and direct sources (Mail too). Zero false merges in the acceptance corpus before any new rule is enabled (ChatGPT) | L | 1.1 |
| 2.6 | WhatsApp reader and synthetic fixtures, including `@lid` handles (DeepSeek); only if 0.2 passes | L | 0.2, 1.1 |
| 2.7 | Retention and compaction with an injected clock; excluded apps never stored | L | 1.2 |
| 2.8 | File-watch recovery: WAL truncation and replacement, missing folder, restart; decide the 5 s throttle from measured tail latency (ChatGPT) | M | 2.2 |
| 2.9 | Accessibility recorder where 0.1 says: observer-driven, never opens Notification Center, moves focus or clicks; no continuous polling | M | 0.1, 1.1 |
| 2.10 | WhatsApp lifecycle wiring (never launches WhatsApp) | M | 2.6 |
| 2.11 | Capture health in the panel, one line per source with a fix, nothing while the panel is closed | M | 2.4 |
| 2.12 | Notification suggestions, minimal: detect installed messaging apps; static guidance for web apps; no settings changed (DeepSeek, Claude). The full wizard is Stage 6 | M | — |

### Step 3: integration (Claude)

Compose the recorders in AegisCore; crash replay keeps every record; one broken source leaves the others working; measure idle RAM with everything on; run the synthetic matrix.

**Checkpoint B** (Done when): the matrix passes, then the owner's normal day.

## Decisions for the owner

- **Telegram.** The design says "Telegram (API)". That means Telegram's servers, an account login, app credentials and a large dependency (TDLib), which breaks the no-network rule unless the owner approves an exception (Claude, ChatGPT; DeepSeek assumed it was approved). **Recommended:** Telegram through its Mac app's notifications, already captured; a direct collector only after an explicit exception and an ADR. Secret chats are device-specific either way.
- **Retention.** How long the permanent notification log keeps full text before compressing to metadata.

## Proposed changes to the design (after the owner agrees)

- "Every notification" becomes the supported delivery matrix; "dismissing loses nothing" means once persisted, and dismissal before capture is the race Stage 2 tests (ChatGPT).
- WhatsApp's direct reader is gated on 0.2; Telegram on the decision above.
- Setup suggestions describe prerequisites; they can't guarantee delivery.

## Risks

| Risk | Early test | Decision it drives |
| --- | --- | --- |
| A notification is dismissed before either recorder saves it (the 5 s throttle; Accessibility misses brief banners) | 2.2's matrix, dismissing at 0–5 s | Throttle and coalescing policy; narrow the claim where neither route sees a case |
| Undocumented formats change: the Notification Center database, the banner's Accessibility tree, WhatsApp's store | 2.1 fingerprints, 0.1 tree dump, 0.2 feasibility | Unknown formats fail visibly and alone; defer WhatsApp if needed |
| Merging hides distinct notifications | 2.5's corpus: identical text across chats, repeats, edits, truncated previews | Ambiguous evidence stays separate |
| Accessibility doesn't reach a background agent | 0.1 | Run the observer in the app and pass observations to AegisCore over XPC |

## Not adopted

- DeepSeek: a Telegram client through a Telethon subprocess (network not approved; Python runtime); opening WhatsApp's store with `immutable=1` (Aegis reads private copies of WAL stores and never uses immutable mode).
- Claude: hashing body and time for Accessibility-only events; replaced by ChatGPT's persisted observation IDs.
