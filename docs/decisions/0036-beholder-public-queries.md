# ADR-0036: Beholder browser-assisted public queries

- **Status:** Proposed for review. The owner chose "Allow selected public lookups" for explicitly typed names, phone numbers and email addresses on 2026-11-01. Implementation is #134.
- **Builds on:** ADR-0034 (the app's own fixed public lookups) and ADR-0035 (case provenance). Neither is widened by this decision.

## Context

The research planner (#110) prepares exact quoted queries for a username, name, email, phone number or domain. Until now it could only copy them. The owner now wants to run selected public searches for an explicitly typed name, phone number or email, which AGENTS.md principle 1 did not allow before.

The narrowest way to do that keeps Aegis itself off the network. Aegis builds one fixed search address, and the owner's own browser opens it after a separate click. The owner then reads the results in the browser.

## Decision

**Destinations** are fixed. These are the only two:

| Destination | Address Aegis builds | Allowed input types |
| --- | --- | --- |
| DuckDuckGo web search | `https://duckduckgo.com/?q=<query>` | username, name, email, phone |
| GitHub user search | `https://github.com/search?type=users&q=<query>` | username, name, email |

- The scheme, host and path are constants. The query string is built with `URLComponents` query items and carries only `q` (plus GitHub's fixed `type=users`).
- No other parameters are added. In particular, DuckDuckGo settings parameters (`kp`, `kl`, `kz` and so on) are left out, so the owner's own browser settings apply.
- The full address is bounded in length, and an address that fails to build is never opened.
- DuckDuckGo documents its URL parameters for individual use (https://duckduckgo.com/duckduckgo-help-pages/settings/params). This is one owner's individual use.

**What a query can contain**
- The seed is only the raw value the owner typed into the search input or planner, after the planner's own validation (#110/#132). That is the owner's own words.
- Nothing from `BeholderModel`, a case file, findings, people, archived evidence, identifiers, Aegis memory, collected messages, mail, notifications or web content may seed, extend or rewrite a query. Collected content stays data and never becomes a query (principle 4).
- There are no automatic pivots. A result, handle or address seen in the browser never feeds the next query; the owner types every query.
- GitHub queries use only documented user-search qualifiers for the type entered:
  - usernames: `user:` / `in:login`
  - names: `fullname:` / `in:name`
  - email: `in:email`
  - (https://docs.github.com/en/search-github/searching-on-github/searching-users)
- GitHub email search matches only an address the account shows publicly, and GitHub doesn't support searching by email domain. A match isn't proof that the account holder controls the address. No match isn't proof that no account exists.
- Phone numbers have no GitHub destination; GitHub user search makes no phone claim. Domains have no destination in this decision, so they stay copy-only.
- IP addresses have no destination at all. IP context stays offline (#133): an address doesn't reveal a subscriber, an account or an email, and registry contacts are network operators.

**How the owner chooses and confirms**
- Destination selection starts empty. It resets to empty whenever the input text, input type, phone region, scope or document filter changes, so nothing carries over to a new value.
- Before any click, the planner shows:
  - the exact query text
  - the exact destination address
  - "Your browser sends this query to <host> with your IP address, browser cookies and any sign-in for that site. The site may log it."
- Each destination opens only on its own separate owner click, with no "open all".
  - Nothing opens on Return, on selection, when the panel opens, after a search, or in the background.
  - Nothing repeats, retries or schedules.
  - Opening happens only while the panel is open, so Aegis stays silent until it is opened.
- Aegis hands the address to the default browser (`NSWorkspace` / `Link`) and does nothing else.

**What Aegis must never do**
- make an HTTP request of its own for these destinations
- fetch, scrape, parse, prefetch or preview results, or import, store or log them
- send query text to a model or to telemetry
- call account-recovery or password-reset pages, or any other "does this account exist" probe

Results are leads the owner inspects in the browser, not verified account records. If the owner wants something in the case, they enter it themselves as owner-recorded evidence with a public HTTPS source (ADR-0035). It is never imported automatically.

## Consequences

- AGENTS.md principle 1 gains a narrow clause in #134: owner-clicked browser handoffs of the owner's own typed query to the two fixed search pages in ADR-0036. The code review rules treat any other destination, parameter or query source as blocking.
- The privacy guard's allow-network annotations mark only the two destination constants and the hand-off call.
- The two search sites, and anything along the browser's path, see the query, the owner's IP address, cookies and sign-in state. Aegis can't hide this and doesn't try; the preview text states it.
- Tests use invented values only. They check that:
  - each type maps to exactly the allowed destinations
  - destinations are rebuilt exactly, with the fixed host, path and parameters only
  - selection resets on every input change
  - no model, case or memory value can reach a query
  - nothing opens without the click
  - no `URLSession` or other request path exists
- Considered and rejected:
  - fetching results inside Aegis (scraping, data import, provider terms)
  - an "open all" action (one click sending one personal value to several sites)
  - seeding queries from case data (pivots on collected or derived data)
  - adding more destinations (each needs its own owner approval and ADR update)
