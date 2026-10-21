#!/usr/bin/env bash
# Builds the Full Disk Access test app (Stage 0, issue #11) into Prototype/output/agent-fda/
# (gitignored): the app, its launch agent inside Contents/MacOS, and the agent's launchd plist
# inside Contents/Library/LaunchAgents, all signed ad hoc for local testing.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
app="../output/agent-fda/Aegis Agent FDA Test.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
cp .build/release/fda-test-app "$app/Contents/MacOS/AegisAgentFDATest"
cp .build/release/fda-agent "$app/Contents/MacOS/fda-agent"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/dev.aegis.fdatest.agent.plist "$app/Contents/Library/LaunchAgents/"
codesign --force --sign - "$app/Contents/MacOS/fda-agent"
codesign --force --sign - "$app"
codesign --verify --deep "$app"
echo "Built: $(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
