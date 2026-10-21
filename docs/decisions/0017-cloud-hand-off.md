# ADR-0017: Handing non-personal questions to Claude or ChatGPT

**Status:** Accepted (owner's request, 2026-10-12) · **Issue:** #223

## Context
The owner asked that Aegis "pass tasks directly to Claude or ChatGPT if it's too complex and not personal-info related", with the answer shown in Aegis. Until now nothing the owner says left the Mac (principle 1).

## Decision
- **Off by default.** It works only after the owner saves an API key (Anthropic for Claude, OpenAI for ChatGPT) under *Claude and ChatGPT…* in the menu. Keys are kept in the Mac's Keychain, never in files or logs.
- **When:** the owner names a provider ("Ask Claude…", "Ask ChatGPT…"); a follow-up to the last hand-off ("make it shorter"); or, if the owner turns on *automatic*, a complex general question (explain, write, plan, code, compare, or 30+ words) that the owner's own data didn't cover.
- **What goes:** only the owner's own words and earlier turns of the same hand-off, plus fixed instructions. Never the brief, messages, mail, notifications, calendar, contacts, NOTES or memory.
- **The gate is deterministic and runs in AegisCore** (`CloudHandOff` in AegisKit). A question stays on the Mac if it mentions the owner's messages, mail, calendar, people, accounts, health or home, a contact's name, an email address, a phone or account number, or a street address. When in doubt, it stays. A named hand-off that fails the gate is answered locally, and Aegis says why.
- **AegisCore never connects to the internet.** It returns the approved request; the panel app sends it (`api.anthropic.com/v1/messages` with `claude-opus-5-5`, or `api.openai.com/v1/chat/completions` with the newest `gpt-N.N` the key can use), shows the reply marked "via Claude" or "via ChatGPT", and reads its opening aloud.
- Replies are data: they're shown and spoken, never acted on. They're kept in the conversation and memory's exchanges on the Mac.

## Consequences
- AGENTS.md principle 1 now lists this as an allowed network use. The question text goes to Anthropic or OpenAI under the owner's own API account and their retention terms.
- Each answer costs a few cents on the owner's API account.
- False positives (a general question kept local because it looks personal) are accepted. A false negative would leak, so the gate is conservative and its tests cover the personal categories.

## Amendment (2026-10-12, #235): the owner's ChatGPT plan, and tasks
The owner asked to use their existing ChatGPT plan rather than only API keys, and for tasks as well as answers.

**ChatGPT without a key.** ChatGPT can run through the Codex tool inside ChatGPT.app, signed in with the owner's plan. This is on by default and can be switched off under *Claude and ChatGPT…*. An OpenAI key, if saved, wins. Claude follows the same way once Claude Code is installed.

**Questions** run `codex exec` read-only in an empty temporary folder, with:
- `--ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check`;
- `--` before the prompt;
- instructions to answer without running commands or reading files.

**Tasks** ("get ChatGPT to make a spreadsheet…") run `workspace-write` in their own folder under `~/Aegis Tasks`:
- The folder is named from the date and letters/digits of the request, and checked by real path to sit inside the base and not be a symlink.
- The owner must press **Start**: the action-safety policy treats it as a file create, at confirm tier.
- The action log records IDs and codes only.
- There's a 20-minute timeout and a Stop button.
- Through an API key instead, the reply is saved into the folder.

**Containment (from DeepSeek's review):** Codex runs as its own launchd job, not as a child of Aegis, so it doesn't inherit Aegis's privacy permissions.
- It gets a fresh HOME and TMPDIR. Only `CODEX_HOME` points at the owner's sign-in.
- Stop and timeout boot the job out, which ends its whole process group.
- The transcript and reply are deleted at once.

**Gate additions (from the same review):**
- Personal nouns without "my" ("the landlord", "the doctor", "the email…").
- First-person debt and symptoms, children's ages, and dated parties.
- Fines and refunds, and employer domains.
- Providers' replies are re-checked as if the owner said them ("your" → "my").
- The whole outbound payload is gated together.
- At most two earlier turns are sent.

**Residual risk:** a task's agent can still read files its own permissions allow, and what it reads goes to OpenAI as context. Its input is only the owner's gated words, and the sandbox confines its writes.
