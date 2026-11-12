# ADR-0038: Claude as Aegis's brain, through the owner's Claude plan

- **Status:** Accepted (owner's design choices and §6's decision, pure C, 2026-11-11; cross-vendor safety review folded in the same day).
- **Supersedes in part:** ADR-0017 (what may go to Claude) and AGENTS.md principles 1 and 4, for the Claude brain only. ADR-0031's tiers, plan card, never-list and action log still apply in full.

## Context

The owner wants to choose Claude instead of the local models as Aegis's brain, using their existing Claude plan (no API key), with Claude able to read everything Aegis can read and use every tool Aegis has. Today Claude is reachable only as a hand-off of the owner's own non-personal words, through an API key (ADR-0017). Claude Code is installed on the owner's Mac, signed in with their plan, and has a non-interactive mode (`claude -p`) that streams replies and accepts MCP servers.

## Options considered

| Option | Verdict |
| --- | --- |
| Anthropic API with a key | Rejected: the owner wants their plan, not per-token billing. |
| Hybrid (local for some jobs, Claude for others) | Rejected by the owner: one brain at a time, switchable. |
| Driving the Claude desktop app's UI (including its voice) | Rejected: no public interface; fragile; takes over audio and input. |
| **Claude Code headless, signed in with the owner's plan, with Aegis's data and tools offered over MCP** | **Chosen.** |

## Decision

### 1. One brain at a time
- The setup wizard gains a **Brain** step: **On this Mac** (today's local models) or **Claude (your plan)**. The same switch is in Settings and can be changed any time.
- Choosing Claude checks, inside the real launch environment (§4), that Claude Code runs and is signed in with a subscription, shows in plain words what will leave the Mac, and lets the owner skip the large local model (a small one stays as the fallback).
- With Claude chosen, the jobs the owner starts use Claude: chat, asks about the owner's data, command planning (ADR-0031, ADR-0032), meeting prep and reply drafts.
- **Jobs that run with the panel closed stay local**: scheduled briefs, learning and reflection. Claude never runs while the panel is closed (principle 2), so nothing reaches Anthropic without the owner in front of Aegis.

### 2. What always stays on the Mac
"Hey Aegis", speech recognition and the speaking voice (Kokoro); the collectors, the database and memory storage; instant answers (time, maths, conversions); the action log; the safety policy; the closed-panel jobs above.

**Fallback.** If Claude is unreachable, signed out or over the plan's limits (read from Claude Code's structured result, not by matching text), Aegis answers that request with the local model and says so once, **only if no action has run yet in that request**. If an action ran or its outcome is unknown, Aegis stops and shows what happened instead of replaying the request. Each action carries a stable operation ID recorded in the action log, so the same action never runs twice across a retry or a brain switch. Stop, closing the panel and switching brains first revoke the connector's authority, then end the job; an action Aegis already started (such as a shortcut) is reported as started, not as cancelled. There is no API-key fallback: billing by key would need its own owner opt-in.

### 3. Model picker
- Any model the owner's plan offers through Claude Code (for example Opus 5.5, Sonnet 5.5, Haiku 5.5, or Fable 5.2 where the plan includes it), read from Claude Code's `initialize` handshake (the interface the Agent SDK uses), not hard-coded; if discovery fails, the last good list is kept.
- Changeable from Settings, from a model chip in CHAT, and by voice ("use Sonnet"); plus an effort setting (quick / balanced / thorough → `low` / `medium` / `high`). Stored in Aegis's settings on the Mac.

### 4. How Aegis runs Claude
- **Command line, fixed and tested per supported Claude Code version:** `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`, `--model` and `--effort` from the picker, Aegis's own `--system-prompt`, `--no-session-persistence`, `--tools ""` (no shell, file, web or other built-in tools), `--strict-mcp-config` (plus `--mcp-config <Aegis's connector only>` from stage 2), an empty `--setting-sources`, `--safe-mode` (no instruction files, skills, plugins, hooks, custom agents or memory), `--restricted`, `--disable-slash-commands` and `--no-chrome`. Not `--bare`: it skips subscription sign-in. Tested with Claude Code 2.1.306.
- **Handshake before any prompt:** Aegis sends the `initialize`, `mcp_status` and `get_settings` control requests and sends the prompt only if the account is a first-party subscription sign-in with no API key, no commands are loaded, the MCP servers are only Aegis's, and no settings source applies (managed policy included). As the turn starts, Claude Code's `init` report is checked again (no tools, skills, commands, non-built-in plugins or API key) and the job is stopped if anything is wrong.
- **Environment:** a minimal, rebuilt environment. Credential, provider and endpoint overrides (such as `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, cloud-provider switches) are removed, so the job uses the owner's subscription sign-in and nothing else; the job keeps the real home folder and account name, which is how Claude Code finds the owner's sign-in in the Keychain (a fresh home folder signs it out); the sign-in is never copied, and safe mode and the empty settings sources keep the home folder's configuration from loading. Nonessential traffic is switched off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, plus disabling error reporting and feedback), and a synthetic-data session verifies that only Anthropic's inference endpoints are contacted.
- **Containment:** its own launchd job (as Codex in ADR-0017), with an empty working folder and its own temporary folder, so it is not a child of Aegis and does not run as Aegis's code identity. This is separation, not a sandbox: anything Claude Code itself has been granted, and files any process of the owner's account can read, remain reachable in principle; with no built-in tools and no customisations loaded, Claude has no way to use them. The owner validates permissions on a clean profile and one with earlier grants before stage 1 ships.
- **No transcript on disk:** the prompt goes in and the reply comes out through named pipes that Aegis holds open, and the stream is parsed in memory with fixed size limits and only codes and counts are logged. Unlike `PlanRunner`, nothing writes stdout or stderr to a file. A synthetic canary phrase in a fixture message checks that no text reaches disk, including after a crash.
- **Warm session:** one session may stay warm while the panel is open to hide the 2–4 s start-up; it ends when the panel closes. The owner's authorisation (§6) is reset on every turn, and revoking a read category ends the warm session so nothing already read carries over.

### 5. Aegis's MCP connector
- **Served by Aegis itself** over Claude Code's control channel, as the Agent SDK serves in-process MCP servers (`--mcp-config` with a `type: sdk` server, named in the `initialize` handshake): Claude Code sends each MCP message to Aegis on the job's output pipe and Aegis answers on its input pipe. There is no connector process, socket or new XPC protocol, so there is nothing else to sign, start or reach. Only Aegis's own tools are offered and allowed (`--allowedTools`), and the turn's `init` report must show only those tools and only the `aegis` server with source `sdk`. Any other request Claude Code makes of Aegis is refused.
- **Route:** the app answers each tool from AegisCore's existing read-only requests through its existing connection, with a fixed list of tools. Memory deletion, rule changes and every other mutating Core request are not exposed.
- **Reads** (each category switchable by the owner, all on by default once Claude is chosen): recent messages, mail and notifications and the items other tools cite, calendar and reminders, the brief, people waiting, promises, done today, memory notes and source health. Message search and system readings need new AegisCore requests and come later.
- **Categories:** messages, mail, notifications, calendar, memory and source health. A derived item (brief, waiting, promise, done) goes only when AegisCore confirms the source of every item it cites and each is on. Results carry the least that answers: names, times and text, never handles, recipients or attendees. Category switches are enforced at **one outbound boundary** that also covers the prompts Aegis builds itself (prep, drafts, history and memory), using each item's source, so a disabled category cannot leak through a brief or any other derived text.
- **Action tools** (stage 3): open an app, website or file by name, run a shortcut by its exact name, quit an app, control music, Notes, Maps, a Settings page, the volume or dark mode, add a reminder or event, send a message, and propose a plan. Each becomes the same typed `ActionCommand` the owner's words make, with a new `claude` origin in the action log; Claude gets no catalogue entry that takes a path or an address, and nothing that approves a card.
- **Actions** go through the **same resolver and execution pipeline as Aegis's own commands** (ADR-0031): URL and scheme checks, exact shortcut lookup, file resolution inside the home folder with alias checks just before running, then `ActionPolicy`'s tier and never-list, then the action log (codes only). There is no raw-payload action tool, no arbitrary URL scheme, no model-supplied file path. ADR-0031's limitation still holds: a shortcut's name cannot prove what the shortcut does.
- **Plans:** one action per request, at its tier; more than one must come as one plan card (ADR-0031): two to six steps, approved once, unchangeable once approved, no messages in it (each message asks on its own card, twice). Any action call after the first is refused, so nothing unplanned runs. A run's action count is kept so a run that acted is never replayed (§2).
- **Limits per request:** tool calls, actions, bytes read and bytes returned are capped, with a deadline; results carry collected text marked as data, never as instructions.
- **Accounting:** each answer in CHAT lists the messages, emails and notifications Claude read in full (“read 3 messages”, with the sources), and a read log keeps counts for every category, including summaries such as the brief. The prompt Aegis builds carries only the owner's words and Claude's own earlier replies. The action log and the read log keep codes and counts only.

### 6. Who an action is for: pure C (owner's decision)
The owner chose **pure C: Claude's actions use Aegis's normal tiers**, so automatic-tier actions run at once and the rest show confirmation cards.

- **Waiver recorded.** Claude also reads collected content, so a crafted email or message could steer it into an automatic-tier action the owner didn't ask for (for example opening a website with details in the link). AGENTS.md principle 4 is waived for this, with the owner's informed choice on 2026-11-11, and only with the Claude brain chosen. ADR-0031's rule that model-picked actions need confirmation does not apply to Claude's single actions.
- **What still holds:** the never-list cannot be unlocked; actions go only through the resolver and execution pipeline (§5), so no raw links, schemes or file paths; more than one action is still a plan card; messages are still confirmed; the per-request caps apply; Claude cannot approve its own cards; every step is in the action log.
- **Rejected: the owner-request guard** (actions the owner's own words didn't authorise become cards). It stays the design to add if the owner later wants it: Aegis would parse the owner's words into a bounded authorisation before Claude reads collected content.

### 7. Privacy
- What Claude reads goes to Anthropic under the owner's Claude account and its data settings, including other people's words in the owner's messages and email. Turning off training use (recommended in setup) does not mean Anthropic keeps nothing: its usual retention applies.
- Plan usage credits, if enabled on the account, can turn usage past the plan's limits into paid usage; setup says so.
- Nothing personal is written into the repo, prompts kept in the repo, or logs.
- The per-category read switches and the brain switch are the owner's controls; switching back to **On this Mac** ends the job and the warm session immediately.

## Consequences

- AGENTS.md principle 1 gains an allowed network use: with the Claude brain chosen and the panel open, the owner's requests and the data Aegis reads for them go to Anthropic through Claude Code under the owner's plan. Principle 4 carries the §6 waiver.
- Usage counts against the owner's plan limits. Fallback to local keeps Aegis working when limits are hit.
- Prompts, parsers and tests must work with both brains; tests use a stand-in for Claude Code and synthetic fixtures only, including adversarial messages.
- Reviews treat as blocking: a connector operation that bypasses the resolver or `ActionPolicy`, writes data, or opens the network; any raw stream written to disk; any outbound path outside the category boundary.
- Idle RAM: the job and connector run only with the panel open; the bridge adds no always-on process, so the 3 GB budget (ADR-0025) is unchanged. Measured in stage 1.

## Build stages (each its own PR, tests first)

1. Claude Code bridge: the fixed command line and environment, the handshake and configuration checks, sign-in check, in-memory streaming, model and effort picker, structured error handling. First use: ADR-0017's hand-off answers through the owner's Claude plan when no Claude key is saved (only the gated words, as for the ChatGPT plan).
2. Read tools served over the control channel, the per-category switches on every result, per-run limits and the read log (counts only). The category switches' UI comes with stage 4; the boundary for Aegis-built prompts with stage 5.
3. Action tools through the resolver, plan card and `ActionPolicy`, operation IDs, and adversarial tests (injected instructions in synthetic messages never reach the never-list, a raw link or scheme, a second unplanned action or an unconfirmed message).
4. The wizard's Brain step (after Your Mac) and the same switch in the Claude and ChatGPT window: On this Mac or Claude, the sign-in check, model and effort, plain words on what leaves the Mac, and the six read switches. Skipping the large local model download when Claude is chosen is a follow-up: it needs a small fallback model chosen and downloaded instead.
5. Switching the owner-started jobs to the chosen brain, with the fallback to the local model. With Claude chosen and the panel open: questions that aren't fixed commands (fixed phrases such as “remind me to…” stay on this Mac), with Claude's tools replacing the local command planner; meeting prep when the calendar is on; reply drafts when messages or mail are on and the person has a name (never a bare handle). Replies stream on screen and are spoken sentence by sentence; a new job, Stop or closing the panel ends the last. The prompt carries the owner's words and Claude's own earlier replies only. Each answer lists the messages, emails and notifications Claude read in full; the read log counts every category. Fallback says so once until Claude answers again; after an action, Aegis stops and says so.
