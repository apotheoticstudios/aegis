# ADR-0015: Aegis's voice through Voicebox

**Status:** Superseded by ADR-0018 (Aegis bundles its own Kokoro voice, 2026-10-15) · **Issue:** #192

## Context
Voice v1 (#178) spoke with macOS system voices. The owner asked for a proper, fluent AI voice using Voicebox (github.com/jamiepine/voicebox, MIT): a local voice studio for Apple Silicon (MLX) with several TTS engines (Kokoro, Qwen3-TTS, Chatterbox…), voice profiles and a REST API on 127.0.0.1:17493.

## Decision
- Aegis speaks through the **Voicebox app installed separately** on the Mac, not a bundled engine: no new Swift dependency, and Voicebox manages its own models.
- The panel app talks to Voicebox's local server only (`http://127.0.0.1:17493`; ATS `NSAllowsLocalNetworking`): `POST /generate` with the profile named **"Aegis"**, poll `GET /history/{id}`, `GET /audio/{id}`, then `DELETE /history/{id}` so Aegis's words don't stay in Voicebox's history. Text is sent sentence by sentence and the next passage is generated while one plays.
- The "Aegis" profile starts as Voicebox's Kokoro British male preset "George" (created if missing); the owner can redesign it in Voicebox and Aegis follows. Original synthetic voices only: no clone of a real person (DESIGN.md › Voice).
- Voicebox is opened hidden when the panel opens; Aegis never speaks while the panel is closed. If Voicebox isn't installed or running, Aegis falls back to the system voice. Listening stays on Apple's on-device recognition.

## Consequences
- No audio or text leaves the Mac; a third-party local process now receives the text Aegis speaks (answers and the brief).
- Voicebox's own memory is outside Aegis's 300 MB idle budget; it runs only after the panel has been opened.
- Kokoro on the M5: about 1 s per 5 s of speech once warm (3.6 s for the first passage).
