# ADR-0006: Python mlx-lm for the Stage 0 model benchmark

- **Status:** accepted (owner approved the downloads on 2026-10-07)
- **Date:** 2026-10-07
- **Proposed by:** Claude · **Approved by:** human

## Context
Stage 0 task 0.14 (#18) must measure local models on the target Mac before Stage 1 commits to model sizes. DESIGN.md commits Aegis to MLX (MLX Swift in the shipping app). The quickest faithful way to measure MLX models is Apple's Python package `mlx-lm`, a new third-party dependency, which AGENTS.md says needs an ADR.

## Options considered
1. **Python `mlx-lm`**: Apple's reference runner for the same MLX engine and model files the app will use. Prototype only.
2. **MLX Swift now**: closest to the final app, but slower to build for a throwaway benchmark, and Stage 1's job.
3. **llama.cpp or Ollama**: mature, but a different engine and file format from what DESIGN.md commits to, so its numbers wouldn't transfer.

## Decision
Use `mlx-lm==0.32.0` (pulls `mlx==0.32.3`) in a private virtual environment, `Prototype/.venv` (gitignored), for Stage 0 only. Models are pinned by revision and run **offline** (`HF_HUB_OFFLINE=1`), each in its own process:
- `mlx-community/Qwen3.5-4B-MLX-4bit` @ `32f3e8ecf65426fc3306969496342d504bfa13f3` (3.1 GB, Apache-2.0): primary 3–4B candidate
- `mlx-community/Qwen3.5-9B-MLX-4bit` @ `938d8919941c6e7efd3c7150eff7fe9d12afa631` (6.0 GB, Apache-2.0): stretch candidate

Nothing in `Prototype/` ships. The app uses MLX Swift from Stage 1.

## Consequences
- The numbers come from the same engine and model files the app will use, so they carry over to Stage 1.
- About 9 GB of models in the Hugging Face cache (`~/.cache/huggingface`) and 0.4 GB of Python packages on the owner's Mac; delete them after Stage 0 if space is needed.
- Apache-2.0 licences keep a future public release open (an open question in DESIGN.md); Gemma's licence was avoided for that reason.
- The download is the only network use, done once with the owner's OK; runs are offline.
