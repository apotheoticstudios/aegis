# ADR-0012: GRDB for AegisCore's store, in a portable AegisStorage target

- **Status:** accepted (Stage 1 Checkpoint 1, storage part; owner's default OK for the download, 2026-10-08)
- **Date:** 2026-10-08
- **Proposed by:** Claude, from the trial in #68 (PR #76) · **Approved by:** human

## Context
AegisCore owns one SQLite database. It holds events, schedule records, checkpoints and finished briefs, with full-text search (DESIGN.md › Tech stack, `docs/stages/STAGE-1.md` step 2.7).

The store must:
- commit a batch's records and its checkpoint together;
- make replays harmless;
- run ordered migrations;
- search with FTS5.

ChatGPT's bake-off plan raised two points: GRDB's Linux support is contributor-maintained, and GRDB needs Swift 6.1 or newer, while the Linux CI job ran Swift 6.0.

## Options considered
1. **GRDB in a portable `AegisStorage` target:** Codex can build and test it on Linux.
2. **GRDB inside AegisCore only:** Mac-only tests, with AegisKit keeping just the store protocols.
3. **Our own wrapper over the C SQLite API**, which #61 already has for reading: no dependency, but migrations, transactions, FTS5 and pooling would all have to be rebuilt.

## Decision
Option 1. The trial (`Prototype/grdb-trial`, GRDB 7.11.1, MIT) passed on both platforms, on synthetic rows:

| Check | macOS (SQLite 3.51.0) | Linux (`swift:6.2`, `libsqlite3-dev`) |
| --- | --- | --- |
| Ordered migrations | pass | pass |
| A batch and its checkpoint commit together, and a failure leaves neither | pass | pass |
| Replays change nothing | pass | pass |
| FTS5: diacritic folding, following edits, hostile query text kept as data | pass | pass |

How it's set up:
- **Package:** `AegisStorage` becomes a library target in `Packages/AegisKit`, depending on GRDB pinned exactly to 7.11.1. The `AegisKit` target itself stays free of third-party dependencies.
- **Toolchain:** the Linux `core` CI job moves to `swift:6.2`. The language mode stays Swift 6.
- **Writer:** one serialized writer (`DatabaseQueue`), with read concurrency added only if measurements ask for it.
- **Location:** the database lives in Aegis's private Application Support folder, never in the repo.

## Consequences
- Codex can build the store and its tests on Linux (step 2.7, S1 and S2).
- The first package resolution needs network (a one-time download of about 220 MB with history). Sandboxed agents work from a resolved checkout.
- **Licence:** MIT.
- **Watch:** FTS5 must stay compiled into the system SQLite on Linux; the CI job asserts it. GRDB's Linux support is maintained by its contributors, so CI catches any regression.
- `Prototype/grdb-trial` and its CI job are removed once AegisStorage's own tests cover the same cases.
