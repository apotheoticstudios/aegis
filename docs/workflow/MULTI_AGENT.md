# How the AIs work together on Aegis

Three AI services build Aegis alongside the human owner. They never talk to each other directly: they meet in this **GitHub repo**, follow the same **AGENTS.md**, build from the same **DESIGN.md**, and pick up work from **GitHub issues**. The human approves plans and merges.

## Who does what

| Who | Where it runs | Best at | Owns |
| --- | --- | --- | --- |
| **Claude** (Claude Code in the Claude desktop app, on the Mac) | Locally, with Xcode | macOS frameworks, Xcode builds, integration, planning, orchestrating subagents | Everything that needs a Mac to build or test; stage planning; integration; contracts |
| **Codex** (included in ChatGPT Plus) | OpenAI's cloud, connected to this GitHub repo | Parallel tasks in the cloud while Claude works locally; automatic PR reviews | Linux-buildable work (see below); reviewing every Claude-written PR |
| **ChatGPT** (chat, in a "Aegis" project) | ChatGPT app/web | Research, images, design discussion, plan bake-offs | Research issues, visual assets, second plans |
| **DeepSeek** (free web chat, copy-paste only) | chat.deepseek.com | An independent third brain: alternatives, edge cases, test ideas, fixture text | Bake-off opinions, edge-case lists, optional third review |
| **Human** (you) | Your Mac + GitHub Desktop | Judgement, real data, permissions, secrets | Approving plans, merging, running Aegis on real data, the real-Mac tests |

### What Codex can build (Linux-buildable work)

Codex cloud environments can't build macOS apps, so Codex gets the work that builds on Linux:

- `Packages/AegisKit`: event model, rules engine, triage pipeline logic, prompt builders, parsers that work on fixture files, XPC message types (after the contract is approved)
- Fixture generators and synthetic test data
- `Prototype/` Python scripts (written and tested against fixtures; the human runs them on real data)
- The World view sidecar (God's Eye View, Node/JavaScript)
- CI, scripts, docs

Claude gets everything that imports AppKit, SwiftUI, EventKit, HomeKit, Metal, MLX, WidgetKit, or needs Xcode.

> Overflow: if Claude's usage limit is reached, the Codex CLI or the ChatGPT desktop app can run locally on the Mac and use Xcode too. Give it `agent:codex` issues the same way.

### Getting full value from ChatGPT Plus

1. **Codex cloud tasks** run in parallel with Claude: every stage should have Codex issues.
2. **Codex automatic review** on every PR (set up in `SETUP.md`). It reads the "Code Review Rules" in AGENTS.md.
3. **`@codex` in PR comments** to fix review findings or CI failures on Codex-owned PRs, e.g. `@codex fix the failing test-core job`.
4. **ChatGPT research:** deep questions about Apple APIs and macOS behaviour (e.g. "how does the Notification Center database store iPhone Mirroring notifications on macOS 26?"). Answers go into the issue as a comment, with sources.
5. **ChatGPT images:** app icon, menu bar icon studies, reactor textures, marketing art (prompt in `prompts/chatgpt-assets.md`). Final assets go in an issue for Claude to add.
6. **Plan bake-offs:** ChatGPT gives an independent plan for each stage.

### Getting real value from DeepSeek (free, no API)

DeepSeek has no access to the repo, so give it self-contained, high-value thinking tasks and copy its answers back:

1. **Bake-off third opinion** on every stage plan and hard design question.
2. **Edge-case and test-idea lists** for a module (prompt in `prompts/deepseek-edge-cases.md`), which become tests.
3. **Synthetic fixture text**: realistic invented messages, emails, notifications for test data.
4. **Optional third review** of risky diffs (safety system, permissions): paste the diff with `prompts/cross-review.md`.

Paste results into the relevant GitHub issue as a comment starting with `DeepSeek:` so the contribution is tracked. Never paste secrets, real personal data, or anything you wouldn't publish; DeepSeek's hosted service processes data under its own privacy policy, with servers in China.

## The life of a stage

1. **Plan (bake-off).** In Claude Code run `/bakeoff <stage>`. Claude's architect writes a plan and gives you one prompt to paste into ChatGPT and DeepSeek. Paste their answers back; Claude synthesises one plan into `docs/stages/STAGE-<n>.md` and lists the issues with owners.
2. **You approve** the stage file (edit anything you disagree with).
3. **Create issues** from the stage file (Claude can do it with `gh`, or create them on GitHub with the Task template). Each has an owner label, a stage label and acceptance criteria.
4. **Contracts first.** Claude does the contract issue (AegisKit types, XPC protocols). Merge it before anything else.
5. **Build in parallel.**
   - Claude: 2–4 local worktrees (`/start-task <issue>`), one per Mac issue.
   - Codex: start each `agent:codex` issue as a cloud task (paste the issue text, or use `prompts/codex-task.md`). Codex opens a PR from its branch.
   - ChatGPT / DeepSeek: research, assets and edge-case lists for the issues that need them.
6. **Cross-vendor review.**
   - Claude-written PR → Codex reviews automatically (or comment `@codex review`).
   - Codex-written PR → Claude reviews: in Claude Code run `/code-review <PR number> --comment`, or ask the `reviewer` subagent.
   - Safety/permission/privacy-heavy PR → also paste into DeepSeek with `prompts/cross-review.md`.
   - CI must be green: core tests on Linux, privacy guard, and (when needed) the macOS build.
7. **Merge.** You merge in GitHub Desktop or on GitHub, contracts first, then modules, then wiring. Claude's `integrator` subagent can prepare the order and catch integration breaks.
8. **Close the stage.** Dogfood on your Mac, run the stage's "done when" test, privacy review, budget check, then update DESIGN.md (and the Claude Doc) and STATUS.md.

## Labels

| Label | Meaning |
| --- | --- |
| `agent:claude`, `agent:codex`, `agent:chatgpt`, `agent:deepseek`, `agent:human` | Who owns the issue |
| `stage:0` … `stage:8` | Development stage |
| `area:core`, `area:collectors`, `area:model`, `area:ui`, `area:voice`, `area:home`, `area:control`, `area:world`, `area:shell`, `area:infra`, `area:docs` | Module |
| `type:contract` | Changes shared types or XPC protocols — merges first |
| `type:research`, `type:asset`, `type:decision` | Non-code work |
| `status:blocked`, `status:needs-review` | Workflow state |

Create them once with `scripts/setup-labels.sh` (needs the GitHub CLI), or by hand on GitHub.

## Branches and conflicts

- Branch: `<agent>/<issue>-<slug>`. One writer per branch.
- `main` is protected by habit (and by GitHub branch protection if you enable it): everything arrives by PR.
- The Xcode project is generated from `project.yml`, so agents never conflict over `.xcodeproj` files.
- Shared types change only through `type:contract` issues owned by Claude's architect and approved by you.
- If two PRs conflict, the later one rebases; the owner of that branch fixes it.

## Handoffs (memory between sessions)

Chat AIs forget between sessions; the repo doesn't. Every working session ends with a short handoff note in `docs/handoffs/` (Claude: `/handoff`; Codex doesn't write them: Claude records Codex's work; ChatGPT/DeepSeek: paste their summary into the issue). Keep it to a few lines; AGENTS.md's "How we work" sets the paperwork limits. New sessions start by reading `docs/STATUS.md` and the latest handoffs for their issue.

## Costs and limits

- ChatGPT Plus and Claude plans have usage limits; parallel work spends them faster. Use Claude's `helper` (Haiku) for routine work and save Opus for planning and review.
- GitHub Actions minutes for private repos are limited, and macOS minutes count much more than Linux. CI runs the cheap Linux checks on every PR and the macOS build only when app code changes or when you run it manually.
