#!/usr/bin/env bash
# Create the workflow labels on GitHub. Needs the GitHub CLI: `gh auth login` first.
set -euo pipefail
command -v gh >/dev/null || { echo "Install the GitHub CLI (brew install gh) and run: gh auth login"; exit 1; }

label() { gh label create "$1" --color "$2" --description "$3" --force >/dev/null && echo "✔ $1"; }

label "agent:claude"   "D97757" "Owned by Claude (Mac/Xcode, integration, contracts)"
label "agent:codex"    "10A37F" "Owned by Codex (Linux-buildable work)"
label "agent:chatgpt"  "74AA9C" "Owned by ChatGPT (research, assets)"
label "agent:deepseek" "4D6BFE" "Owned by DeepSeek (edge cases, fixtures, opinions)"
label "agent:human"    "5319E7" "Owned by the human (real data, real Mac, secrets)"
for s in 0 1 2 3 4 5 6 7 8; do label "stage:$s" "BFD4F2" "Development stage $s"; done
for a in core collectors model ui voice home control world shell infra docs; do label "area:$a" "C5DEF5" "Module: $a"; done
label "type:contract"  "B60205" "Changes shared types or XPC protocols - merge first"
label "type:research"  "FBCA04" "Research question"
label "type:asset"     "F9D0C4" "Images, icons, sounds"
label "type:decision"  "0E8A16" "Needs an ADR"
label "type:bug"       "D73A4A" "Something is broken"
label "status:blocked" "000000" "Waiting on something"
label "status:needs-review" "1D76DB" "Ready for cross-vendor review"
