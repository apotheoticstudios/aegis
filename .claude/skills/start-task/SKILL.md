---
name: start-task
description: Start work on a Aegis GitHub issue. Use when the user says to start, pick up or work on an issue number.
---

1. Read the issue (`gh issue view <number>` if gh is available, otherwise ask the user to paste it). Confirm it is labelled `agent:claude`; if not, say who owns it and stop.
2. Read AGENTS.md, docs/STATUS.md and the stage file in docs/stages/.
3. Create the worktree and branch: `scripts/new-worktree.sh <number> <short-slug>` (branch `claude/<number>-<slug>`), and work inside it.
4. Restate the acceptance criteria and the files you will touch. If the issue needs changes outside its module or to AegisKit contracts, stop and say so.
5. Build with tests first where practical. Run `make test-core`, `make guard` and `make test` before finishing.
6. Finish with `/handoff`.
