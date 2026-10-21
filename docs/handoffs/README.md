# Handoffs

AI sessions forget; these notes don't. Every working session ends with one file here:

`YYYY-MM-DD-<agent>-<issue>.md`, created with `scripts/handoff.sh <agent> <issue>` from `TEMPLATE.md`.

- Claude: `/handoff` does it.
- Codex: include the handoff section in the PR description (the PR template has it); Claude copies it here when integrating.
- ChatGPT / DeepSeek: their answers go into the issue as comments; no file needed.

A new session on an issue starts by reading `docs/STATUS.md` and the latest handoff for that issue.
