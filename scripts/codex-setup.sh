#!/usr/bin/env bash
# Install script for the Codex cloud environment (Linux). Safe to re-run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
chmod +x scripts/*.sh .githooks/* 2>/dev/null || true

echo "▸ Python: $(python3 --version 2>&1 || echo 'not found')"
echo "▸ Node:   $(node --version 2>&1 || echo 'not found')"

if command -v swift >/dev/null 2>&1; then
  echo "▸ Swift:  $(swift --version 2>&1 | head -1)"
  (cd Packages/AegisKit && swift build) && echo "✔ AegisKit builds"
else
  echo "✖ Swift is not installed in this environment."
  echo "  AegisKit tasks need Swift 6 for Linux. Ask Codex to install it here (e.g. via swiftly or the official"
  echo "  Swift toolchain for this Linux distribution), or limit this environment to Python/Node/docs/scripts tasks."
fi
exit 0
