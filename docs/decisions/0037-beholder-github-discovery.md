# ADR-0037: Beholder GitHub user discovery by typed name or email

- **Status:** Accepted. The owner answered "Approve in-app GitHub discovery" on 2026-11-02, and the approval is recorded on #143. Implementation is #144.
- **Builds on:** ADR-0034 (app-side username lookups), ADR-0035 (case provenance) and ADR-0036 (browser-only name/email/phone searches).
- **Narrowly amends:** ADR-0034's fixed endpoint list and its ban on discovered-identifier expansion, and ADR-0036's rule that Aegis makes no HTTP request of its own for names or emails. Both change for the two GitHub requests below only. Every other part of both decisions stands.

## Context

Before this decision, AGENTS.md principle 1 allowed Beholder only two network paths:
- ADR-0034 lookups of an explicitly entered username, to fixed APIs
- ADR-0036 browser searches that the owner opens with a separate click

A typed name or email could only go to a site through the owner's browser. The owner wants Beholder to find public accounts for journalistic research and asked for one in-app path: GitHub user search for a typed name or email, then inspection of one chosen result.

## Decision

**1. Search request.**
- **Where it starts:** a dedicated Discover tab with its own field. The owner types a name or email there. The source choice starts empty; the owner chooses GitHub and sees the exact request before pressing Search.
- **What it sends:** one credential-free GET:
  `https://api.github.com/search/users?q=<"seed"> in:name|in:email type:user&per_page=20&page=1`
- **The seed:** the typed value, re-validated by the existing name and email helpers. It is quoted, and a literal `+` is encoded as `%2B`. Nothing else goes into `q`.
- **No other parameters:** no `sort` and no text-match media type.
- **Not included:** phone, IP and username modes keep their current behaviour, and nothing claims GitHub can search phone numbers or IP addresses.

**2. Search hits.**
- **Display:** up to 20 hits in GitHub's order, with no score or ranking shown. Each shows only its `login` and `type`, and the profile address is rebuilt locally from the login.
- **Context shown with them:** the exact query, the time, `total_count`, and a note when `incomplete_results` is set.
- **Kept only on screen:** the search input and hit metadata (each hit's login and type, `total_count`, `incomplete_results` and the query) are never added to the case, its archive or an export. A separately inspected public profile (step 3) is saved as a normal ADR-0034 observation with its own source and check time. Its fields may independently contain the same name or email the owner typed; that is the profile's own published data, not the query saved as metadata.
- **Not proof:** GitHub matches `in:email` and `in:name` by *containment* within public fields. A hit is neither an exact email or name match nor identity evidence.

**3. Inspect.**
- **Trigger:** a separate **Inspect GitHub profile** click on one hit makes one GET to `https://api.github.com/users/<login>`.
- **The address:** it is rebuilt from the `login` of the current, live search hit the owner clicked, after that login passes GitHub's handle rules. This is the only returned value allowed to seed a request (see "Never" below). It is never taken from a returned URL.
- **The result:** it goes through the existing ADR-0034 GitHub adapter, with the exact-login check, the archive and an optional Save as possible. It is labelled "found via GitHub user search" plus the time, without storing the query.
- **Email matches:** a typed email counts as an exact match only when the profile `email` canonically equals it. GitHub documents that unauthenticated responses may return `email: null`, so a missing email proves nothing.
- **No fan-out:** nothing goes to any other source, and nothing is inspected automatically.

**4. Transport.** Both requests use the existing ADR-0034 transport:
- a fresh ephemeral session with no cookies, credentials or cache
- no redirects, a 256 KiB response bound and finite timeouts
- only the `Accept` and `User-Agent` headers, and no retries or background work

The allow-list gains exactly these two request shapes, rebuilt and compared by exact URL equality. GitHub allows 10 unauthenticated search requests a minute, so a 403 or 429 shows as Rate limited.

**5. Never:**
- GitHub keys, tokens or sign-in
- avatars, returned URLs used as destinations, link following or pagination
- `sort` or text-match parameters, or scoring
- model calls, account-recovery or breach probes, or private APIs
- requests built from case references, people, Contacts, messages, mail, files, memory, or imported or restored data
- requests built from returned text, with one exception: the validated `login` of the current search hit the owner clicks Inspect on (step 3). Response prose and every other returned field (names, bios, emails, URLs, `text_matches` and so on) never seed a request. Nothing from an inspected profile seeds a further request.

The code that builds these requests has no access to the case. Nothing from a response is executed or treated as an instruction (principle 4).

## Owner approval

The owner approved this statement on 2026-11-02:

> Beholder may send a name or email that the owner types, only after the owner chooses GitHub and presses Search, to `api.github.com/search/users` (one page of 20 public users), and fetch one public GitHub profile only when the owner clicks Inspect on a result. Nothing else is sent, nothing is fetched automatically, and no case or personal data is used to build these requests.

The approval does not add phone or IP discovery, authentication, automatic fan-out or any other provider. Each of those needs its own owner approval and ADR.

## Consequences

- AGENTS.md principle 1 gains one clause citing this ADR. The code review rules treat any other destination, parameter, identifier class or query source as blocking.
- #144 adds privacy-guard allow-network annotations on the two URL builders only.
- The tests use stubbed transports only. They cover:
  - exact URL rebuilding and the `+`/quote encoding
  - no fan-out and no seeding from case data
  - the difference between a containment hit and an exact email match, and `email: null`
  - the rate-limit and `incomplete_results` display
  - that hits and queries are never kept
- No live-person searches are run during development.

Primary sources (checked 2026-11-02):
- https://docs.github.com/en/rest/search/search#search-users
- https://docs.github.com/en/rest/users/users#get-a-user
- https://docs.github.com/en/search-github/searching-on-github/searching-users
