#!/bin/bash
# World view setup (#265, ADR-0024), run by Aegis on the first open: a pinned Node and a pinned God's Eye View in
# Aegis's private folder, both checked by SHA-256 (the app by its git commit if its archive's checksum differs).
# npm packages come from the lock file with install scripts off. Progress goes to setup-status, for the panel.
set -euo pipefail
node_version=v24.22.0
node_sha=6a9724d9b50a5f22b4816cded441b5a8d9ddae546191a5e5b7efa5a5e2ee26d5
commit=93ea088f4556a5a65b3292a2d15142d5a6c562bc
app_sha=52bca648c93f0437ad9e0897aff3c9bccc9f5d66a8ecb8586a050f4f6f57cfb0
root="${AEGIS_WORLD_DIR:-$HOME/Library/Application Support/Aegis/World}"
cache="$root/cache"
status() { printf '%s\n' "$1" > "$root/setup-status"; }
fail() { status "failed: $1"; echo "World view setup failed: $1" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
mkdir -p "$cache"
chmod 700 "$root"
trap 'status "failed: interrupted"' INT TERM

# 1. Node, unless the pinned one is already there.
if [ "$("$root/node/bin/node" --version 2>/dev/null || true)" != "$node_version" ]; then
    status "Downloading Node.js"
    archive="$cache/node-$node_version.tar.gz"
    if [ ! -f "$archive" ] || [ "$(sha "$archive")" != "$node_sha" ]; then
        curl --fail --silent --location --retry 2 --max-time 600 --output "$archive.download" \
            "https://nodejs.org/dist/$node_version/node-$node_version-darwin-arm64.tar.gz" || fail "Node download" # privacy-guard: allow-network pinned Node download, ADR-0024
        mv "$archive.download" "$archive"
    fi
    [ "$(sha "$archive")" = "$node_sha" ] || fail "Node checksum"
    rm -rf "$root/node.new"
    mkdir -p "$root/node.new"
    tar -xzf "$archive" -C "$root/node.new" --strip-components 1
    rm -rf "$root/node"
    mv "$root/node.new" "$root/node"
fi
export PATH="$root/node/bin:/usr/bin:/bin"

# 2. God's Eye View at the pinned commit, unless it's already built.
app="$root/gods-eye-view"
if [ "$(cat "$app/.aegis-commit" 2>/dev/null || true)" != "$commit" ] || [ ! -f "$app/dist/index.html" ]; then
    status "Downloading God's Eye View"
    fresh="$root/gods-eye-view.new"
    rm -rf "$fresh"
    mkdir -p "$fresh"
    archive="$cache/gods-eye-view-$commit.tar.gz"
    if [ ! -f "$archive" ] || [ "$(sha "$archive")" != "$app_sha" ]; then
        curl --fail --silent --location --retry 2 --max-time 600 --output "$archive.download" \
            "https://codeload.github.com/bilawalsidhu/gods-eye-view/tar.gz/$commit" || fail "app download" # privacy-guard: allow-network pinned public app download, ADR-0024
        mv "$archive.download" "$archive"
    fi
    if [ "$(sha "$archive")" = "$app_sha" ]; then
        tar -xzf "$archive" -C "$fresh" --strip-components 1
    elif command -v git >/dev/null 2>&1; then
        # GitHub's archives aren't byte-stable forever; the commit itself is the identity then.
        git -C "$fresh" init --quiet
        git -C "$fresh" fetch --quiet --depth 1 https://github.com/bilawalsidhu/gods-eye-view.git "$commit" || fail "app download" # privacy-guard: allow-network pinned public app download, ADR-0024
        [ "$(git -C "$fresh" rev-parse FETCH_HEAD)" = "$commit" ] || fail "app commit"
        git -C "$fresh" checkout --quiet FETCH_HEAD
    else
        fail "app checksum"
    fi
    status "Installing packages"
    (cd "$fresh" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error) || fail "packages" # privacy-guard: allow-network pinned npm packages, ADR-0024
    status "Building the globe"
    (cd "$fresh" && npm run --silent build >/dev/null) || fail "build"
    printf '%s\n' "$commit" > "$fresh/.aegis-commit"
    rm -rf "$app"
    mv "$fresh" "$app"
fi
status "done"
echo "World view ready."
