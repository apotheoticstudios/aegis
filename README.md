# Project: Aegis

Project: Aegis is private assistant software for macOS. Your assistant is **your Aegis**, and you can give it a personal name in Personality settings. It reads your messages, email, notifications and calendar, works out what matters with local AI models, and shows it in a sci-fi HUD. Everything stays on your Mac.

**Status:** framework and development setup only. No app features yet. Next: Stage 0 (prototype and risk tests).

## Start here

| If you are… | Read |
| --- | --- |
| Setting up for the first time | [`docs/workflow/SETUP.md`](docs/workflow/SETUP.md) |
| Any AI agent | [`AGENTS.md`](AGENTS.md), then [`docs/STATUS.md`](docs/STATUS.md) |
| Planning or assigning work | [`docs/workflow/MULTI_AGENT.md`](docs/workflow/MULTI_AGENT.md) |
| Looking for the spec | [`docs/design/DESIGN.md`](docs/design/DESIGN.md) |

## Who builds what

| AI | Role |
| --- | --- |
| Claude (Claude Code, on the Mac) | Hub: Mac/Xcode builder, planner, integrator, reviews Codex's work |
| Codex (ChatGPT Plus) | Cloud builder for Linux-buildable work; automatic reviewer of Claude's PRs |
| ChatGPT | Research, images and assets, independent plans |
| DeepSeek | Third opinion, edge cases, synthetic fixture text |
| You | Approve plans, merge, run on real data, hold secrets |

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
Apps/AegisApp/       macOS app (scaffold)
Fixtures/             synthetic test data only
Prototype/            Stage 0 scripts
docs/                 design, workflow, decisions, stages, handoffs, status
scripts/              bootstrap, guard, worktrees, handoffs, labels
```

## Licence

MIT, see `LICENSE`. Third-party code keeps its own licence (`THIRD_PARTY_NOTICES.md`).
