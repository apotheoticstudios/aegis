"""Messages database (chat.db) → contract events (Stage 0, issue #15).

Rules (they match `Fixtures/generate`'s expected output):
- One event per message row with a guid. `source` is "sms" for the SMS service, else "imessage".
- Skipped and reported, as they carry no message text of their own (codes per the research on #37):
  reactions and their removals, stickers placed on a message and poll votes (associated_message_type
  1000, 2000–3999, 4000); system rows such as group renames, members added or removed, location
  sharing, FaceTime (item_type other than 0, or is_system_message); unsent messages (date_retracted
  set and no text left).
- sender is the handle (phone or email), "me" for the owner's messages, null (and a problem) when the
  handle row is missing. thread is the chat guid, or null (and a `chat_missing` problem) for a message
  in no chat; a message in several chats gets the first. title is the chat's display name, if any.
- body is `text`, else the string inside `attributedBody`; content is `complete`. An unreadable
  `attributedBody` gives an empty body, `unavailable` and a problem. A body that is only attachment
  placeholders (U+FFFC) is empty, `unavailable`, flag `attachment_only`. An edited message is flagged `edited`.
- `date` is nanoseconds since 2001 (seconds on old databases). Future times are kept and flagged
  `clock_skew`; times before 2001 or after 2100 are problems.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime
from typing import Iterator, Optional

from reader_base import Item, ReadResult, cocoa, cocoa_seconds, iso, make_event, number, problem, require, scan, skew_flags
from typedstream_reader import text_from_attributed_body

APP = "com.apple.MobileSMS"
OBJECT_REPLACEMENT = "\ufffc"  # how an attachment appears inside the text
# Rows attached to another message rather than standalone: 1000 sticker, 2000–2007 reaction added,
# 3000–3007 removed (the rest of 2000–3999 kept for future reaction kinds), 4000 poll vote.
ASSOCIATIONS = {1000, 4000} | set(range(2000, 4000))
NANOSECONDS_THRESHOLD = 10**14  # nanosecond dates are past this after 2 January 2001; second dates never reach it


def _moment(value) -> Optional[datetime]:
    stamp = number(value)
    if not stamp:
        return None
    return cocoa(stamp / 1e9 if abs(stamp) > NANOSECONDS_THRESHOLD else stamp)


def iter_messages(conn: sqlite3.Connection, now: datetime, since: Optional[datetime] = None) -> Iterator[Item]:
    """Yields ("event", event) and ("problem", problem) one message at a time."""
    found = require(conn, "message", ["guid", "text", "attributedBody", "handle_id", "service", "date", "is_from_me"])
    require(conn, "handle", ["id"])
    require(conn, "chat", ["guid", "display_name"])
    require(conn, "chat_message_join", ["chat_id", "message_id"])
    optional = {column: f"m.{column}" if column in found else "0"
                for column in ("associated_message_type", "date_edited", "item_type", "is_system_message", "date_retracted")}
    query = (
        "SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, h.id, m.service, m.date, m.is_from_me, "
        f"{optional['associated_message_type']}, {optional['date_edited']}, {optional['item_type']}, "
        f"{optional['is_system_message']}, {optional['date_retracted']}, "
        "c.guid, c.display_name FROM message m "
        "LEFT JOIN handle h ON h.ROWID = m.handle_id "
        "LEFT JOIN chat_message_join j ON j.message_id = m.ROWID "
        "LEFT JOIN chat c ON c.ROWID = j.chat_id"
    )
    params = ()
    if since is not None:  # dates in nanoseconds, or in seconds on old databases (the same rule as _moment)
        seconds = int(cocoa_seconds(since))
        query += " WHERE (m.date > ? AND m.date >= ?) OR (m.date <= ? AND m.date >= ?)"
        params = (NANOSECONDS_THRESHOLD, seconds * 10**9, NANOSECONDS_THRESHOLD, seconds)
    captured = iso(now)
    previous = None
    for row in conn.execute(query + " ORDER BY m.ROWID, j.chat_id", params):
        (rowid, guid, text, attributed, handle_id, handle, service, date, from_me, kind, edited_at, item_type, system,
         retracted, chat_guid, display) = row
        if rowid == previous:
            continue  # the same message joined to another chat
        previous = rowid
        source = "sms" if service == "SMS" else "imessage"
        if kind in ASSOCIATIONS:
            yield "problem", problem("reaction_skipped", source, guid or "(null)", f"associated_message_type {kind}")
            continue
        if item_type or system:
            yield "problem", problem("system_item_skipped", source, guid or "(null)", f"item_type {item_type}")
            continue
        if not guid:
            yield "problem", problem("missing_guid", source, "(null)", "a message row whose guid is NULL")
            continue
        moment = _moment(date)
        if moment is None:
            yield "problem", problem("missing_timestamp" if not number(date) else "timestamp_out_of_range", source, guid)
            continue
        if from_me:
            sender = "me"
        elif handle is not None:
            sender = handle
        else:
            sender = None
            yield "problem", problem("missing_handle", source, guid, f"handle_id {handle_id} has no handle row")
        if chat_guid is None:
            yield "problem", problem("chat_missing", source, guid)
        content, flags = "complete", []
        if text:
            body = text
        elif attributed:
            try:
                body = text_from_attributed_body(attributed)
            except ValueError:
                body, content = "", "unavailable"
                yield "problem", problem("attributed_body_parse_error", source, guid)
        else:
            body, content = "", "unavailable"
        if OBJECT_REPLACEMENT in body and not body.replace(OBJECT_REPLACEMENT, "").strip():
            body, content, flags = "", "unavailable", ["attachment_only"]
        if retracted and not body:  # unsent: the row stays, its text is gone
            yield "problem", problem("unsent_skipped", source, guid)
            continue
        if edited_at:
            flags.append("edited")
        yield "event", make_event(
            source=source,
            source_record_id=guid,
            route="chat_db",
            app_id=APP,
            sender=sender,
            thread_id=chat_guid,
            title=display or None,
            body=body,
            content=content,
            event_time=moment,
            event_time_source="sent",
            capture_time=captured,
            flags=flags + skew_flags(moment, now),
        )


def read_messages(path, now=None, since=None, busy_timeout: float = 5.0, on_item=None) -> ReadResult:
    """Reads a Messages database (`chat.db`). See `reader_base.scan` for statuses and streaming."""
    return scan(path, iter_messages, now, since, busy_timeout, on_item)
