#!/usr/bin/env bash
# One-time (and safe to re-run) Mac setup for Aegis development.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n▸ %s\n' "$1"; }

if [[ "$(uname)" != "Darwin" ]]; then
  echo "bootstrap is for macOS. On Linux, use: make test-core && make guard"; exit 1
fi

say "Checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode not found or not selected. Install Xcode from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
xcodebuild -version | head -1

say "Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it from https://brew.sh, then re-run: make bootstrap"; exit 1
fi

say "Installing tools from Brewfile (xcodegen, swiftlint, swiftformat, gh, python, node)"
brew bundle --file=Brewfile

say "Enabling git hooks (privacy guard before every commit)"
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh

say "Generating Aegis.xcodeproj"
xcodegen generate

say "Running core tests"
(cd Packages/AegisKit && swift test)

say "Done. Open Aegis.xcodeproj in Xcode and press Run. Next: docs/workflow/SETUP.md step 2."
