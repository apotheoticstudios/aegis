# ADR-0005: No real personal data during development

- **Status:** accepted
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
Aegis processes the owner's messages, email and notifications. Cloud AI services (Codex, ChatGPT, DeepSeek) and even local agents should never see that data.

## Decision
- All development and tests use synthetic data in `Fixtures/`.
- Only the human runs Aegis or prototypes on real data; outputs are never committed.
- Claude Code's `.claude/settings.json` denies reading the macOS personal data stores.
- `make guard` (and the pre-commit hook and CI) blocks commits that reference real data paths, contain secrets, or add Apple-only imports to AegisKit.
- Never paste secrets or personal data into any chat AI.

## Consequences
Strong privacy by default; fixtures must be realistic enough to catch real-world bugs, so their schemas follow research findings (Stage 0, issue 0.1).
