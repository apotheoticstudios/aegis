# ChatGPT research prompt

For `type:research` issues. Use the ChatGPT "Aegis" project (it has DESIGN.md and AGENTS.md). Turn on web search or deep research for questions about current Apple behaviour.

```
Research question for the Aegis project (issue #[number]):
[question, e.g. "On macOS 15 and 26, are iPhone notifications shown via iPhone Mirroring written to the Notification Center database? What are the table/columns and the bundle IDs used?"]

What we need:
- A direct answer first, then the evidence.
- Which macOS/iOS versions it applies to, and what changed between versions.
- The exact Apple APIs, frameworks, entitlements or permissions involved.
- Known limitations and how other apps handle them.
- Links to sources (Apple documentation first). Say clearly what you could not confirm.
Keep it under 600 words.
```

Paste the answer into the issue as a comment starting with `ChatGPT research:`. Claude turns confirmed findings into code or an ADR.
