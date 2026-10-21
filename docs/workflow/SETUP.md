# One-time setup

About an hour, once. Do the steps in order.

## 1. Mac development tools

1. Install **Xcode** from the Mac App Store, open it once and accept the licence.
2. Install **Homebrew** from https://brew.sh (copy the one-line command from that page into Terminal).
3. In Terminal, go to this folder and run:
   ```
   make bootstrap
   ```
   This installs XcodeGen, SwiftLint, SwiftFormat, the GitHub CLI and Python (from `Brewfile`), turns on the repo's git hooks (privacy guard before every commit), and generates `Aegis.xcodeproj`.
4. Open `Aegis.xcodeproj` in Xcode and press Run. You should see the scaffold window. That's the whole app for now.

## 2. GitHub (with GitHub Desktop)

1. Open **GitHub Desktop**, add this folder as an existing local repository, and make the first commit (e.g. "Agent framework and dev setup").
2. **Publish repository**, keeping **Keep this code private** ticked.
3. On github.com, in the repo's settings (optional but recommended):
   - Protect the `main` branch: require a pull request and the `core` and `guard` CI checks before merging.
   - Under Actions, allow workflows to run.
4. Create the labels: in Terminal run `gh auth login` once, then `scripts/setup-labels.sh`. (Or create them by hand from the table in `MULTI_AGENT.md`.)

## 3. Claude (hub and main builder)

1. In the **Claude desktop app**, open the **Code** tab (needs a paid Claude plan).
2. Choose **Local**, **Select folder** → this repo folder.
3. Pick **Sonnet** as the default model for building; the repo's subagents switch to Opus or Haiku automatically.
4. Try: `/bakeoff 0` to plan Stage 0.

Claude reads `CLAUDE.md`, which imports `AGENTS.md`, plus the subagents, skills and permission rules in `.claude/`.

## 4. ChatGPT Plus: Codex and a Aegis project

**Codex (cloud tasks and PR reviews)**
1. In ChatGPT, open Codex and connect your GitHub account; give it access to this repository.
2. Create a cloud **environment** for the repo. In its install script, use:
   ```
   bash scripts/codex-setup.sh
   ```
   This checks for Swift and Python and runs the core tests. If Swift is missing in the environment, the script tells you; Codex can then still do Python, Node, docs and scripts, and you can give it the Swift install command it suggests.
3. Turn on **automatic code review** for this repository in Codex's settings. It will review PRs using the "Code Review Rules" in AGENTS.md. You can also comment `@codex review` on any PR.
4. Codex reads `AGENTS.md` automatically.

**ChatGPT project (research, images, bake-offs)**
1. Create a ChatGPT project called **Aegis**.
2. Add `docs/design/DESIGN.md`, `AGENTS.md` and `docs/workflow/MULTI_AGENT.md` as project files. Re-upload DESIGN.md when it changes.
3. Use this project for research questions, image generation and plan bake-offs (prompts in `docs/workflow/prompts/`).

## 5. DeepSeek (free)

1. Sign in at https://chat.deepseek.com.
2. For each conversation, paste the relevant prompt from `docs/workflow/prompts/` (they include the context DeepSeek needs).
3. Paste useful answers back into the GitHub issue, starting the comment with `DeepSeek:`.
4. Never paste secrets or real personal data.

## 6. Check everything works

- [ ] `make test-core` and `make guard` pass in Terminal
- [ ] The app builds and runs from Xcode
- [ ] The repo is on GitHub (private) and the CI run on the first commit is green
- [ ] Claude Code opens the repo and lists the `architect`, `reviewer`, `helper` and `integrator` subagents
- [ ] Codex can see the repo, its environment setup passes, and automatic review is on
- [ ] The ChatGPT "Aegis" project has DESIGN.md, AGENTS.md and MULTI_AGENT.md
- [ ] Labels exist on GitHub

Then start Stage 0: in Claude Code, `/bakeoff 0`.
