# ADR-0027: A small on-device meaning model for memory recall

- **Status:** Accepted (owner's go, 2026-10-20)
- **Issue:** #309

## Context

Memory recall (#305, #307) fuses word overlap with a meaning ranking. The Mac's built-in word embedding finds synonyms but misses brand names and whole-phrase meaning ("car" and "Mazda"). Hindsight, the owner's reference memory system, uses BAAI/bge-small-en-v1.5 for its local embeddings.

## Decision

- Use BAAI/bge-small-en-v1.5 (MIT, about 130 MB) for memory recall. `scripts/fetch-meaning-model.sh` downloads it once, at a pinned Hugging Face revision, into `~/Library/Application Support/Aegis/Models/`, and checks each file by SHA-256. `make app` runs it.
- It runs in ModelService through MLXEmbedders, part of the already pinned mlx-swift-lm (ADR-0011), so no new package is added. It loads on first use and leaves with ModelService.
- AegisCore asks for vectors over XPC (`embed`), caches them, and recalls notes and earlier conversations by cosine similarity. If the model is missing or slow (20 s), recall falls back to the word model.
- Only the owner's notes and questions are embedded, on this Mac. Nothing is sent anywhere.

## Consequences

- Recall understands meaning beyond single words, at a one-time 130 MB download and a short model load when ModelService starts.
- Hindsight's reranker (jina-reranker-v3) is not used: its licence is non-commercial.
