# ADR-0031: Read-only public-topic searches

Status: owner approved, 2026-10-23. Contract issue #37.

The owner authorizes non-personal public-topic search phrases leaving the Mac, and prohibits uploads, posts, account linking and private-context sharing. This is a narrow addition to the network exceptions in AGENTS.md, not permission to send collected information or use a cloud model. A network request necessarily reveals its search terms and connection metadata to the provider; this is not an anonymity guarantee.

Core checks only the current verbatim owner question against its contact/alias names and the existing conservative personal-information gate. It never expands remembered shortcuts or includes history, messages, contacts, files, calendar, memory, or location in the outbound query. Ambiguous follow-ups and personal questions stay local. A short-lived single-use plan binds the reply to the current question; superseded plans are rejected.

The app uses an ephemeral, cookie-free, credential-free session for one GET to Bing's public RSS search endpoint. No request body, upload, authentication, account connection, redirect or result-link traversal is allowed. This is a public endpoint rather than a guaranteed paid search API: unavailable, malformed or empty feeds produce an honest failure, not invented results. Response time and bytes and the number/size of excerpts are bounded. It does not open result websites, execute their scripts, or download files.

Public excerpts are untrusted data passed separately to the local model, without personal notes or conversation history. They never reach the action system or owner-learning/persistent-memory path. Only the checked reply is retained in the local short-lived conversation for follow-ups; that conversation is never included in a search request or public-source model job. A checked reply cites only supplied excerpt indices and shows plain source names; no clickable source links are produced. Excerpts cannot authorize another network request. Search is performed only for the current owner question, with no background polling or query logging. No third-party dependency is added.

The panel's question-answering path no longer advertises available cloud providers to Core and refuses any hand-off response instead of posting it. This disables automatic Claude/ChatGPT question hand-offs under the owner's read-only policy. Existing stored keys are not read or deleted by the public-search path.

General knowledge still works locally. Public searches cover arbitrary public topics but cannot guarantee a result or verify a full article from its search excerpt. Citation validation and source attribution are preserved; read-only does not mean the absence of outbound search terms. Synthetic fixtures test the network boundary and malicious-source handling.
