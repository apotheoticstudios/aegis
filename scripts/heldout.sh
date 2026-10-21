#!/bin/bash
# make heldout — Stage 1 step 3.2 (#131): the SYNTHETIC held-out dense day through the real readers,
# CoreEngine and Qwen3.5-4B on MLX, then the independent scorer (#132). Mac only; needs the model in
# the Hugging Face cache or ~/Library/Application Support/Aegis/Models (ADR-0014). Prints counts only.
set -euo pipefail
cd "$(dirname "$0")/.."
seed="${SEED:-7}"
out=build/heldout
rm -rf "$out" && mkdir -p "$out"
python3 Fixtures/generate/generate.py "$out/fixture" --profile stage1 --seed "$seed" >/dev/null
(cd Packages/ModelRuntime && xcodebuild -scheme heldout-run -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath ../../build/ModelRuntime \
    -skipMacroValidation -skipPackagePluginValidation build -quiet)
build/ModelRuntime/Build/Products/Release/heldout-run "$out/fixture" "$out/run"
if [ -f Fixtures/score/score_heldout.py ]; then
    python3 Fixtures/score/score_heldout.py --brief "$out/run/brief.json" --events "$out/run/events.jsonl" \
        --fixture "$out/fixture"
fi
