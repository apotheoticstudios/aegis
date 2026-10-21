# MLX Swift spike: Qwen3.5-4B in Swift (issue #54)

A throwaway Swift program that checks the app's model runtime: MLX Swift (`mlx-swift-lm`, ADR-0011) running Qwen3.5-4B (ADR-0009) from the files already on disk, with no network. Nothing here ships. The results are in `docs/stages/STAGE-1-SPIKES.md`.

## Build (Mac with Xcode)

```
cd Prototype/model-swift
xcodebuild -downloadComponent MetalToolchain     # once; MLX compiles its GPU kernels with it (839 MB)
xcodebuild -scheme MLXSwiftSpike -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-xcode \
  -skipMacroValidation -skipPackagePluginValidation -configuration Release build
```

Build with `xcodebuild`, not `swift build`: command-line SwiftPM can't compile MLX's Metal shaders. The build output (about 1–2 GB) goes in `.build-xcode/`, which git ignores; delete it when you're done.

## Run (synthetic inputs only)

```
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  .build-xcode/Build/Products/Release/mlx-brief MODEL_DIR fixture.spec.json examples.spec.json long.spec.json
```

- **`MODEL_DIR`:** the pinned Qwen3.5-4B snapshot in the Hugging Face cache (ADR-0006).
- **The spec files:** `{"system", "user", "max_tokens"}`, exactly what `Prototype/model/mlx_worker.py` takes, built from the fixture day, the 12 examples and the long input.
- **What it does:** loads the model once, writes each brief with greedy decoding (thinking off), then releases the model and reports how much memory came back.
- **Output:** one JSON line per step, holding timings and memory plus the answer text (synthetic).
