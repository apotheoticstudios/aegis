#!/usr/bin/env bash
# World view (#265, ADR-0024): Aegis runs this itself on the first open; this wrapper is for development.
exec "$(dirname "$0")/../Apps/AegisApp/Resources/World/world-setup.sh" "$@"
