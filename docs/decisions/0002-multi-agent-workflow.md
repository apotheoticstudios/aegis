# ADR-0002: Multi-AI workflow through GitHub

- **Status:** accepted
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
The owner uses Claude (paid), ChatGPT Plus (with Codex) and DeepSeek (free web chat) and wants all three to contribute real value without chaos.

## Decision
- The GitHub repo is the shared workspace; AGENTS.md is the single rules file (Claude imports it; Codex reads it natively; it is pasted into chats).
- Roles: Claude = hub, Mac builder, planner, integrator; Codex = cloud builder for Linux-buildable work and automatic PR reviewer; ChatGPT = research, assets, bake-off plans; DeepSeek = independent third opinion, edge cases, fixture text (copy-paste); human = approvals, merges, real data, secrets.
- Every task is an issue with an owner label; one issue → one branch → one PR; one writer per branch.
- Cross-vendor review: code is reviewed by a different company's AI than the one that wrote it.
- Handoff notes and STATUS.md carry memory between sessions.

## Consequences
Parallel work across vendors with clear ownership and an audit trail. The human remains the bottleneck for approvals and merges, so keep 3–4 parallel threads at most.
