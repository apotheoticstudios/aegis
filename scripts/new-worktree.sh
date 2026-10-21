#!/usr/bin/env bash
# Create a git worktree + branch for one issue, so parallel agents never share a working copy.
# Usage: scripts/new-worktree.sh <issue-number> <short-slug> [agent]   (agent defaults to claude)
set -euo pipefail
[[ $# -lt 2 ]] && { echo "usage: $0 <issue> <slug> [agent]"; exit 1; }
issue="$1"; slug="$2"; agent="${3:-claude}"
root="$(git rev-parse --show-toplevel)"
branch="${agent}/${issue}-${slug}"
dir="$(dirname "$root")/$(basename "$root")-worktrees/${agent}-${issue}-${slug}"

git -C "$root" fetch -q origin 2>/dev/null || true
base="main"; git -C "$root" rev-parse -q --verify origin/main >/dev/null && base="origin/main"

if git -C "$root" rev-parse -q --verify "$branch" >/dev/null; then
  git -C "$root" worktree add "$dir" "$branch"
else
  git -C "$root" worktree add -b "$branch" "$dir" "$base"
fi
echo "Worktree ready: $dir (branch $branch)"
echo "If project.yml matters for this task, run: (cd \"$dir\" && make generate)"
