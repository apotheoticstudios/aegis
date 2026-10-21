# Prototype (Stage 0)

Throwaway Python scripts that prove the risky parts: reading Messages, notifications and Mail, and generating a brief with a local MLX model.

- Agents write and test these against `Fixtures/` only.
- Only the human runs them on real data (Terminal needs Full Disk Access for that).
- Output from real data goes to `Prototype/output/`, which is gitignored. Never commit it, and never paste it into an AI chat.
- Code here will not ship; the real app is Swift (ADR-0001).
