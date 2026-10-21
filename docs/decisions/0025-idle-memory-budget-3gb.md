# ADR-0025: Idle memory budget raised to 3 GB

- **Status:** Accepted (owner's decision, 2026-10-20)
- **Supersedes:** the 300 MB idle budget in AGENTS.md and DESIGN.md

## Context

The original budget kept every always-on Aegis process at or under 300 MB. The owner's Mac has 24 GB of RAM, and the owner set Aegis's limit at 3 GB.

## Decision

All always-on Aegis processes together may use up to 3 GB while the panel is closed. The room is for small, useful helpers kept warm (for example a small local model for memory and quick answers, or a memory-search model). The large chat model still loads on demand and unloads after use. Silence, efficiency cores and no fan while the panel is closed are unchanged.

## Consequences

- Features such as automatic remembering and meaning-based memory search can run locally without waiting for the large model.
- Measurements of idle RAM are checked against 3 GB instead of 300 MB.
- Stage 1's historical "done when" line keeps its original 300 MB figure; it was met.
