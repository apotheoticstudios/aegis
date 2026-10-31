# ADR-0034: Beholder, owner-started public username research

- Status: implementation proposed for review, issue #98; owner requested development and the Beholder name on 2026-10-30.

## Decision

Beholder is an optional app-only research dashboard. Its first slice searches one explicitly entered username
against selected GitHub, GitLab, Hacker News and DEV public profile APIs. The screen previews the normalised
username and destination hosts; pressing Search or Return authorises that bounded search. Editing a field or
opening the dashboard sends nothing. This is a narrow new network exception for research, separate from private
record retrieval and cloud hand-off. It must not silently extend either permission.

Only unauthenticated HTTPS GETs to the twenty-two fixed API endpoints below are allowed. Fresh ephemeral sessions have no
cookies, credentials or cache; redirects are rejected. Requests have 12-second inactivity and 20-second resource
timeouts; responses are bounded to 256 KiB while streaming. At most four requests run concurrently, once per selected source, with no retries,
pagination, discovered-identifier expansion, remote images, scripts or linked-page fetching. Providers see the
username, the common `Aegis-Beholder/1.0` User-Agent (not a per-owner ID), ordinary request metadata and the
connection's IP address. The preview discloses this. They may log it; local inference does not
make an online lookup anonymous.

Results are source observations, never identity assertions. Each keeps the exact queried source URL, retrieval
time, fixed status and a bounded allow-list of public profile text. A returned handle must match the query;
Hacker News matching is case-sensitive. HTTP errors, malformed responses and mismatched identities are not
absence evidence. A missing public result does not prove an account does not exist (HN exposes only public
activity). Accounts on different services are never merged automatically. Text is displayed literally, not
executed, opened as a URL or fed into an action/model prompt.

The HUD retains its own case across tab changes; the menu-bar window has a separate case. Cases live in memory
until cleared or the app exits. Cancellation, navigation away and closing/hiding the host
stop outstanding work; generations prevent obsolete results from entering another search. Export is a deliberate
JSON file save with stable status codes, source URLs, observation times and the identity warning. No automatic persistence, uploads,
telemetry, query/content logging, Contacts access or memory writes exist. Opening a canonical profile is a
separate explicit browser-link action and uses the browser's own privacy settings.

App-private Foundation models and SwiftUI presentation require no AegisKit/IPC changes or new runtime dependency.
There is no idle worker, timer or model. All tests use invented Example handles and mocked responses without
external lookups. Future provider additions, shared contracts, persistence, capture, semantic analysis and World
integration need scoped issues; leaked credentials, account-recovery probing and private-person live tracking
are outside this slice. The current app is not replaced by this development change.

## Reuse and sources

Sherlock's cross-site discovery and Hunchly's source/time provenance informed the design. No upstream code,
site dataset or artwork is copied or bundled; the multi-eyed emblem is original SwiftUI vector drawing. Each
additional code integration must review its actual licence and outbound behavior first.

- https://github.com/sherlock-project/sherlock (MIT)
- https://hunch.ly/ (capture and provenance inspiration, not a bundled dependency)
- https://docs.github.com/en/rest/users/users#get-a-user
- https://docs.gitlab.com/api/users/#list-users
- https://github.com/HackerNews/API#users
- https://developers.forem.com/api/v1#tag/users

This is a first working dashboard, not exhaustive coverage or guaranteed identification. Broader public-web,
registry and geographic research can build on the same evidence and permission boundaries.


## Broader coverage (#100, owner requested 2026-10-30)

The initial four remain the default selection. Eight additional sources are opt-in. The closed catalogue is
compiled into the app; no remote configuration, Python tool or site-rule download is executed. A fixed four-slot
queue replaces unbounded fan-out, with explicit Queued/Checking states. Stop cancels active and queued work;
completion order never changes the catalogue order displayed/exported. Each request retains the original
transport restrictions, bounded text and exact returned-handle checks.

| Added source | Fixed API host and path | Positive account identity |
| --- | --- | --- |
| Codeberg | codeberg.org/api/v1/users/{handle} | login |
| Docker Hub | hub.docker.com/v2/users/{handle}/ | username |
| Keybase | keybase.io/_/api/1.0/user/lookup.json | OK status, one result, basics.username |
| Lichess | lichess.org/api/user/{handle} | username |
| Chess.com | api.chess.com/pub/player/{handle} | username |
| Scratch | api.scratch.mit.edu/users/{handle} | username |
| Bluesky (.bsky.social) | public.api.bsky.app/xrpc/app.bsky.actor.getProfile | handle including .bsky.social |
| Mastodon.social | mastodon.social/api/v1/accounts/lookup | matching local username AND local acct |

Keybase receives `usernames` and fixed `fields=basics,profile`, never a cross-service identifier query. Bluesky
receives only the explicitly named .bsky.social namespace (a bare handle is qualified with that label); custom
handle domains and DIDs are outside this slice. Mastodon queries only the named server's local accounts, not
arbitrary federated hosts. No posts, followers, contact networks, linked proofs or extra identities are fetched.
A provider requiring sign-in or returning an unrecognised/mismatched response is Unavailable, never a positive
match. Only explicit HTTP 404 or documented empty Keybase results become No public result. No public result
still does not prove absence. All new adapters are tested with invented responses, not live private-person scans.

Discovery inspiration: selected entries of Sherlock's MIT catalogue at
https://github.com/sherlock-project/sherlock/blob/e40a45ec2a074b90703b3b4b842c8a3adbd6ada3/sherlock_project/resources/data.json.
No upstream code, full dataset, headers or example usernames are copied/bundled. Native positive JSON identity
checks replace status-only profile probes. References used to verify the selected endpoint shapes:

- https://raw.githubusercontent.com/go-gitea/gitea/main/routers/api/v1/user/user.go
- Docker Hub's public profile route is also recorded in the pinned Sherlock Docker Hub entry above.
- https://keybase.io/docs/api/1.0/call/user/lookup
- https://github.com/lichess-org/api/blob/master/doc/specs/tags/users/api-user-username.yaml
- https://www.chess.com/news/view/published-data-api
- https://github.com/scratchfoundation/scratch-rest-api/wiki/Users
- https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/actor/getProfile.json
- https://github.com/mastodon/mastodon/blob/main/app/controllers/api/v1/accounts/lookup_controller.rb

Vendor API availability and access policies may change. Failures remain visible; the app never attempts an
alternate private endpoint, authentication, scraping workaround or a different search provider automatically.

Review refinements (#100): a qualified .bsky.social input is eligible only for Bluesky; it is never sent to another source. The preview lists the qualified Bluesky payload separately. Scratch profile.status is labelled Working on, never Account state. The reserved Codeberg search route is ineligible. Bluesky HTTP 400 missing-profile replies remain Unavailable rather than being guessed absent; moderation/closure flags on other services are not interpreted as identity findings. The original-source selection shares one provider definition after the #101 integration.

## Social coverage (#104 / #105, owner requested 2026-10-31)

Ten further API sources are individually opt-in. The original four remain the defaults. Seven are named
Mastodon servers: mastodon.online, mstdn.social, fosstodon.org, hachyderm.io, infosec.exchange, mas.to and
social.vivaldi.net. Each uses only `/api/v1/accounts/lookup?acct={handle}` and requires both the returned username
and local acct to match. No arbitrary server, remote account address or WebFinger resolution is accepted.
Server access policies can require authentication or block requests; those responses stay Unavailable.

Write.as uses only `write.as/api/collections/{alias}`. Its successful API envelope and exact alias are required;
only title and description are retained. A collection is labelled Blog, not asserted to be a person's account.
PeerTube uses only `framatube.org/api/v1/accounts/{name}`. Returned name, local host and canonical actor URL
must all match; only display name and description are retained. No posts, videos, followers or CSS are fetched.
Mixcloud uses only `api.mixcloud.com/{handle}/`, whose exact root user key and returned username must both match. Reserved API routes
(me, search, genres, upload, OAuth and other non-user roots) are ineligible. Returned shows, pictures and links
are never followed. These adapters use locally constructed canonical profile links; all existing transport bounds apply.

Primary API references (no upstream executable code copied):

- https://docs.joinmastodon.org/methods/accounts/#lookup
- https://github.com/mastodon/mastodon/blob/main/app/controllers/api/v1/accounts/lookup_controller.rb
- https://developers.write.as/docs/api/#retrieve-a-collection
- https://www.mixcloud.com/developers/
- https://docs.joinpeertube.org/api-rest-reference.html#operation/getAccount
- https://github.com/Chocobozzz/PeerTube/blob/develop/support/doc/api/openapi.yaml

The broader Sherlock-style directory is deliberately separate from positive API evidence. Public profile URL
patterns can be useful even when a platform needs sign-in, API registration or browser rendering. Such sources
must be marked Open manually, never Candidate account or No public result merely because a URL was generated.
Their links are opened only by a separate owner click in the browser. Search itself must not request them,
claim they were checked, use browser cookies, or bypass the platform's access controls. Source coverage and
automatically checked accounts are different counts. The pinned Sherlock patterns inspire native fixed rules;
Hunchly's provenance principle informs source and observation times, without bundling either tool.

Integration uses the original four sources by default. Automatic source IDs retain their existing encoding;
manual directory IDs are additive and are excluded from the transport allow-list. Preparing a manual finding
does not create a task, request, check timestamp, request source URL or existence claim. Mixed searches schedule
only automatic sources in the four-slot queue; Stop leaves unchecked links unchanged. Directory input rules
still apply to manual links, and a known automatic adapter takes precedence over a directory template.

Explicit JSON export is schema 2: it adds the `manual` status and optional `preparedProfileURL` for an unchecked
directory target. Such a URL is not request provenance: `sourceURL` and `checkedAt` remain absent for manual
findings. Automatic findings retain actual request provenance and time. New findings also encode a fixed `access` mode
(`automatic` or `manual`), including Unsupported results. Legacy JSON can omit it. Provider-reported Mastodon
suspension, limitation and moved-profile flags are displayed without following their destination URLs. Old finding JSON with the optional
field absent still decodes. There is no change to AegisKit or IPC contracts, no import path or persistent case store.
