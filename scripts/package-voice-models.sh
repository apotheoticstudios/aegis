#!/usr/bin/env bash
# Build-time public model download only (#221, ADR-0018). Runtime speech never uses the network.
set -euo pipefail
cd "$(dirname "$0")/.."
destination=${1:?Pass the app resource directory}
cache=build/VoiceAssets
archive="$cache/kokoro-models.tar.gz"
checksum=0d24bbf80526456bd8640f9f484cd1c333aee8a936e618ac44e619eafb79aec9
mkdir -p "$cache" "$destination"
verify() { [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$checksum" ]; }
if [ ! -f "$archive" ] || ! verify; then
    curl --fail --location --retry 2 --max-time 180 --output "$archive.download" \
        'https://github.com/Jud/kokoro-coreml/releases/download/models-2026-03-23/kokoro-models.tar.gz' # privacy-guard: allow-network pinned public model download at build time only
    mv "$archive.download" "$archive"
fi
verify || { echo 'Voice model checksum mismatch.' >&2; exit 1; }
temporary=$(mktemp -d "$cache/extract.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
# The pinned archive is verified before extraction. Ship only the selected voice, not the studio's library.
tar -xzf "$archive" -C "$temporary" kokoro_frontend.mlmodelc kokoro_backend.mlmodelc voices/bm_george.bin
rm -rf "$destination/VoiceModels"
mv "$temporary" "$destination/VoiceModels"
trap - EXIT
echo 'Bundled the verified local speech model and George voice.'
