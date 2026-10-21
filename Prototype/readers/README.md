# Readers: notifications and Messages (Stage 0, issue #15)

Turn the Mac's Notification Center database and the Messages database (`chat.db`) into **events** in the shared format (`Prototype/contracts`), plus a list of **problems** (records that were skipped or couldn't be read, with the reason). The brief pipeline (#17) and the owner's one-day trial (#19) build on these. The Mail reader is separate (#16).

## Why it's safe

- **Read-only.** The databases are opened with SQLite's `mode=ro` (never `immutable=1`, which would ignore the newest changes). If opening a database read-only would make SQLite create helper files next to it, the reader uses a private temporary copy of the database and its change log instead. Tests check that nothing next to a database is created or changed.
- **Counts only on screen.** The command-line tool prints numbers and status codes, never message text. A test checks this.
- **Stays on your Mac.** Python standard library only, no network.
- **You run it on real data, not an AI.** Agents and tests only use fake databases from `Fixtures/generate`.

## Try it on fake data (anyone)

```
python3 Fixtures/generate/generate.py /tmp/aegis-fixtures
python3 Prototype/readers/read.py --fixtures /tmp/aegis-fixtures
```

Expect `notifications ok events 11` and `messages ok events 14`, with the problems the fake data contains on purpose.

## Run it on your real data (owner only, for the trial in #19)

Use the **Terminal** app with Full Disk Access (the same setup as the notification probe, `Prototype/probe/README.md`), not Claude's terminal panel.

```
python3 ~/Documents/Aegis/Prototype/readers/read.py
```

It reads the last 24 hours (`--hours N` changes that; `--hours 0` reads everything) and prints one line per source: status, number of events, problems by type, and time taken. Paste that output into the issue; it has no message text in it.

`--save` also writes the events to `Prototype/output/readers/` for the brief pipeline. **Those files do contain message text.** They're readable only by you, git ignores that folder, and you should delete them when the trial is done.

## Status codes

| Code | Meaning | What to do |
| --- | --- | --- |
| `ok` | Events were read | |
| `no_data` | The database is readable but has nothing (in the time window) | |
| `not_found` | No database at that path | Check the macOS version; the path may have moved |
| `permission_denied` | macOS refused access | Give Terminal Full Disk Access, quit and reopen it |
| `busy` | The database was locked, or kept changing while being copied | Run again |
| `unreadable` | Not a SQLite database, or damaged | Report it |
| `unknown_schema` | The tables or columns differ from what the reader knows (a typed error, `UnknownSchemaError`, in code) | Paste the line (it lists table and column names only) on the issue |

## Rules the readers follow

The fake-data generator encodes the same rules in its expected output (`Fixtures/generate/README.md`), and the tests compare against it exactly.

- **Notifications:** one event per delivered record. The id is the record's `uuid`; app from the `app` table; title `req.titl`, body `req.body`; `preview`, or `redacted` when previews are hidden; time `delivered_date`. Requested-but-not-delivered records are skipped (`not_delivered`) and picked up on a later run.
- **Messages:** one event per message with a guid. Rows with no text of their own are skipped and reported: reactions, stickers and poll votes (`reaction_skipped`); system rows such as group renames, members added or removed, location sharing and FaceTime (`system_item_skipped`); unsent messages (`unsent_skipped`). The codes come from the open-source research (`docs/design/open-source-references.md`). The sender is the phone number or email, or `me`; thread is the chat (none for a message in no chat); group chats have their name as the title. The text comes from `text`, or from inside `attributedBody` when `text` is empty. Attachment-only messages are empty and flagged; edited ones are flagged. Dates in nanoseconds (or seconds on old databases).
- **Everywhere:** text is kept exactly (emoji, accents, invisible characters; cleaning up for display is the UI's job). Future times are kept and flagged `clock_skew`; times before 2001 or after 2100 are problems.

Not yet known until the trial (#19) shows real layouts: whether notification subtitles carry information worth keeping (schema 0.1 has no subtitle field). System rows in `chat.db` are now skipped, using codes from the open-source research.

## For developers

| File | What it does |
| --- | --- |
| `reader_base.py` | Read-only opening, statuses, time conversion, `scan()` (streaming, bounded memory with `on_item`) |
| `notification_reader.py` | `iter_notifications`, `read_notifications(path, now, since, ...)` |
| `messages_reader.py` | `iter_messages`, `read_messages(path, now, since, ...)` |
| `typedstream_reader.py` | Text out of `attributedBody` (written from the format's description, not from GPL code) |
| `read.py` | The command-line tool above |

`make test-prototype` runs the tests (fake data only; also on Linux in CI). `AEGIS_FIXTURES_HUGE=1` adds a 200,000-message streaming test.

## Mail (Stage 0, issue #16)

`mail_reader.read_mail(path, now=None, since=None, on_item=None)` accepts an
Envelope Index, a `V*` directory, or a Mail root (selects the highest numbered
version). `read.py --source mail --fixtures DIR` prints counts only; `all` now
includes Mail. The owner-only default uses the Mail root under `Library/Mail`.

The reader follows index rows in order and reads each matching `.emlx` or
`.partial.emlx` within that version. It respects the decimal byte count and
ignores the plist trailer; invalid counts and short files produce
`emlx_framing_error`, absent or vanished files `body_file_missing`. Malformed
headers produce `message_parse_error` with a rowid and no message text; other
messages continue to read. Decoded From and Subject
come only from headers (absent headers are null, present empty headers remain
empty). It selects text/plain, falling back to HTML with tags removed and
whitespace collapsed; head, title, style and script text is excluded. Date supplies UTC time (`-0000` means UTC);
without Date, the first Received header supplies it. Encrypted and attachment-only
mail have empty, unavailable bodies and flags; partial downloads are flagged
truncated and are previews only when readable body text is present. Duplicate Message-IDs produce one event and a
`duplicate_message_id` problem. Missing conversation_id is supported.

With `on_item`, events and problems are handed over immediately. MIME attachments
are drained in bounded chunks without decoding; Message-ID deduplication uses a
private temporary SQLite table rather than a growing in-memory set. Deleted
rows are skipped. A time window first filters date_received in SQL with one day
of slack, then checks the exact Date/Received time. Selected rowids and their
file paths are staged in the private database during one tree walk. Memory still
scales with a single text body and MIME nesting depth, not the number of rows.
Junk/Trash mailbox exclusion remains a question for the owner's trial (#19).
All layouts remain hypothetical until the owner's trial; IMAP is out of scope.
`AEGIS_FIXTURES_HUGE=1` also checks the ~24 MB attachment against the fixture
oracle while enforcing a 4 MB traced allocation budget for the reader.
