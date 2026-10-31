# ADR-0035: Beholder case files and evidence provenance

- **Status:** Proposed for review (#125). Owner asked for Beholder development using the twelve audited upstream projects on 2026-10-31.
- **Builds on:** ADR-0034, which owns the network allowance, providers and export schemas 1–3.

## Context

A Beholder case now holds several kinds of record:

- public lookup findings
- unchecked manual links
- owner-made person groups and assessments
- a cross-search account archive (#124)
- phone and email identifiers the owner enters

These records only stay trustworthy if every one says where it came from and when, and keeps observations separate from the owner's judgements. Export already exists (schema 4). Import does not exist yet, but a case file is the obvious way in. A file arriving from outside must not become a way to add data or trigger actions.

## Decision

**Provenance rules (all case records):**
- An automatic finding counts as an observation only when it has a check time and a definite answer: Candidate or No public result. A request address alone is never one.
  - Rate limited, Unavailable, Queued, Checking and Cancelled are unknown, not absent.
  - These unknown results must not replace or revoke an earlier completed observation.
- A manual source is always unchecked, whatever its stored fields say. It has no check time and no request address. Its prepared link only shows where the owner could look.
- The owner's assessments, notes, identifiers and evidence links keep their own timestamps. They are stored apart from the source snapshot they refer to, and never overwrite it.
- Profile addresses are compared only in the canonical form from `BeholderProfileLinks`:
  - Only the scheme and host are lowercased; the default `:443` and the fragment are dropped.
  - Path case, `www`, trailing slashes and queries are kept.
  - Credentials, other ports, IP addresses and private hosts are rejected.
  - Equal addresses, equal handles or equal identifiers are a lead for the owner to review. They are never proof that two accounts are one person.

**Case files:**
- Export happens only when the owner chooses it. It writes one local JSON file and nothing else: no upload and no copy into Aegis memory. Each schema version adds fields to the previous one.
- A schema 4 file can hold phone and email values the owner entered, so the export warning must say so.
- Phone and email values never leave the case any other way. They are not sent to a provider, a model or the network.

**Import (when built):**
- An imported case file is untrusted data, never instructions. Every value is re-validated through the same constructors used for live input, including handles, `BeholderIdentifier`, `BeholderProfileLinks.canonical`, the evidence URL rules and text bounds. Anything invalid is rejected, not repaired.
- An import:
  - refuses a schema newer than the app understands
  - applies the same caps as a live case
  - shows the owner what it will add before it replaces the open case
- An import never starts a lookup, opens or fetches a URL, re-checks an account or merges people. Every imported record keeps its original check and assessment times and is marked as imported.

## Consequences

Codex's #124 archive and later import work have one rule set to check against. The cost is that a refresh that gives no answer must keep the previous observation visible rather than overwriting it. No new network destinations, dependencies, storage or AegisKit contracts are added.
