#!/usr/bin/env bash
# Build-time model packaging only; no downloads at runtime (ADR-0019).
set -euo pipefail
cd "$(dirname "$0")/.."
destination=${1:?Pass the app resource directory}
cache=build/WakeAssets
archive="$cache/model.tar.bz2"
checksum=f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
mkdir -p "$cache" "$destination"
verify() { [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$checksum" ]; }
if [ ! -f "$archive" ] || ! verify; then
    curl --fail --location --retry 2 --max-time 180 --output "$archive.download" \
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2' # privacy-guard: allow-network pinned public keyword model at build time only
    mv "$archive.download" "$archive"
fi
verify || { echo 'Wake model checksum mismatch.' >&2; exit 1; }
temporary=$(mktemp -d "$cache/extract.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
model=sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
stem=epoch-12-avg-2-chunk-16-left-64
# Extract only verified model resources; no upstream speech recordings are shipped or used.
tar -xjf "$archive" -C "$temporary" "$model/encoder-$stem.int8.onnx" "$model/decoder-$stem.onnx" \
    "$model/joiner-$stem.int8.onnx" "$model/tokens.txt" "$model/bpe.model"
mkdir -p "$destination/WakeModels"
cp "$temporary/$model/encoder-$stem.int8.onnx" "$destination/WakeModels/encoder.int8.onnx"
cp "$temporary/$model/decoder-$stem.onnx" "$destination/WakeModels/decoder.onnx"
cp "$temporary/$model/joiner-$stem.int8.onnx" "$destination/WakeModels/joiner.int8.onnx"
cp "$temporary/$model/tokens.txt" "$destination/WakeModels/tokens.txt"
python3 scripts/wake-token-scores.py "$temporary/$model/bpe.model" "$destination/WakeModels/token-scores.json"
# SentencePiece encoding from the pinned model's bpe.model; the default keyword; custom names are configured in memory.
printf '▁HE Y ▁A E G IS @HEY_AEGIS\n' > "$destination/WakeModels/keywords.txt"
echo 'Bundled the verified offline Hey Aegis detector.'
