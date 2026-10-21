# ADR-0014: The real ModelService is built on the Mac; CI builds a placeholder

- **Status:** accepted
- **Date:** 2026-10-09
- **Proposed by:** Claude, for step 2.12 (#118) · **Approved by:** human (Stage 1 plan; the private repo's Actions budget, 2026-10-09)

## Context
ModelService runs Qwen3.5-4B with MLX Swift (ADR-0009, ADR-0011). MLX compiles C++ and Metal shaders: it builds only with `xcodebuild` and Apple's separately downloaded Metal toolchain (839 MB), and a clean build takes several minutes. The repo is private, so every CI minute counts against a small Actions budget, and a macOS minute counts ten times.

## Options considered
1. **Build MLX in CI:** every app PR pays minutes of macOS time plus the toolchain download.
2. **A local build step:** CI builds and tests the lightweight placeholder ModelService in `project.yml`; `make app` on the Mac builds the real one from `Packages/ModelRuntime` and puts it into the team-signed `Aegis.app`.
3. **A self-hosted runner on the Mac:** free minutes, but a background service on the owner's laptop that runs workflow code.

## Decision
Option 2.
- `Packages/ModelRuntime`: `MLXModelClient` (a AegisKit `ModelClient`) and the `ModelService` executable that serves it over XPC; pins exactly as ADR-0011.
- `make app` (`scripts/build-app.sh`): builds the Xcode project team-signed, builds ModelRuntime, swaps the executable in, copies MLX's Metal kernels (`mlx-swift_Cmlx.bundle`) into `Contents/Resources`, re-signs ModelService (`dev.aegis.model`, hardened runtime) and then the app, and verifies the signature.
- The model loads from Aegis's folder (`~/Library/Application Support/Aegis/Models/`) or the pinned Hugging Face snapshot (ADR-0006); never downloaded at run time.
- `model-smoke` checks the MLX client offline with synthetic events (`sandbox-exec` denying network).

## Consequences
- CI never compiles MLX; the MLX code is checked on the Mac (`make app`, `model-smoke`) before merging.
- First synthetic run on the owner's MacBook Air M1 (12 example events, network denied): load 1.5–2.5 s, first words 8–13 s, whole brief 31–36 s, peak 3.0 GB; the draft passed every brief check (7 items, 3 urgent).
- ADR-0011's MLX pins are adopted for ModelService (Checkpoint 1).
- The prompt now states the brief checks' budget ("at most 7 items… at most 3 urgent"; it said 8), in both the Python and Swift copies.
