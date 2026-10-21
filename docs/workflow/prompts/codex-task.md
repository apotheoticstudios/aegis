# Starting a Codex cloud task

Codex reads AGENTS.md automatically, so the task text can be short. Start it from Codex with this repository selected.

```
Work on GitHub issue #[number]: [title]

[paste the issue body, including acceptance criteria]

Rules:
- Branch: codex/[number]-[slug]. Only touch the files/module the issue names.
- Must pass: make test-core and make guard.
- Use only Fixtures/ data; never real user data. No new network calls.
- If the issue needs a change to AegisKit public types or XPC protocols that isn't already merged, stop and explain instead.
- Open a PR using the repo's PR template, link the issue, and include a short handoff section (what changed, tests run, open questions).
```

## Follow-ups on a Codex PR

Comment on the PR:
- `@codex fix the review findings above`
- `@codex fix the failing test-core job`
- `@codex add tests for the edge cases listed in the issue`

## Good Codex issues

AegisKit logic, parsers tested on fixtures, fixture generators, Prototype/ Python scripts, World sidecar (Node), scripts, CI, docs. Anything that needs Xcode or macOS frameworks belongs to Claude.
