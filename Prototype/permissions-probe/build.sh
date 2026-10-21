#!/usr/bin/env bash
# Builds the permissions probe (Stage 1, issue #66) into Prototype/output/permissions-probe/ (gitignored):
# the app, its launch agent in Contents/MacOS and the agent's launchd plist in
# Contents/Library/LaunchAgents. Both are signed with the owner's Apple Development identity and the
# hardened runtime, so permission grants survive a rebuild (TCC follows the signing identity).
set -euo pipefail
cd "$(dirname "$0")"
identity=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
if [ -z "$identity" ]; then
    echo "No Apple Development signing identity. In Xcode: Settings › Accounts › Manage Certificates › + › Apple Development." >&2
    exit 1
fi
swift build -c release
app="../output/permissions-probe/Aegis Permissions Probe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
cp .build/release/probe-app "$app/Contents/MacOS/AegisPermissionsProbe"
cp .build/release/probe-agent "$app/Contents/MacOS/probe-agent"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/dev.aegis.permprobe.agent.plist "$app/Contents/Library/LaunchAgents/"
sign() { codesign --force --options runtime --timestamp=none --entitlements Resources/probe.entitlements --sign "$identity" "$@"; }
sign --identifier dev.aegis.permprobe.agent "$app/Contents/MacOS/probe-agent"
sign "$app"
codesign --verify --deep --strict "$app"
echo "Built: $(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
