#!/usr/bin/env bash
# Create today's handoff note from the template.
# Usage: scripts/handoff.sh <agent> <issue-number>
set -euo pipefail
[[ $# -lt 2 ]] && { echo "usage: $0 <agent> <issue>"; exit 1; }
root="$(git rev-parse --show-toplevel)"
date="$(date +%Y-%m-%d)"
file="$root/docs/handoffs/${date}-$1-$2.md"
if [[ -f "$file" ]]; then echo "$file already exists"; exit 0; fi
sed -e "s/\[agent\]/$1/" -e "s/\[number\]/$2/" -e "s/\[date\]/$date/" "$root/docs/handoffs/TEMPLATE.md" > "$file"
echo "$file"
