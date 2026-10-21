# Third-party notices

Aegis includes code ported from these projects. Their licences are kept under `ThirdParty/`.

## OpenJarvis

- Source: https://github.com/open-jarvis/OpenJarvis, commit 6ae98f0df9c1cf8bf6e86f7b997c43bc0600da04
- Copyright the OpenJarvis authors (Hazy Research and the Scaling Intelligence Lab, Stanford)
- Licence: Apache License 2.0, full text in `ThirdParty/OpenJarvis/LICENSE`
- Changes: translated from Python to Swift and adapted to Aegis's privacy rules. Each ported file names its source file and its changes in a header comment.

| Aegis file | Ported from |
| --- | --- |
| `Packages/AegisKit/Sources/AegisKit/Memory/FactExtractor.swift` | `src/openjarvis/memory/extractor.py` |
| `Packages/AegisKit/Sources/AegisKit/Memory/MemoryBook+Learning.swift` | trust tiers in `src/openjarvis/memory/store.py` |
| `Packages/AegisKit/Sources/AegisKit/Engine/CoreEngine+Learning.swift` | `src/openjarvis/memory/service.py` |
| `Packages/AegisKit/Sources/AegisKit/Safety/*.swift` | `src/openjarvis/security/` (injection scanner, types, taint, credential stripper) |
| `Packages/AegisKit/Sources/AegisKit/Skills/*.swift` | `src/openjarvis/skills/` (types, parser, loader, executor's template rendering) |
| `Packages/AegisKit/Sources/AegisKit/Routine/Approvals.swift` | `src/openjarvis/tools/approval_store.py` |
| `Packages/AegisKit/Sources/AegisKit/Routine/ApprovalReply.swift` | `parse_approval_response` in `src/openjarvis/tools/proactive_tools.py` |
| `Packages/AegisKit/Sources/AegisKit/Routine/MorningRoutine.swift` | adapted from `src/openjarvis/agents/proactive_agent.py` |

## God's Eye View

- Source: God's Eye View (bilawalsidhu/gods-eye-view on GitHub), at the commit pinned in `Apps/AegisApp/Resources/World/`
- Copyright (c) 2026 Bilawal Sidhu
- Licence: MIT. Aegis downloads and runs God's Eye View itself at setup (ADR-0024); its licence is in its own folder.
- Ported here: the view-applying steps of `src/app/embed.js` (`applyView`) in `Apps/AegisApp/Sources/WorldWindow.swift`, and a compact catalogue of the page actions in `src/voice/actionSchemas.js` and `gevRealtime.js` in `Packages/AegisKit/Sources/AegisKit/World/world-actions.md` (#296).

## Hindsight

- Source: Hindsight (vectorize-io/hindsight on GitHub), `hindsight-api-slim/hindsight_api/engine/search/fusion.py`
- Copyright Vectorize; licence: MIT
- Ported: reciprocal rank fusion with a per-list cap, in `Packages/AegisKit/Sources/AegisKit/Memory/MemoryRecall.swift` (#305).
- Adapted: the observation rules of `hindsight_api/engine/consolidation/prompts.py`, in `Packages/AegisKit/Sources/AegisKit/Memory/Reflection.swift` (#315).

## BAAI bge-small-en-v1.5

- Model: BAAI/bge-small-en-v1.5 on Hugging Face, revision 5c38ec7c405ec4b44b94cc5a9bb96e735b38267a
- Licence: MIT. Downloaded at setup by `scripts/fetch-meaning-model.sh` (ADR-0027); not stored in the repo.
