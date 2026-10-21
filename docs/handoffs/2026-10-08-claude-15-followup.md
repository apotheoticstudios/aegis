# Handoff — Claude — issue #15 (follow-up) — 2026-10-08

## What changed
- `messages_reader.py` skips and reports rows with no text of their own, using codes from the open-source research (#37):
  - `system_item_skipped`: `item_type` ≠ 0 or `is_system_message` (group renames, members added or removed, location sharing, kept audio, FaceTime).
  - `unsent_skipped`: `date_retracted` set and no text left. A partly unsent message with text stays an event.
  - `reaction_skipped`: `associated_message_type` 1000 (sticker on a message), 2000–3999 (reactions added and removed), 4000 (poll vote).
- All three columns are optional, so older databases still read. README rules updated. One regression test, which fails on the previous reader.

## Decisions made (and why)
- None new. These rows were the open question in #15's handoff, answered by the research.

## Tests run
- `make test-prototype` on Python 3.9 and 3.12; `make guard`.

## Open questions / risks
- The codes come from a mature open-source reader (facts only; GPL code not copied). The trial (#19) confirms them on real data.

## Next step (and who)
- Owner: the Mac tests (#4, #10, #11) and the cold model load (#18).
- Claude: the day-5 gate summary once those results are in.
