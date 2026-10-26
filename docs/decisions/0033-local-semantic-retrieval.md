# ADR-0033: Bounded on-device meaning search for personal records

- Status: Implemented for review
- Issue: #64; owner requested the shared intelligence improvements on 2026-10-26

## Decision

Reuse bge-small-en-v1.5 and the existing local `ModelClient.embed` IPC operation for explicit personal-record searches. Unlike memory-only recall in ADR-0027, the operation may now receive bounded excerpts of locally collected records. No data leaves the Mac, no package or download is added, and vectors are used only for ranking records, never for instructions, actions, identities or event relationships.

Source, sender/contact, direction and civil-date constraints apply first. An on-demand request embeds at most 128 eligible recent records, with at most two 768-scalar body passages and a short title per record. Numeric constraints stay exact. At most three close semantic matches complement existing keyword search through rank fusion. Weak or ambiguous similarities go through one local relevance-selection job (64 output tokens, 20-second deadline); only validated record indices are accepted, and invalid/failed selection adds no semantic candidates. It uses the selected chat model through the existing cancellable job path. Missing or malformed embeddings preserve keyword retrieval. Existing citation and injection checks remain blocking.

No event vectors are persisted or cached across requests; no background indexing, new process or idle work is introduced. The existing ModelService lifetime and memory budget still apply. This first pass covers a bounded recent candidate pool, not every historical event. A persistent event index, multilingual embedding model or new model profile needs a separate scoped decision and measurements.

Development and benchmarks use invented records and in-memory stores only. Reports contain counts, timings and fixed codes, never collected text. The model, the developer and a public lookup cannot turn source text into commands.
