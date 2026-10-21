# ADR-0016: One owner-command action safety pipeline

- **Status:** Proposed
- **Date:** 2026-10-12
- **Proposed by:** Codex · **Issue:** #189 · **Approved by:** pending

## Context

Stage 5 will send messages, control accessories and operate apps. A model can propose work, but cannot
authorize it. Collected email, messages, notifications, web pages and screen text are untrusted data:
prompt injection can impersonate the owner or tell an assistant to bypass its rules. None of these
sources may originate an action, even when their text claims to be an owner command.

## Options considered

1. Each domain applies its own safety rules and audit format.
2. One shared typed contract and pure policy gate, followed by domain-specific executors.

## Decision

Choose one pipeline: direct owner command typed or spoken in the open panel → proposed `ActionRequest`
→ policy check → confirmation tier → required confirmation in the panel → per-domain execution
→ codes-only action log → undo where the domain supports it. Plans are previewed before any step runs;
each step must pass the same gate. Recheck panel state and policy immediately before future execution.

Only `ownerTyped` and `ownerSpoken` origins exist. These labels do not authenticate a model's claim:
future panel adapters own request construction and retain trusted provenance. Collectors and model
output have no dispatch route; never deserialize collected text as an action. Future executors must
honor the typed operation and must never interpret payload text, URLs or screen content as commands.

The fixed never-list cannot be overridden by settings or confirmation: payments, purchases, money
transfers, deletion of any data (including messages, email, files, events and reminders), passwords
and credentials, and security or privacy system settings. Unknown operations fail closed.

Read-only and opening operations are `auto`; lights/scenes and creation of reminders/events are
`confirm`; sending messages/email and operating locks/garage doors are `confirmTwice`; forbidden work
is `never`. Secure accessory changes conservatively require two approvals in either direction.
These proposed tiers refine the earlier design tables for this groundwork. Instruction-like payload
text reuses the brief's injection detectors; URLs are also detected locally. Either hazard raises the
tier one step (both together still raise once), retaining reason codes. Raising `confirmTwice` reaches
`never`. Owner settings can only raise requirements. `allowed` means policy eligibility, never completed
confirmation or authority to execute.

Aegis is silent while the panel is closed: no actions, prompts, notifications or sounds. Closed-panel
requests fail policy. This layer does not create UI, sound or background work.

The append-only local log stores time, opaque UUID, domain, decision codes and outcome code; no payload,
handles, paths, titles, message text or free-form errors. JSON-lines appends replace the active file
atomically. At N entries the completed generation rotates into one bounded archive; at most 2N records
remain on disk and reads return the newest N. A single locked file instance owns writes; multiple
processes/instances writing the same path are unsupported. Rotation uses two atomic writes; if interrupted
between them, identical generations are deduplicated on read and retried on the next append.

## Consequences

Policy and storage remain Foundation-only, local and Linux-testable. Typed domain payloads and verbs
prevent mismatched domains and arbitrary executable instructions. Provenance enforcement, confirmation
state, per-domain semantic resolution, permissions, execution-time checks and undo require later work.
This issue adds contracts, policy and log storage only: no CoreRequest/CoreResponse cases, executors,
registry, panel wiring or enabled action. Audit retention is finite and intentionally expires old entries.
