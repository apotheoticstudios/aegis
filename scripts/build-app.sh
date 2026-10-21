#!/usr/bin/env bash
# Builds the Aegis.app the owner installs (ADR-0014): the Xcode project, team-signed, with the real MLX
# ModelService in place of the placeholder CI builds. Output: build/Aegis.noindex/Aegis.app. Mac only; needs the Apple
# Development certificate and Apple's Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Config/Signing.local.xcconfig ] || ./scripts/signing-config.sh
# Build copies live in .noindex folders (Spotlight skips them) and are unregistered from Launch Services below,
# so the only Aegis that shows up anywhere is the installed /Applications/Aegis.app (owner's request).
mkdir -p build
identity=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
if [ -z "$identity" ]; then
    echo "No Apple Development signing identity (Xcode › Settings › Accounts › Manage Certificates)." >&2
    exit 1
fi
xcodegen generate
# The memory meaning model (#309): downloaded once, checked by SHA-256.
./scripts/fetch-meaning-model.sh
xcodebuild -project Aegis.xcodeproj -scheme AegisApp -configuration Release \
    -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/App.noindex build
(cd Packages/ModelRuntime && xcodebuild -scheme ModelService -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath ../../build/ModelRuntime \
    -skipMacroValidation -skipPackagePluginValidation build)

app=build/Aegis.noindex/Aegis.app
models=build/ModelRuntime/Build/Products/Release
rm -rf "$app" && mkdir -p "$(dirname "$app")"
cp -R build/App.noindex/Build/Products/Release/Aegis.app "$app"
cp "$models/ModelService" "$app/Contents/MacOS/ModelService"
# MLX finds its Metal kernels in this bundle under the app's Resources.
cp -R "$models/mlx-swift_Cmlx.bundle" "$app/Contents/Resources/"

./scripts/package-voice-models.sh "$app/Contents/Resources"
./scripts/package-wake-model.sh "$app/Contents/Resources"

sign() { codesign --force --options runtime --timestamp=none --sign "$identity" "$@"; }
sign --identifier dev.aegis.voice "$app/Contents/XPCServices/AegisVoice.xpc"
sign --identifier dev.aegis.model "$app/Contents/MacOS/ModelService"
sign --preserve-metadata=identifier,entitlements,requirements,flags "$app"
codesign --verify --deep --strict "$app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -u "$app" build/App.noindex/Build/Products/Release/Aegis.app 2>/dev/null || true
echo "Built: $(pwd)/$app"
