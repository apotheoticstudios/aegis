# ADR-0009: Main model on 16 GB Macs: Qwen3.5-4B (4-bit) through MLX, loaded on demand

- **Status:** accepted (owner's decision at Checkpoint A)
- **Date:** 2026-10-08
- **Proposed by:** Claude, from #18 · **Approved by:** human

## Context
Stage 0 measured brief quality, speed and memory on the target Mac (MacBook Air M1, 16 GB, fanless) with Python `mlx-lm` (ADR-0006). The results are in `docs/stages/STAGE-0-RESULTS.md`.

## Options considered
1. **Qwen3.5-4B, 4-bit:** accurate on a typical day; under 4 GB; never swapped; loads in about 4 s from cold and 1.3–2.2 s warm; a brief takes 35–50 s.
2. **Qwen3.5-9B, 4-bit:** the most accurate, and it leaves planted instructions out. But a brief takes 62–102 s and it pushed the Mac into swap.
3. **Apple Foundation Models:** costs no disk space and always gives well-formed output. But it is slow and uneven (14–86 s) and missed the same request in every run.

## Decision
- Qwen3.5-4B (4-bit, Apache-2.0) is Aegis's main model on 16 GB Macs.
- The model service (XPC) loads it on demand, one model at a time, and frees it after a short idle.
- The app uses MLX Swift (Stage 1) with the same model files.
- Speed bars apply to live answers: first words in 1.5 s or less. The morning brief is written in the background and only has to be ready before it is needed (owner, Checkpoint A).
- Larger models are offered only where the setup tune-up shows they run without swapping.

## Consequences
- Background briefs are fine as they are. For live answers, the input has to stay small, because the 4B reads about 100–160 tokens a second before it writes anything.
- Collected text that gives orders to an assistant is flagged by rules and must never be ranked urgent (#49).
- To confirm in Stage 1:
  - MLX Swift loads these files at a similar speed;
  - memory returns after the model unloads inside the XPC service, not only after a process exits.
- DESIGN.md's tier table (a 7–8B model for Lite) stays a target to confirm with the tune-up; on this 16 GB M1 the 4B is the measured fit.
