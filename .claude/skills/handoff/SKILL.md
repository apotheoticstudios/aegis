---
name: handoff
description: End a Aegis work session cleanly. Use when the user says to wrap up, hand off, or finish for now.
---

1. Run `scripts/handoff.sh claude <issue-number>` to create today's handoff file, then fill in every section of it: what changed, decisions made, tests run and results, open questions, next step.
2. Update docs/STATUS.md: the issue's state and anything now unblocked.
3. Commit both on the current branch with a clear message.
4. Tell the user in two or three lines what is ready for review and who should review it (Codex for Claude-written PRs).
