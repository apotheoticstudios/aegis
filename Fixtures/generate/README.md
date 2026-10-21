# Synthetic fixture generator (Stage 0, issue #14)

Builds invented copies of the three macOS stores Aegis reads, plus **what a correct reader must get from them**, so readers can be built and tested on Linux without ever touching real data.

```
python3 Fixtures/generate/generate.py OUT_DIR [--seed 7] [--profile full|empty|drift] [--huge]
```

Generate into a temp folder at test time. Never commit the output: the privacy guard rejects database and `.emlx` files.

## What it writes

| Path | What it is | Layout |
| --- | --- | --- |
| `notifications/db` | Notification Center database (WAL mode): `app`, `record` (binary-plist `data`), `dbinfo` | hypothetical until #4's `schema` output |
| `messages/chat.db` | Messages: `message`, `handle`, `chat`, joins, attachments; text in `text` or only in `attributedBody` (typedstream) | hypothetical until #19 |
| `mail/V10/...` | `MailData/Envelope Index` plus `.emlx` / `.partial.emlx` files in `INBOX.mbox` and `Archive.mbox` | hypothetical until #19 |
| `expected/notifications.jsonl`, `messages.jsonl`, `mail.jsonl` | Contract events (`Prototype/contracts`) a correct reader emits, one file per reader | |
| `expected/problems.json` | Errors and skips a correct reader reports instead of an event | |
| `expected/duplicates.json` | Notification/Messages twins the pipeline (#17) should merge | |
| `manifest.json` | Seed, profile, counts, and which layouts are verified | |

Expected events use `capture_time` = `2026-10-06T21:00:00Z`; reader tests compare everything except capture times.

## Reader rules the expected files encode

- **IDs:** notification `uuid` as an upper-case UUID string; Messages `guid`; mail `Message-ID` header including angle brackets.
- **Notifications:** sender `null`, title `titl` (`null` when it isn't a string), body `body`; `content` is `preview`, or `redacted` when the body is empty.
- **Messages:** sender is the handle (`"me"` when `is_from_me`); thread is `chat.guid` (`null` for a message in no chat, with a `chat_missing` problem); a group's title is its display name.
  - `content` is `complete`. An attachment-only message (only U+FFFC) has an empty body, `unavailable` and the flag `attachment_only`.
  - An edit adds the flag `edited`. Reactions are skipped.
- **Mail:**
  - Sender is the decoded `From`, title the decoded, unfolded `Subject`, body the decoded `text/plain` part (HTML-only mail: tags stripped and whitespace collapsed).
  - Time is the `Date` header (`-0000` means UTC). Without `Date`, the time comes from the first `Received` header (`event_time_source: received`).
  - Encrypted mail: empty body, `unavailable`, flag `encrypted`. A partial download: `preview`, flag `truncated`. Attachment-only mail: `unavailable`, flag `attachment_only`.
  - A Message-ID filed twice gives one event.
- **Unknown is `null`**, as the contract says: never a placeholder value.
- **Text is kept exactly**, including emoji, NFD names, bidi overrides and zero-width characters. Sanitizing for display is the UI's job.
- **Future times** are kept and flagged `clock_skew`. Times before 2001, or impossibly far ahead, are rejected.

## Edge cases covered (numbers from #6)

| # | Where |
| --- | --- |
| 1 | Corrupt plist blob (notifications) |
| 2 | NULL and zero timestamps, missing app row, an array where the title belongs (notifications) |
| 3 | `attributedBody`-only text, an unparseable one, invalid UTF-8, attachment-only (messages) |
| 4 | `.emlx` framing: count not a number, truncated file, missing trailer |
| 5 | `.partial.emlx`; an index row whose file is gone |
| 6 | Quoted-printable soft breaks, unpadded base64, ISO-8859-1, Windows-1252, GB18030, HTML-only, folded headers, header smuggling, a fake boundary line |
| 7 | S/MIME-encrypted body |
| 8 | Instructions to the assistant in all three stores |
| 9 | ZWJ emoji, flags, skin tones, NFD vs NFC names, bidi override, zero-width and NUL characters |
| 10 | Seconds-based (old) and impossible Messages dates |
| 11 | Daylight-saving fall-back night, `-0000`, missing `Date` |
| 12 | Future (clock skew) and negative notification times |
| 13 | A message seen as a notification and in `chat.db` (exact, and 1 s apart in a group) |
| 14 | Reactions, an edited SMS, a NULL guid, one Message-ID in two mailboxes |
| 15 | Group chat, the owner's own message, an orphan, a missing handle, one person on phone and email |
| 16 | `--profile empty` |
| 19 | `--huge`: 200,000 extra messages and a ~24 MB email (not in the expected events) |
| 20 | `--profile drift`: an Envelope Index without `conversation_id` |

Not covered by stores (reader tests use fakes instead): 17 (permission revoked mid-run) and 18 (concurrent writers and file replacement; open the WAL database with a writer to test it).

## Tests

`make test-fixtures`: determinism, layouts, contract validity, plist and typedstream decoding, and a check that every expected mail body, subject, sender and time is exactly what Python's own mail parser recovers. Set `AEGIS_FIXTURES_HUGE=1` to also build the large profile.
