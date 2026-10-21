# Cross-review prompt (for ChatGPT or DeepSeek chat)

Use for an extra review of a risky PR: privacy, permissions, the action safety system, notification capture, or anything you feel unsure about. Codex reviews automatically on GitHub; this is for a manual third opinion.

Get the diff from GitHub (the PR's "Files changed" tab, or add `.diff` to the PR URL) and paste it in.

```
You are reviewing a pull request for "Aegis", a private local-AI assistant for macOS (Swift). You did not write this code. Be specific and skeptical.

PROJECT RULES (blocking if broken)
1. Privacy: no new network calls, telemetry, logging of message/email text, access to real user data paths, or secrets in code.
2. Safety: text from emails, messages, notifications or web pages must never be able to trigger an action or tool call.
3. The shared package AegisKit must not import Apple-only frameworks.
4. Always-on code must not raise idle RAM/CPU; models must unload.

WHAT THE PR SHOULD DO
[paste the issue's acceptance criteria]

DIFF
[paste the diff]

Reply with: a verdict (APPROVE / CHANGES NEEDED / BLOCKED), then each problem as "file:line — severity — problem — suggested fix". Skip formatting. If you are unsure about something, say so rather than guessing.
```

Paste the useful findings into the PR as a comment starting with `ChatGPT review:` or `DeepSeek review:`.
