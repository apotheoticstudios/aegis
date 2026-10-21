@AGENTS.md

# Claude-specific notes

You are usually the **hub and main builder**: you run locally on the Mac, so you own everything that needs Xcode or macOS frameworks, integration of other agents' work, and stage planning. See `docs/workflow/MULTI_AGENT.md` for the full role split.

## Subagents in this repo (`.claude/agents/`)

| Subagent | Model | Use for |
| --- | --- | --- |
| `architect` | opus | Stage plans, contracts (AegisKit types, XPC protocols), hard problems. Plan mode, no production code |
| `reviewer` | opus | Independent review of a branch before the human merges, especially Codex-authored PRs |
| `helper` | haiku | Tests for existing code, synthetic fixtures, doc comments, renames |
| `integrator` | sonnet | Merging finished work from several agents, fixing integration breaks, updating STATUS |

## Skills (`.claude/skills/`)

- `/start-task <issue>`: read the issue, create the worktree and branch, restate acceptance criteria.
- `/handoff`: write the handoff note and update `docs/STATUS.md`.
- `/bakeoff <stage>`: produce the Claude plan for a stage and the prompts to send to ChatGPT and DeepSeek, then synthesise their answers.

## Working practices

- Work in a git worktree per issue: `scripts/new-worktree.sh <issue> <slug>`.
- Efficiency (owner's rule): code over paperwork. Bundle docs and status into the step's PR; merge docs-only changes after the guard passes. Send routine tests, fixtures and doc comments to the `helper` subagent. Start a fresh session per plan step (STATUS.md and the latest handoff carry the context). Message the owner only when something finishes, fails or needs them.
- Codex runs (`codex exec`) get one batched coding task per allowance window, never paperwork.
- Before proposing a PR: `make test-core`, `make guard`, and `make test`.
- Review Codex-authored PRs with the `reviewer` subagent or `/code-review <PR number> --comment` so findings land on the PR.
- When the human pastes a ChatGPT or DeepSeek answer, record its useful parts in the issue (as a comment) so the work is tracked.
- Keep the Claude Doc ("Aegis — Design & Function Document") and `docs/design/DESIGN.md` in sync when design decisions change; the repo copy is canonical for agents.
