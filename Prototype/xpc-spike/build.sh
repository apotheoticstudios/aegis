#!/usr/bin/env bash
# Builds the XPC routing spike (Stage 1, issue #67) into Prototype/output/xpc-spike/ (gitignored):
# the app, the AegisCore and ModelService stand-ins inside Contents/MacOS, their launchd plists inside
# Contents/Library/LaunchAgents, and two copies of a client ModelService must refuse. The app and agents
# are signed with the Apple Development identity, so the requirements pin the team; each binary has its
# own signing identifier. The impostors are ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
out="../output/xpc-spike"
app="$out/Aegis XPC Spike.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
cp .build/release/spike-app "$app/Contents/MacOS/AegisXPCSpike"
cp .build/release/model-agent .build/release/core-agent "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/dev.aegis.xpcsigned.model.plist Resources/dev.aegis.xpcsigned.core.plist "$app/Contents/Library/LaunchAgents/"
# Team-signed only: macOS remembers an agent's first signature, so registering these labels ad hoc
# would stop a later team-signed build from launching (STAGE-1-SPIKES.md 1.5b).
identity=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
if [ -z "$identity" ]; then
    echo "No Apple Development signing identity (Xcode › Settings › Accounts › Manage Certificates)." >&2
    exit 1
fi
codesign --force --sign "$identity" --identifier dev.aegis.xpcsigned.model "$app/Contents/MacOS/model-agent"
codesign --force --sign "$identity" --identifier dev.aegis.xpcsigned.core "$app/Contents/MacOS/core-agent"
codesign --force --sign "$identity" "$app"
codesign --verify --deep "$app"
cp .build/release/rogue-client "$out/rogue-wrong-id"
cp .build/release/rogue-client "$out/rogue-spoofed-id"
codesign --force --sign - --identifier dev.aegis.xpcsigned.rogue "$out/rogue-wrong-id"
codesign --force --sign - --identifier dev.aegis.xpcsigned.core "$out/rogue-spoofed-id"
echo "Built: $(cd "$out" && pwd)"
