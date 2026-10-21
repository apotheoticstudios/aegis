# ADR-0026: Port code from OpenJarvis

- **Status:** Accepted (owner's decision, 2026-10-20)
- **Issues:** #281 (safety scanner, Codex), #282 (automatic memory, Claude)

## Context

The owner asked to integrate parts of OpenJarvis (Stanford, Apache-2.0, Python) into Aegis, using its code and not only its ideas. Running OpenJarvis itself would add a second model runtime (Python and Ollama next to MLX), connectors built around Google and chat apps, and code outside Aegis's privacy guard and tests.

## Decision

Port selected OpenJarvis modules to Swift inside AegisKit, keeping their logic, patterns and prompts, with attribution:

- `security/injection_scanner.py`, `types.py`, `taint.py`, `credential_stripper.py` → `AegisKit/Safety/`
- `memory/extractor.py`, the trust tiers of `memory/store.py`, and `memory/service.py` → automatic memory

Apache-2.0 obligations: the licence text is in `ThirdParty/OpenJarvis/LICENSE`, `THIRD_PARTY_NOTICES.md` lists every ported file, and each file's header names its source and what changed. Following the licence rule in `docs/design/open-source-references.md`, code is copied only from permissively licensed projects.

Adaptations for Aegis's rules:
- Automatic memory reads only the owner's own words, never Aegis's reply or collected content (OpenJarvis also reads the assistant's reply).
- Extraction uses the local model while it is still loaded after a chat, waits for a quiet moment, and stops when the owner asks something new. No network.
- Learned notes never change what the owner asked Aegis to remember. Flagged facts are quarantined: kept so the owner can see and forget them, never used in a reply.
- The owner can say "stop learning about me".

Second round (#285, #286): skills (`skills/types.py`, `parser.py`, `loader.py`, template rendering) and the morning routine (`tools/approval_store.py`, `parse_approval_response`, adapted from `agents/proactive_agent.py`). Adaptations:
- A Aegis skill is a saved list of the owner's own commands. Running one sends each step through the normal path, so actions keep their confirmations, and a skill never starts another skill.
- OpenJarvis's proactive agent lets a model read collected email and messages and propose actions, including deletes. Aegis does neither: proposals come only from the owner's own data (remembered dates, their own promises, rule suggestions, scheduled skills), and deleting stays on the never-list.
- The routine is built when the panel opens, never while it's closed. "Always yes / always no" is remembered only for low and medium tiers, as in OpenJarvis.

Later candidate: the trace and learning loop.

## Consequences

- New capability without new dependencies or network use.
- Ported code is maintained here. Upstream fixes are pulled in by hand, with the commit noted in `THIRD_PARTY_NOTICES.md`.
