# ADR-0030: Setup downloads the models, and the tune-up picks the size

- **Status:** Accepted (owner's go for stage 4 of the setup wizard, 2026-10-23)
- **Issue:** #30

## Context

ModelService never downloads anything: until now the chat model reached a Mac through a developer's Hugging Face cache, and the meaning model through `make app` (ADR-0027). A fresh Mac had no chat model, so Aegis couldn't install itself. DESIGN.md has the models download in the background during setup, and a tune-up that checks the model on the owner's Mac.

## Decision

- **The app downloads, during setup.** When the wizard opens, Aegis.app fetches this Mac's chat model (Qwen3.5 4B or 9B, by memory, ADR-0009) and the meaning model (bge-small, ADR-0027) into `~/Library/Application Support/Aegis/Models/`. It sends only HTTPS GETs to huggingface.co for files at pinned revisions; nothing about the owner goes out. Each file arrives as a `.part` file, is checked by SHA-256 against the list in AegisKit (`ModelFiles`), and only then takes its real name, so a finished name always means a checked file. Models already in place (in Aegis's folder or the pinned Hugging Face snapshot) are skipped. A download needs the remaining size plus 1 GB free.
- **The tune-up measures, then may step down.** It sends one synthetic job (no owner data) through AegisCore to the real model (`CoreRequest.tuneUp`, additive) and shows load time, time to first word, speed and peak memory. If the 9B writes fewer than 8 tokens a second, Aegis downloads the 4B and records the choice in `Aegis/model-choice`. `ModelChoice.current` reads that file before falling back to the memory rule, so AegisCore and ModelService follow it.
- No new package: URLSession and CryptoKit.

## Consequences

- A fresh Mac gets everything it needs from the wizard: about 3 GB (16 GB Macs) or 6 GB (24 GB or more), plus 130 MB.
- An interrupted file starts again from the beginning (no byte ranges yet); finished files are kept.
- Stepping up to a larger model on a 16 GB Mac (DESIGN.md, "only if it runs without swapping") isn't offered yet.
