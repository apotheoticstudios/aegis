# Project: Aegis

Project: Aegis is private assistant software for macOS. Your assistant is **your Aegis**, and you can give it a personal name in Personality settings. It reads your messages, email, notifications and calendar, works out what matters with local AI models, and shows it in a sci-fi HUD. Everything stays on your Mac.

**Status:** early and in active development. The brief and triage, voice conversation, wake word, memory, skills, the HUD and the World view work end to end on a development Mac. There's no installer yet: the setup wizard is next.

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Start here

| If you are… | Read |
| --- | --- |
| Contributing code, tests, docs or ideas | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Reporting a security or privacy problem | [`SECURITY.md`](SECURITY.md) |
| Any AI agent | [`AGENTS.md`](AGENTS.md), then [`docs/STATUS.md`](docs/STATUS.md) |
| Planning or assigning work | [`docs/workflow/MULTI_AGENT.md`](docs/workflow/MULTI_AGENT.md) |
| Looking for the spec | [`docs/design/DESIGN.md`](docs/design/DESIGN.md) |

## How it's built

| Who | Role |
| --- | --- |
| Claude (Claude Code, on the Mac) | Hub: Mac/Xcode builder, planner, integrator, reviews Codex's work |
| Codex | Cloud builder for Linux-buildable work; automatic reviewer of Claude's PRs |
| ChatGPT | Research, images and assets, independent plans |
| DeepSeek | Third opinion, edge cases, synthetic fixture text |
| Maintainer | Approves plans, merges, runs Aegis on real data, holds secrets |
| Contributors | Anything in [`CONTRIBUTING.md`](CONTRIBUTING.md): code, tests, docs, ideas |

## Everyday commands

```
make bootstrap   # first time: tools, git hooks, Xcode project
make generate    # regenerate Aegis.xcodeproj after pulling
make test-core   # fast core tests (works on Linux too)
make test        # full app build + tests (Mac)
make guard       # privacy guard
```

## Layout

```
Packages/AegisKit/   Linux-testable core (shared types, logic)
Apps/                macOS app, AegisCore and ModelService agents, voice
Fixtures/             synthetic test data only
Prototype/            Stage 0 scripts
docs/                 design, workflow, decisions, stages, handoffs, status
scripts/              bootstrap, guard, worktrees, handoffs, labels
```

## Licence

MIT, see `LICENSE`. Third-party code keeps its own licence (`THIRD_PARTY_NOTICES.md`).
