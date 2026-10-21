#!/bin/bash
# One-time move of an installed Jarvis to Aegis (ADR-0028): stops the old app and its agents,
# moves its data folder and copies its settings. Reads no file contents. Safe to run twice.
set -euo pipefail

support="$HOME/Library/Application Support"
uid=$(id -u)

pkill -x Jarvis || true
pkill -x Aegis || true
for agent in dev.jarvis.core dev.jarvis.model dev.aegis.core dev.aegis.model; do
    launchctl bootout "gui/$uid/$agent" 2>/dev/null || true
done

# Merge: `make app` may already have made Aegis/Models; anything already in Aegis wins.
if [ -d "$support/Jarvis" ]; then
    mkdir -p "$support/Aegis"
    for item in "$support/Jarvis"/* "$support/Jarvis"/.[!.]*; do
        [ -e "$item" ] || continue
        name=$(basename "$item")
        target="$support/Aegis/${name/jarvis.sqlite/aegis.sqlite}"
        if [ -e "$target" ]; then
            [ -d "$item" ] && [ -d "$target" ] && { cp -Rn "$item"/. "$target"/ || true; } # cp -n exits 1 when it skips
        else
            mv "$item" "$target"
        fi
    done
    rm -rf "$support/Jarvis"
    echo "moved data folder"
fi

if defaults read dev.jarvis.app >/dev/null 2>&1; then
    defaults export dev.jarvis.app - | defaults import dev.aegis.app -
    defaults rename dev.aegis.app listenForHeyJarvis listenForHeyAegis 2>/dev/null || true
    defaults delete dev.jarvis.app
    echo "copied settings"
fi

if [ -d /Applications/Jarvis.app ]; then
    rm -rf /Applications/Jarvis.app
    echo "removed old app"
fi
