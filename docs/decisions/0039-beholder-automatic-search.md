# ADR-0039: Beholder searches automatically after one Search

- **Status:** Accepted. The owner asked for it on 2026-11-08 and said "Keep developing that" on 2026-11-12. The authorisation is recorded on #158. Implementation is #160.
- **Builds on:** ADR-0034 (fixed public username APIs), ADR-0035 (case provenance) and ADR-0037 (GitHub user discovery).
- **Narrowly amends:** ADR-0037's separate source choice and separate Inspect click, its ban on automatic fan-out, and its rule that hits keep GitHub's original display order. ADR-0034's per-source selection becomes "all sources" for one Search. Every other part of those decisions stands, including their transport, allow-lists and "Never" lists.
- **Retires from the interface:** ADR-0036's browser hand-offs and the research planner (#110). Beholder no longer offers manual web searches.

## Context

The owner said on 2026-11-08:

> I don't want Beholder to give an option to search the web manually, its whole job is to search automatically and present information

Until now Beholder made the owner pick sources, click Inspect on each GitHub hit, or open browser searches by hand. This decision makes one deliberate Search do the bounded lookups Aegis is already allowed to make, and present the results. It adds no destination.

## Decision

**1. What starts a search.** Only one deliberate Search click or Return, on input the owner has typed and that is current and valid. The existing username, name and email validators decide the mode. Opening Beholder, typing, pasting, importing, restoring a case or reading case data sends nothing.

**2. Before Search.** The screen shows a summary of what Search will do (mode, number of destinations, that providers see the query and ordinary request metadata). An optional disclosure lists every exact destination. Both appear before the click, not after.

**3. Username mode.** One Search runs all 22 existing fixed ADR-0034 username APIs for the typed username, at most four at a time.

**4. Name or email mode.**
- One credential-free GitHub user search, exactly ADR-0037's request: one page, at most 20 results.
- Each hit is validated as a `User` with a login that passes GitHub's handle rules. For those live validated logins only, Aegis then fetches each exact `https://api.github.com/users/<login>` profile automatically, at most four at a time, through the existing ADR-0034 GitHub adapter and its exact-login check.
- A typed name or email never goes to the username APIs.

**5. Phone and IP.** They stay local, using the existing case and IP-context features. Nothing is sent.

**6. Never.**
- New destinations, or any returned URL used as a destination
- Keys, tokens or sign-in
- Recursion (nothing from a fetched profile seeds another request), pagination, retries, background or unattended work
- Automatic identity merging or identity scoring
- Requests built from case data, memory, collected content, imports or restores

**7. Cancelling.** Editing the input, Stop, closing or hiding the host, Clear, Import and a new Search all cancel outstanding work. A generation check drops any reply that arrives for a stale search, so it never reaches the screen or the case.

**8. What is kept.**
- The query and the hit list stay on screen only, as in ADR-0037. They are never added to the case, its archive or an export.
- A validated profile may be kept as local case evidence with its source and check time, as an ordinary ADR-0034 observation.

**9. How results are shown.**
- Successful profiles may be grouped first. Within each status group, GitHub's hit order is kept. This is display grouping only, never identity scoring or ranking.
- Pending, failed, rate-limited and incomplete coverage is shown truthfully, including GitHub's `incomplete_results`. A failure or missing result is not evidence of absence.
- A GitHub hit means the typed text is *contained* in a public field. Only a profile `email` that canonically equals the typed email counts as an exact public-email match, and the screen keeps the two apart. `email: null` proves nothing.
- Links to the actual evidence (a fetched profile's own page) remain optional inspection the owner opens.

**10. Removed.** The browser hand-off buttons (ADR-0036) and the research planner leave the active Beholder interface. No manual web search remains.

## Consequences

- AGENTS.md principle 1 cites this ADR in its Beholder clauses. Code review treats any other destination, parameter, query source or automatic step as blocking.
- #160's tests use stubbed transports only. They cover: Search as the only trigger, the four-at-a-time limit, names/emails never reaching username APIs, profile fetches only for live validated logins, no recursion or pagination, cancellation and stale-reply exclusion, the transient query and hits, and the containment versus exact-email display.
- No live-person searches are run during development.
