# Status board

Updated by whoever changes an issue's state (Claude's `/handoff` does it automatically).

**Current stage:** 1 — Foundations and first brief (plan: `docs/stages/STAGE-1.md`; Stage 0 closed 2026-10-08)
**Handover brief:** `docs/BRIEF.md` (2026-10-21, newer than this board).
**Last updated:** 2026-10-12 (afternoon) — Done today in the brief; Aegis remembers (memory, shortcuts, "do that again"); Claude/ChatGPT hand-off for non-personal questions (needs the owner's API key). GitHub Actions is out of budget: CI's checks run locally until it resets or the limit is raised.

## In progress

| Issue | Title | Owner | Branch | State |
| --- | --- | --- | --- | --- |
| — | Real mornings and feedback on the new features | agent:human | — | Owner's reviews drive the next fixes |
| #83 | AegisShell stages 3–6: the stream (#78), world and home readings, the art shapes (#77), window layouts (#83); launcher fix (present while engaged) | agent:claude + agent:codex | merged | The owner's first real run to come |
| — | AegisShell stage 5: the launcher (⌥Space while engaged; apps, files, settings, commands and Ask Aegis; through ActionPolicy) | agent:claude | claude/shell-launcher | Merged; the owner's first real run to come |
| — | AegisShell stage 3: the readings round the core (status, next up, waiting orbit, system arcs, brief, ask line, ground), the still frame, Hide details (on by default) and Hold still in Aegis's menu (ADR-0033) | agent:claude | claude/shell-readings | Merged; the owner's first real run to come |
| — | AegisShell stages 1–2: engage and disengage (⌃⌥A, menu, Exit, "engage" / "stand down"), the Dock saved and restored, the design's transition, Aegis's menu bar item and menu, the desktop's frame and core (ADR-0033) | agent:claude | claude/shell-engage | Merged; the owner's first real run to come |
| #72 | World: air quality, eruptions and Australian weather warnings around home, in the brief and by asking (ADR-0024); fixes the brief's weather line | agent:claude | claude/world-alerts | Merged; not yet tried |
| #8 | The Project: Aegis design system: five screens, tokens, fonts (ADR-0029) | agent:claude | claude/8-design-foundation | In review; next: settings windows, theme picker |
| #8 | The design's motion: each screen builds itself as it shows (ADR-0029) | agent:claude | claude/8-design-motion | In review; waits for the owner's go-ahead |
| #52 | Proper chatbot conversation: fuller answers, 20 turns for 30 min, follow-ups about the day (Codex), cached turns in ModelService (first word ≈ 1.3 s, was 3.2 s), natural wording | agent:claude | claude/52-chatbot-conversation | In review; the owner tries it live next |
| #59 | Codex review of general commands: findings 1–5 fixed (model picks stay asked-first on replay, real file targets, never-list word forms, plans stop on panel close, plan resume bound to its message card); 6 is the chat session's | agent:claude | claude/59-command-safety-fixes | Merged |
| #49 | Follow-ups in context: "the other one", "the second one", "close it", "show it in Finder", "again", "do the same for X" (ADR-0031) | agent:claude | claude/49-follow-ups | Merged; not yet tried by voice |
| #47 | General commands, slice 4: multi-step plans shown before they run, one OK (ADR-0031) | agent:claude | claude/47-multi-step-plans | Merged; the agreed design is complete |
| #45 | General commands, slice 3: Maps, Settings pages, volume and dark mode (ADR-0031) | agent:claude | claude/45-maps-settings-volume | Merged |
| #39 | General commands, slice 1: open websites and run shortcuts by name; the model maps other commands to one ability (ADR-0031) | agent:claude | claude/39-general-commands | Merged |
| #43 | General commands, slice 2: files and folders by name, the app automation catalogue (Music, Notes, Safari, Finder) (ADR-0031) | agent:claude | claude/43-files-and-automation | Merged; not yet tried live (Automation prompts, Spotlight picks); next: app links, multi-step plans |
| #30 | Setup wizard, stage 4 of 4: models download during setup, the tune-up (ADR-0030); 13 screens (stages 1–3: #24, #26, #28) | agent:claude | claude/30-setup-tuneup | Merged; the owner tries the wizard live next |
| #223 | Hand complex, non-personal questions to Claude or ChatGPT (ADR-0017) | agent:claude | merged (PRs #225, #236) | ChatGPT works on the owner's plan (no key); Claude needs a key or Claude Code installed |

## Up next

Next: "Hey Aegis" diagnosis with the owner (logs are in); Codex cross-vendor review of #224, #225, #226, #228 (one batched pass once its allowance returns); Claude through Claude Code when the owner installs it; streaming speech; Stage 4 HUD.

**CI:** GitHub Actions is out of budget (jobs don't start). Until it resets or the owner raises the limit, Claude runs CI's checks locally before merging (`make test-core`, `make test`, guard, lint, scripts) and says so on the PR.

## Blocked / waiting on the human

- **Optional, ready by 7 with the lid closed:** `sudo pmset repeat wake MTWRFSU 06:50:00` (works best plugged in). The setup wizard will offer this later (design rev 120).
- **School email:** check that new school mail arrives in Apple Mail (Microsoft switched off EWS on 1 October).
- Clean-up: empty the Trash (old Aegis copies); remove the Permissions Probe and FDA Test entries from Privacy & Security.

## Recently done

- **2026-10-15:** Aegis knows it's Aegis, with an owner-chosen name, style, form of address and notes under Personality…; free speech with the owner, keeping only protections against other people (#241, PR #242). Aegis's own Kokoro voice is bundled (no Voicebox), and Mail is kept running in the background (#221, Codex; PR #243, ADR-0018). Codex's review of #222/#223/#227/#235 is merged (#233, PR #238); read isolation for task agents is still open (#239).

- **2026-10-12 (afternoon):** owner identity from Sent mail and the Me card (#218, PR #219); Done today (#211, PR #220; Codex core, Claude panel); memory: remember/forget/list, instant recall, preferences, shortcuts, "do that again", past exchanges, "what did I ask you yesterday?", Remember this (#222, PRs #224, #226); Claude/ChatGPT hand-off with a deterministic privacy gate (#223, PR #225, ADR-0017); instant answers for the time, date, days until, maths and conversions (#227, PR #228); ChatGPT on the owner's plan for questions and tasks in ~/Aegis Tasks, Codex as its own launchd job, gate tightened after DeepSeek's review (#235, PR #236). Earlier today: one item per question and answer (#212), duplicate apps removed, SpeechAnalyzer (#213), action safety core (#189), CI macOS jobs manual-only (#217).

- **2026-10-11 to 10-12 (new M5 Mac):** set up after migration (Metal Toolchain, signing certificate chain, GitHub sign-in); Qwen3.5-9B on 24 GB+ Macs with rules that make priorities and senders model-independent (#190, PR #191; synthetic day 5/7, 0 wrong people, 0 unsupported for 4B, 9B and 9B 8-bit); Aegis's voice through Voicebox with the "Aegis" profile, warm-up on panel open, 1.12x speech (#192, #196, PRs #193, #197, ADR-0015); talking to Aegis like a person (#194, PR #195) and the conversation view (#198, PR #199); calendar attendees (PR #200); VIP and keyword rules (#185, PR #201; Codex); meeting prep with a Prep button (#184; Codex wrote the pipeline).
- **2026-10-10 (evening):** Junk on a source and Mute on a person or group chat, with a Muted list (#175, PR #177; Codex wrote the rules core); reply drafts on People waiting, copy only, never sent (#176, PR #180; Codex); ask by voice on-device, spoken answers, Read my brief, the panel reactor and the ⌥⇧Space talk hotkey (#178, PR #181); plain-language rules in the Ask bar (#179, PR #183; Codex); You said you'd: open promises from the owner's own messages (#182; Codex). ModelService caps MLX's buffer cache at 256 MB (a brief reached 5.7 GB uncapped). Maple Preview 20B-A1B tested: never finished a brief, ~4/7 Ask, ~2x Qwen's RAM; not adopted (#174).
- **2026-10-10:** Ask Aegis anything (#163, PR #164; Codex wrote the pipeline); People waiting (#165, PR #166); Filtered list with Not junk (#167, PR #168); menu bar glow and arc reactor icon (#169, PRs #170, #171); evening wrap-up (#172). Brief: one item per request, grouped by person and group chat, up to 10 entries (#156, #158, PRs #157, #159, #160); bulk mail kept out (#151); questions get their conversation, notification twins merged, Open goes to the chat (#153); Messages notifications matched case-insensitively (the real ID is lower case). Owner's DESIGN.md edits committed and synced with the Claude Doc (rev 167, PR #161).
- **Night of 2026-10-09:** notifications on file events within about a second (#138, PR #139); automated "Reply Y" prompts aren't questions (DeepSeek's idea, PR #137; the held-out day's last noise item stays a known gap, judged on real mornings instead, owner's decision on #135); noise scratch in one SQLite store, 210 s → 30 s (Codex, PR #140); AegisCore keeps its main run loop (PR #141); CI skips tests for docs-only changes and reuses compiled dependencies (PR #136); Stage 2 bake-off with all three AIs (`docs/stages/STAGE-2.md`).
- **Step 3.2 measured (2026-10-09 evening, #131, PRs #133 and #134):** `make heldout` runs the synthetic dense day through the real readers, engine and MLX model in about 60 s (2.1 GB peak); Codex's independent scorer prints counts only. Seed 7: recall 7/7, 0 invented facts or wrong people, 0 instructions followed, 0 planted orders urgent, 7 items and 1 urgent; **fails high-priority noise (1)**. Installed Release build idle: 46 MB for the app and AegisCore, ~0 CPU and energy, ModelService absent between jobs.
- **The real app (2026-10-09, PRs #113–#130):** CoreEngine runs the brief end to end (#112) and publishes only through Codex's brief checks (#94); collectors for Messages, Mail and notifications (#114); ModelService runs Qwen3.5-4B with MLX, and `make app` builds the installable, team-signed Aegis.app (#118, ADR-0014); clickable brief items (#121); sender names from Contacts (#123); today's calendar and reminders (#125); a dependable brief: refreshed on open when over an hour old, caught up after sleep, deferred when hot, Apple Mail kept running (#127). Xcode builds stay in `build/` (no extra Aegis apps). Design: wake-up time and "Wake the Mac for the brief" in the setup wizard (#129, Claude Doc rev 120).

- **Step 1 finished (2026-10-09), on the owner's Mac:**
  - XPC routing (#67, PRs #101 and #104): AegisCore reached an on-demand ModelService with the app closed; relaunch in about 0.4 s with `ThrottleInterval` 1 s; team-pinned signature checks refuse impostors; macOS remembers an agent's first signature, so Aegis is team-signed from the first install.
  - Permissions probe (#66): the app's Full Disk Access, Calendar, Reminders and Contacts grants reach the agent; revoking one reaches it at the next check; a rebuilt app keeps every grant. Restart check left.
  - Targets (#65, PR #106): AegisCore and ModelService inside `Aegis.app`, the `SharedIPC` package, team signing from a local xcconfig, and an app guard that never registers an unsigned build.
  - ADR-0013 (PR #105) records it; DESIGN.md and the Claude Doc (rev 117) match.
- **Readers and pipeline (2026-10-09):** Calendar, Reminders and Contacts readers (#107, PR #110); sender display from identity fields only (#96, PR #100, Codex); noise rules, reserved room and duplicate collapse (#95, PR #102, Codex, with Claude's review fixes); calendar occurrence IDs from the original date (#97, PR #98).
- **Research and reviews:** ChatGPT's research on MLX memory, launch agents, Apple Mail and permissions (on #67); DeepSeek's review of the Swift pipeline (on #94).
- **Privacy and cost (owner's decisions):** the repo is public-ready (no personal details); personal files stay on the Mac (`docs/history/`, `Private/` ignored, PR #108); AGENTS.md forbids personal details in code; commits use the GitHub noreply email; macOS CI runs only for Mac code (PR #109). The free Actions minutes ran out on 9 October; checks now run locally before merging.

- **AegisKit's Stage 1 core merged (2026-10-08 to 10-09), main at 185 tests on macOS and green on Linux:**
  - contracts for AegisCore, ModelService and the panel (#64, PR #75); the `.emlx`/MIME/HTML parser (#57, PR #73); notification and Messages readers with v0.2 events (#74, PR #80); the Apple Mail reader (#81, PR #86); the persisted morning-brief scheduler (#77, PR #83);
  - the store: GRDB 7.11.1 (ADR-0012, PR #82) and `AegisStorage` with atomic ingest, schedule reconciliation that never deletes on an incomplete scan, briefs and FTS5 (#84, PR #88);
  - the brief pipeline in Swift with the "already answered" rule, matching Python on the fixture day (#60, PR #91);
  - sender identity from contact handles only, never from message text (#85, PR #92, Codex cloud);
  - DeepSeek's 38 cases as a held-out dense-day fixture with sealed labels (#89, PR #93, Codex cloud);
  - the basic panel: menu bar app, global hotkey, cached brief on sample data (#78, PR #79);
  - DeepSeek's points adopted in STAGE-1.md (#53, PR #90).
- **ChatGPT's research** (recorded on #67): keep ModelService exiting after each job (MLX can't fully release memory in-process); give ModelService its own on-demand MachService agent with an idle exit; authenticate XPC with code-signing requirements; add `AssociatedBundleIdentifiers` and test Calendar, Reminders and Contacts from the agent separately from Full Disk Access; launch Mail hidden without activating it.
- **DeepSeek's review of the Swift pipeline** (recorded on #94, checked by Claude): no port differences that matter; one gap shared with Python (a greeting other than hey/hi/dear/ok before "assistant:" isn't flagged); a decision on malformed model items for #94.

- Stage 1 planned (#53): Claude's and ChatGPT's plans merged into `docs/stages/STAGE-1.md`. Scope changes (adopted as recommended): a minimal notification recorder in Stage 1; senders from Contacts; outgoing context and an "already answered" check; noise rules; schedule straight from EventKit; ModelService exits after each job; XPC instead of a local HTTP API. DESIGN.md is synced with the Claude Doc (rev 116). Stage 0 closed (#20).
- Codex's first AegisKit port merged (#56, PR #62): typedstream and notification payload decoders, written in a local `codex exec` run and reviewed by Claude.
- Contract v0.1 in Swift (#58, PR #59): strict `Event` and `Brief` types; the example data round-trips; event IDs match Python.
- Spike 1b (#54, PR #55): MLX Swift runs Qwen3.5-4B with the same rubric results as Python, similar speed and less memory; releasing the model in-process leaves 0.55 GB, so ModelService exits after each job.
- Trial (#19): one real day ran end to end in 42 s, under 4 GB, with no swap. Claude scored the private brief at the owner's request:
  - 2 items swapped who asked (a bare phone number as the sender);
  - 0 of 2 important items missed;
  - 0 instructions followed;
  - 3 noise items;
  - no email captured.

  The owner chose to get email through Apple Mail, with work Microsoft 365 accounts on Outlook's notifications for now (ADR-0008). The close-out ADRs are 0009 (Qwen3.5-4B on demand) and 0010 (one Full Disk Access grant covers the agent).
- Planted instructions (#49): a rule marks collected text that gives orders to Aegis or an assistant, and the rubric fails a brief that ranks one urgent. With the 4B model no planted instruction is ranked urgent on any input (the fixture day had 1 before), and recall and grounding held.
- Checkpoint A (#48, owner's decisions): version 1 is Mac-only (ADR-0007). The database recorder captured every Mac test notification (median about 5.75 s), and Accessibility read live banners in about 1 s without opening Notification Center. iPhone-only messages didn't reach the Mac. Qwen3.5-4B is the main model (about 4 s cold load). One Full Disk Access grant covers the background agent. Speed bars apply to live answers only. DESIGN.md is synced with the Claude Doc (rev 102), which also corrects the capture timing, the network list and the 16 GB model note.
- Reply detection (#46): a rule marks messages that ask you something, and the prompt keeps who did what. Fixture-day recall went from 1/5 to 5/5 with no invented facts, and the other inputs held steady.
- Planning (#44, owner's decision): steps and evidence checkpoints, not days or weeks. Stage 0's day-5 gate is now Checkpoint A (after the owner's Mac tests). DESIGN.md's roadmap and the Claude Doc no longer carry durations.
- Trial runner (#42): one command runs a real day through readers, merge, model and contract check, printing numbers only; the brief goes to a private file to score. On the fixture day the 4B brief was valid in 43 s but caught only 1 of 5 important items, so reply detection needs work before #19.
- Messages reader follow-up (#15, from #37): system rows (group renames, members, location sharing, FaceTime), unsent messages, stickers and poll votes are skipped and reported instead of becoming empty events.
- Mail reader (#16): Codex wrote it (PR #34); Claude reviewed it (9 findings) and the fixes are in. A 32,000-email store reads in 0.26 s for a day's window. The follow-up keeps messages with header defects, makes `deleted` optional and detects the date epoch.
- Open-source references (#37): Mail, Messages and Notification Center readers in other projects, with licences. They confirm most fixture layouts and point to fixes: optional `deleted` in Mail, and skipping Messages system rows.
- Pipeline (#17, Codex, PR #36): merges duplicate events, bounds the brief input, scores briefs on facts. Reviewed by Claude; 7 findings fixed.
- Readers (#15, Claude while Codex's allowance reset): notifications and Messages → contract events, an exact match with the fixture generator's expected output; statuses tell no data from no access; streaming keeps memory flat; `read.py` for the owner prints counts only.
- Fixture generator (#14, Claude while Codex's allowance reset): synthetic notification, Messages and Mail stores + the events and problems a correct reader must produce; covers the #6 edge cases.
- Models (#18): Apple's built-in model and Qwen3.5-4B/9B measured on synthetic events, on battery and on mains (no faster; the fanless Air slows as it warms). 4B is the realistic primary for 16 GB; 9B swaps; Apple's misses a key item; none meets the speed bar. A planted instruction can be ranked urgent (4B on a long day, Apple's model): a question for Checkpoint A.
- CI runs the privacy-guard regression tests and, once #14 lands, the fixture generator tests (#26).
- Empty-shell memory footprint (#12): an empty menu-bar app + agent use 14.4 MB combined, steady over 30 minutes (~5% of the 300 MB budget).
- Data contract: event and brief schemas, validator, examples (#9, PR #23; five Codex review rounds).
- Notification probe (#3, PR #7): metadata-only and read-only; six Codex review rounds hardened it (reused row ids, consistent fallback copy, no files created beside the store, delivery tracking).
- Privacy guard hardened by Codex (#13, PR #21; reviewed by Claude). Dependabot: actions/checkout 4 → 7 (#1).
- Stage 0 plan approved and merged (#8); issues #9–#20 and #26 created; the Claude Doc's Stage 0 section matches.
- Research (#5) and edge cases (#6) answered, recorded and closed.
- Codex connected: cloud environment `aegis`, cloud tasks and PR reviews working.
- One hub: the DeepSeek Harness app can no longer change files; its unsaved bake-off edits are stashed (recorded on #2).
- Disk freed to ~23 GB; the two #18 models (~9 GB) downloaded with the owner's OK.

- One-time Mac setup: Homebrew, `make bootstrap`, Xcode project generated; app builds and tests pass locally; lint, privacy guard and core tests pass.
- Repo published privately at github.com/apotheoticstudios/aegis; labels created; first CI (`guard`, `core`) and macOS app runs green.
- Note: branch protection needs GitHub Pro on a private repo, so `main` is unprotected; the PR-only rule in AGENTS.md still applies.

- Repo framework: AGENTS.md, multi-AI workflow, prompts, templates, CI, XcodeGen project, AegisKit scaffold.
