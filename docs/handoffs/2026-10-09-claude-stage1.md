# Handoff — Claude — Stage 1 hub session — 2026-10-09

## What changed
- Merged after review and green CI: #88 (store), #90 (DeepSeek's plan points), #91 (pipeline port), #92 (contact identity), #93 (held-out fixtures). Reviews are on #92 and #93.
- ChatGPT answered the four Stage 1 research questions; summary and fact check on #67, pointer on #66.
- DeepSeek reviewed the Swift pipeline port read-only; findings verified and recorded on #94.
- New Codex cloud tasks started from the ChatGPT app: #94 (brief checks), #95 (noise rules), #96 (sender display).
- Contract fix #97 (PR #98): calendar occurrence ID from the original occurrence date; stage1 fixtures updated; a Swift test decodes the generated calendar.

## Decisions made (and why)
- v0.2 is amended in place for `occurrence_date`: nothing has stored v0.2 data yet.
- Malformed model items (DeepSeek's finding): drop structurally broken items and count them; reject the whole draft only on signs of steering (planted order ranked urgent, an action field, more than 2 dropped items). To apply when reviewing #94's PR.
- #95 and #96 both touch `BriefInput.swift`: each issue names its lines; Claude merges them in order #95 then #96.

## Tests run
- `make test-core`: main 185 tests, 0 failures (macOS); #98 187 tests.
- `make guard`: passes.
- `make test-fixtures`: passes on #98 (main fails locally on the Mac's Python 3.9 until #98 merges; CI uses a newer Python).

## Open questions / risks
- No Apple Development signing identity on this Mac: blocks #66 and real code-signing checks in #67 (owner to sign in to Xcode).
- The "gives orders" rule misses greetings outside its list, in Swift and Python alike: follow-up after #94/#95.

## Next step (and who)
- Claude: #67 XPC routing spike on the Mac; review and merge #94–#96 and #98.
- Owner: Xcode Apple ID sign-in; Apple Mail accounts; the clean-up items in STATUS.
