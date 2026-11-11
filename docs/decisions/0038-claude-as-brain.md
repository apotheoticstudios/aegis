# ADR-0038: Claude as Aegis's brain, through the owner's Claude plan

- **Status:** Proposed (owner's design choices, 2026-11-11; cross-vendor safety review folded in the same day). One open decision (§6). Accepted when the owner settles it; build stage 1 then starts.
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
- Any model the owner's plan offers through Claude Code (for example Opus 5.5, Sonnet 5.5, Haiku 5.5, or Fable 5.2 where the plan includes it), read from Claude Code through a supported interface, not hard-coded; if discovery fails, the last good list is kept.
- Changeable from Settings, from a model chip in CHAT, and by voice ("use Sonnet"); plus an effort setting (quick / balanced / thorough → `low` / `medium` / `high`). Stored in Aegis's settings on the Mac.

### 4. How Aegis runs Claude
- **Command line, fixed and tested per supported Claude Code version:** `claude -p --output-format stream-json --verbose --include-partial-messages`, `--model` and effort from the picker, Aegis's own `--system-prompt`, `--no-session-persistence`, `--tools ""` (no shell, file, web or other built-in tools), `--strict-mcp-config --mcp-config <Aegis's connector only>`, and an empty `--setting-sources` so no user, project or local settings, hooks, plugins, instruction files or memory load. A start-up check reads the effective configuration and refuses to run if any hook, plugin, extra MCP server or tool is active, or if a managed policy forces one. Not `--bare`: it skips subscription sign-in.
- **Environment:** a minimal, rebuilt environment. Credential, provider and endpoint overrides (such as `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, cloud-provider switches) are removed, so the job uses the owner's subscription sign-in and nothing else; the sign-in itself is reached where Claude Code keeps it, never copied. Nonessential traffic is switched off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, plus disabling error reporting and feedback), and a synthetic-data session verifies that only Anthropic's inference endpoints are contacted.
- **Containment:** its own launchd job (as Codex in ADR-0017), with an empty working folder and its own temporary folder, so it is not a child of Aegis and does not run as Aegis's code identity. This is separation, not a sandbox: anything Claude Code itself has been granted, and files any process of the owner's account can read, remain reachable in principle; with no built-in tools and no customisations loaded, Claude has no way to use them. The owner validates permissions on a clean profile and one with earlier grants before stage 1 ships.
- **No transcript on disk:** the stream is parsed in memory with fixed size limits and only codes and counts are logged. Unlike `PlanRunner`, nothing writes stdout or stderr to a file. A synthetic canary phrase in a fixture message checks that no text reaches disk, including after a crash.
- **Warm session:** one session may stay warm while the panel is open to hide the 2–4 s start-up; it ends when the panel closes. The owner's authorisation (§6) is reset on every turn, and revoking a read category ends the warm session so nothing already read carries over.

### 5. Aegis's MCP connector
- A small local MCP server started by the job over stdio. It never opens the network.
- **Route:** it talks to an **app-side broker**, not to a generic forwarder of AegisCore's requests: the broker accepts only a fixed list of read and action operations, checks the connector's code signature, and carries per-turn capabilities. Memory deletion, rule changes and every other mutating Core request are not exposed. This is a contract change (new XPC protocol in AegisKit), designed before stage 2.
- **Reads** (each category switchable by the owner, all on by default once Claude is chosen): messages and email search and threads, calendar and reminders, the brief, people waiting, promises, done today, memory notes, source health and system readings. Category switches are enforced at **one outbound boundary** that also covers the prompts Aegis builds itself (prep, drafts, history and memory), using each item's source, so a disabled category cannot leak through a brief or any other derived text.
- **Actions** go through the **same resolver and execution pipeline as Aegis's own commands** (ADR-0031): URL and scheme checks, exact shortcut lookup, file resolution inside the home folder with alias checks just before running, then `ActionPolicy`'s tier and never-list, then the action log (codes only). There is no raw-payload action tool, no arbitrary URL scheme, no model-supplied file path. ADR-0031's limitation still holds: a shortcut's name cannot prove what the shortcut does.
- **Plans:** more than one action in a request still becomes ADR-0031's plan card: at most six steps, approved once, unchangeable once approved, messages still confirmed separately. A tool call that would add an action outside the approved plan is refused.
- **Limits per request:** tool calls, actions, bytes read and bytes returned are capped, with a deadline; results carry collected text marked as data, never as instructions.
- **Accounting:** each answer in CHAT shows what was sent to Claude (counts by source, covering both tool results and Aegis-built prompts, including requests that fail). The action log and a read log keep codes and counts only.

### 6. Who an action is for (the open decision)
The owner chose **option C: Claude uses Aegis's normal tiers**. Because Claude also reads collected content, a crafted email or message could try to steer it.

- **Proposed default: C with the owner-request guard.** Before Claude sees any collected content in a turn, Aegis parses the owner's own words (typed or spoken, never text Claude writes) with the existing command grammar into a bounded authorisation: the complete action, its arguments and how many times it may run. A Claude action that matches that authorisation exactly runs at its normal tier. Anything else — an action the owner didn't ask for, different arguments, a repeat, or a value taken from collected content — becomes an exact confirmation card showing everything that will happen. Claude cannot write the owner's words or approve its own card. For ordinary commands ("open Safari", "remind me at 5pm to call the office") this behaves like C.
- **Alternative: pure C.** Claude's actions always use their normal tier. Not the default, because collected content could then trigger automatic-tier actions, which principle 4 forbids. The owner may still choose it; this ADR then records that waiver.
- Either way, model-picked actions follow ADR-0031's confirmation rule where the guard doesn't authorise them, the never-list cannot be unlocked, and every step is in the action log.

### 7. Privacy
- What Claude reads goes to Anthropic under the owner's Claude account and its data settings, including other people's words in the owner's messages and email. Turning off training use (recommended in setup) does not mean Anthropic keeps nothing: its usual retention applies.
- Plan usage credits, if enabled on the account, can turn usage past the plan's limits into paid usage; setup says so.
- Nothing personal is written into the repo, prompts kept in the repo, or logs.
- The per-category read switches and the brain switch are the owner's controls; switching back to **On this Mac** ends the job and the warm session immediately.

## Consequences

- AGENTS.md principle 1 gains an allowed network use once this is accepted: with the Claude brain chosen and the panel open, the owner's requests and the data Aegis reads for them go to Anthropic through Claude Code under the owner's plan. Principle 4 is kept by §6's guard (or waived by the owner's explicit choice of pure C).
- Usage counts against the owner's plan limits. Fallback to local keeps Aegis working when limits are hit.
- Prompts, parsers and tests must work with both brains; tests use a stand-in for Claude Code and synthetic fixtures only, including adversarial messages.
- Reviews treat as blocking: a connector operation that bypasses the resolver or `ActionPolicy`, writes data, or opens the network; any raw stream written to disk; any outbound path outside the category boundary.
- Idle RAM: the job and connector run only with the panel open; the bridge adds no always-on process, so the 3 GB budget (ADR-0025) is unchanged. Measured in stage 1.

## Build stages (each its own PR, tests first)

1. Claude Code bridge: the fixed command line and environment, configuration check, sign-in check, in-memory streaming, model and effort picker, structured error handling, fallback without actions.
2. Contract change, then the broker and connector with read tools, the outbound category boundary and the read log.
3. Action tools through the resolver, plan card and `ActionPolicy`, operation IDs, §6's decision, and adversarial tests (injected instructions in synthetic messages never cause an action without a card under the guard).
4. The wizard's Brain step and Settings switch.
5. Switching the owner-started jobs (chat, asks, planning, prep, drafts) to the chosen brain.
