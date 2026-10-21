# ADR-0011: MLX Swift (`mlx-swift-lm`) for the Stage 1 model spike

- **Status:** accepted for the spike (the owner OK'd the downloads on 2026-10-08); adopted for ModelService at Checkpoint 1 (2026-10-09, ADR-0014)
- **Date:** 2026-10-08
- **Proposed by:** Claude · **Approved by:** human

## Context
Stage 0 measured Qwen3.5-4B with Python `mlx-lm` (ADR-0006). The app is Swift and must run the model in its ModelService, so Stage 1's first risk is whether MLX Swift loads this model and keeps Stage 0's quality, speed and memory (#54, spike 1b of the bake-off in #53).

## Options considered
1. **`mlx-swift-lm`** (Apple's ml-explore project): the Swift side of the same MLX engine and model files. Its release notes and source include Qwen3.5 (`Qwen35.swift`, gated-delta kernels).
2. **Bundle Python `mlx-lm`:** a Python runtime inside a Mac app is heavy and fragile, and doesn't fit ADR-0001 (native Swift).
3. **llama.cpp:** mature, but a different engine and file format from Stage 0's numbers.

## Decision
For the spike (`Prototype/model-swift/`, throwaway), pinned exactly:

| Package | Version | Licence | Role |
| --- | --- | --- | --- |
| ml-explore/mlx-swift-lm | 3.32.3 | MIT | LLM loading and generation (MLXLLM, MLXLMCommon) |
| ml-explore/mlx-swift (with the MLX core and mlx-c) | 0.32.x | MIT | the array engine and Metal kernels |
| huggingface/swift-transformers | 1.3.4 | Apache-2.0 | the tokenizer and chat template |

**Pulled in by those:**
- swift-jinja, swift-huggingface, swift-collections, swift-crypto, swift-asn1 and swift-numerics (Apache-2.0);
- yyjson and EventSource (MIT);
- swift-syntax (Apache-2.0; prebuilt macro support, which mlx-swift-lm declares even though the spike uses no macros).

**How it runs:**
- The model loads from the folder already on disk, the ADR-0006 revision, with no downloader.
- Runs happen with network access denied (`sandbox-exec`).
- Builds use `xcodebuild`, because command-line SwiftPM can't compile MLX's Metal shaders.

## Consequences
- All licences are MIT or Apache-2.0, which keeps a future public release open.
- The package downloads are the only network use, done once with the owner's OK. The build output (about 1–2 GB) lives in the spike's `.build-xcode/` (gitignored) and can be deleted.
- A Swift package's identity comes from its folder name. The spike folder can't be called `mlx-swift`: it clashed with the dependency of that name and stopped resolution.
- If the spike holds up, the ModelService adopts the same pins through `project.yml` (Checkpoint 1).
