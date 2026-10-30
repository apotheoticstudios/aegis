# ADR-0034: Beholder, owner-started public username research

- Status: implementation proposed for review, issue #98; owner requested development and the Beholder name on 2026-10-30.

## Decision

Beholder is an optional app-only research dashboard. Its first slice searches one explicitly entered username
against selected GitHub, GitLab, Hacker News and DEV public profile APIs. The screen previews the normalised
username and destination hosts; pressing Search or Return authorises that bounded search. Editing a field or
opening the dashboard sends nothing. This is a narrow new network exception for research, separate from private
record retrieval and cloud hand-off. It must not silently extend either permission.

Only unauthenticated HTTPS GETs to those four fixed API endpoints are allowed. Fresh ephemeral sessions have no
cookies, credentials or cache; redirects are rejected. Requests have 12-second inactivity and 20-second resource
timeouts; responses are bounded to 256 KiB while streaming. At most four requests run, once each, with no retries,
pagination, discovered-identifier expansion, remote images, scripts or linked-page fetching. Providers see the
username, ordinary request metadata and the connection's IP address. They may log it; local inference does not
make an online lookup anonymous.

Results are source observations, never identity assertions. Each keeps the exact queried source URL, retrieval
time, fixed status and a bounded allow-list of public profile text. A returned handle must match the query;
Hacker News matching is case-sensitive. HTTP errors, malformed responses and mismatched identities are not
absence evidence. A missing public result does not prove an account does not exist (HN exposes only public
activity). Accounts on different services are never merged automatically. Text is displayed literally, not
executed, opened as a URL or fed into an action/model prompt.

Cases live in memory until cleared or the app exits. Cancellation, navigation away and closing/hiding the host
stop outstanding work; generations prevent obsolete results from entering another search. Export is a deliberate
JSON file save with source URLs, observation times and the identity warning. No automatic persistence, uploads,
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
