"""Synthetic macOS Messages database, chat.db (Stage 0, issue #14).

Tables and columns per the research on #5 (hypothetical until checked on the owner's Mac, #19):
message, handle, chat, chat_message_join, chat_handle_join, attachment, message_attachment_join.
Dates are nanoseconds since 2001-01-01 (older databases used seconds); text is in `text` or only in
`attributedBody` (a typedstream blob, see typedstream.py).
"""

from __future__ import annotations

import sqlite3
from datetime import timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import typedstream
from common import COCOA_EPOCH, INJECTIONS, PEOPLE, Rng, at, cocoa_nanoseconds, event, problem
from notifications import ALEX_CALL_HOURS, ALEX_CALL_TEXT, FAMILY_HOURS, FAMILY_TEXT

SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, country TEXT, service TEXT NOT NULL,
  uncanonicalized_id TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, state INTEGER,
  account_id TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE, text TEXT, attributedBody BLOB,
  handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER, date_read INTEGER, date_delivered INTEGER,
  is_from_me INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0, associated_message_guid TEXT,
  associated_message_type INTEGER DEFAULT 0, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0,
  thread_originator_guid TEXT);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0,
  PRIMARY KEY (chat_id, message_id));
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE (chat_id, handle_id));
CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, filename TEXT,
  mime_type TEXT, transfer_name TEXT, total_bytes INTEGER DEFAULT 0);
CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER, UNIQUE (message_id, attachment_id));
"""

APP = "com.apple.MobileSMS"
OBJECT_REPLACEMENT = "￼"  # what an attachment looks like inside attributedBody


def build(folder: Path, rng: Rng, empty: bool = False, extra_rows: int = 0) -> Tuple[List[Dict], List[Dict], List[Dict]]:
    """Creates `folder/chat.db`. Returns (expected events, expected problems, duplicate anchors)."""
    folder.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(folder / "chat.db"))
    conn.executescript(SCHEMA)
    events: List[Dict] = []
    problems: List[Dict] = []
    anchors: List[Dict] = []
    if empty:
        conn.commit()
        conn.close()
        return events, problems, anchors

    def handle(person: str, kind: str = "phone", service: str = "iMessage") -> int:
        value = PEOPLE[person][kind]
        return conn.execute("INSERT INTO handle (id, country, service) VALUES (?, 'au', ?)", (value, service)).lastrowid

    def chat(guid: str, identifier: str, members: List[int], display: Optional[str] = None, style: int = 45) -> Tuple[int, str]:
        rowid = conn.execute(
            "INSERT INTO chat (guid, style, state, chat_identifier, service_name, display_name) VALUES (?, ?, 3, ?, 'iMessage', ?)",
            (guid, style, identifier, display or ""),
        ).lastrowid
        conn.executemany("INSERT INTO chat_handle_join VALUES (?, ?)", [(rowid, member) for member in members])
        return rowid, guid

    def message(
        *,
        chat_row: Optional[int],
        handle_row: Optional[int],
        hours: float,
        text: Optional[str] = None,
        body: Optional[bytes] = None,
        service: str = "iMessage",
        from_me: bool = False,
        date: Optional[int] = None,
        guid: Optional[str] = "auto",
        reaction_to: Optional[str] = None,
        edited: bool = False,
    ) -> str:
        message_guid = rng.uuid() if guid == "auto" else guid
        stamp = date if date is not None else cocoa_nanoseconds(at(hours))
        rowid = conn.execute(
            "INSERT INTO message (guid, text, attributedBody, handle_id, service, date, date_delivered, is_from_me, "
            "associated_message_guid, associated_message_type, date_edited) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                message_guid,
                text,
                body if body is not None else (typedstream.attributed_body(text) if text else None),
                handle_row if handle_row is not None else None,
                service,
                stamp,
                stamp,
                1 if from_me else 0,
                f"p:0/{reaction_to}" if reaction_to else None,
                2000 if reaction_to else 0,
                stamp + 60_000_000_000 if edited else 0,
            ),
        ).lastrowid
        if chat_row is not None:
            conn.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", (chat_row, rowid, stamp))
        return message_guid or ""

    def expect(guid: str, *, sender: Optional[str], thread: Optional[str], hours: float, body: str, content: str = "complete",
               source: str = "imessage", title: Optional[str] = None, flags: Optional[List[str]] = None, moment=None) -> None:
        events.append(
            event(
                source=source,
                source_record_id=guid,
                route="chat_db",
                app_id=APP,
                sender=sender,
                thread_id=thread,
                title=title,
                body=body,
                content=content,
                event_time=moment or at(hours),
                event_time_source="sent",
                flags=flags,
            )
        )

    alex_phone = handle("alex")
    sam_phone = handle("sam")
    casey_phone = handle("casey")
    jordan_sms = handle("jordan", service="SMS")
    unknown = handle("unknown")
    jose_phone = handle("jose")
    jose_email = handle("jose", kind="email")

    alex_chat, alex_guid = chat(f"iMessage;-;{PEOPLE['alex']['phone']}", PEOPLE["alex"]["phone"], [alex_phone])
    sam_chat, sam_guid = chat(f"iMessage;-;{PEOPLE['sam']['phone']}", PEOPLE["sam"]["phone"], [sam_phone])
    family_chat, family_guid = chat("iMessage;+;chat000000000000000001", "chat000000000000000001",
                                    [alex_phone, sam_phone, casey_phone], display="Family", style=43)
    jordan_chat, jordan_guid = chat(f"SMS;-;{PEOPLE['jordan']['phone']}", PEOPLE["jordan"]["phone"], [jordan_sms])
    unknown_chat, unknown_guid = chat(f"iMessage;-;{PEOPLE['unknown']['phone']}", PEOPLE["unknown"]["phone"], [unknown])
    jose_phone_chat, jose_phone_guid = chat(f"iMessage;-;{PEOPLE['jose']['phone']}", PEOPLE["jose"]["phone"], [jose_phone])
    jose_email_chat, jose_email_guid = chat(f"iMessage;-;{PEOPLE['jose']['email']}", PEOPLE["jose"]["email"], [jose_email])

    # Ordinary messages, including the twin of a notification (edge case 13).
    guid = message(chat_row=alex_chat, handle_row=alex_phone, hours=ALEX_CALL_HOURS, text=ALEX_CALL_TEXT)
    expect(guid, sender=PEOPLE["alex"]["phone"], thread=alex_guid, hours=ALEX_CALL_HOURS, body=ALEX_CALL_TEXT)
    anchors.append({"message": guid, "key": "message:alex-call"})

    # Edge case 15: a group chat, a message from the owner ("me"), and the group's notification twin.
    family_message = message(chat_row=family_chat, handle_row=casey_phone, hours=FAMILY_HOURS, text=FAMILY_TEXT)
    expect(family_message, sender=PEOPLE["casey"]["phone"], thread=family_guid, hours=FAMILY_HOURS, body=FAMILY_TEXT, title="Family")
    anchors.append({"message": family_message, "key": "message:family-dessert"})
    guid = message(chat_row=family_chat, handle_row=None, hours=12.0, text="I'll bring dessert on Sunday.", from_me=True)
    expect(guid, sender="me", thread=family_guid, hours=12.0, body="I'll bring dessert on Sunday.", title="Family")

    # Edge case 14: a reaction is not a message of its own.
    reaction = message(chat_row=family_chat, handle_row=alex_phone, hours=11.9, text="Loved “Who's bringing dessert on Sunday?”",
                       reaction_to=family_message)
    problems.append(problem("reaction_skipped", "imessage", reaction, "associated_message_type 2000"))

    # Edge case 3: text only in attributedBody; an unparseable attributedBody; an attachment-only message.
    guid = message(chat_row=sam_chat, handle_row=sam_phone, hours=10.5, body=typedstream.attributed_body("hello 👋"))
    expect(guid, sender=PEOPLE["sam"]["phone"], thread=sam_guid, hours=10.5, body="hello 👋")
    guid = message(chat_row=sam_chat, handle_row=sam_phone, hours=10.4, body=typedstream.corrupt())
    expect(guid, sender=PEOPLE["sam"]["phone"], thread=sam_guid, hours=10.4, body="", content="unavailable")
    problems.append(problem("attributed_body_parse_error", "imessage", guid))
    guid = message(chat_row=sam_chat, handle_row=sam_phone, hours=10.3, body=typedstream.attributed_body(OBJECT_REPLACEMENT))
    attachment = conn.execute(
        "INSERT INTO attachment (guid, filename, mime_type, transfer_name, total_bytes) VALUES (?, ?, 'image/jpeg', 'beach.jpg', 2048)",
        (rng.uuid(), "~/Library/Messages/Attachments/00/00/beach.jpg"),  # privacy-guard: allow-real-path synthetic fixture path text
    ).lastrowid
    conn.execute("INSERT INTO message_attachment_join VALUES ((SELECT ROWID FROM message WHERE guid = ?), ?)", (guid, attachment))
    conn.execute("UPDATE message SET cache_has_attachments = 1 WHERE guid = ?", (guid,))
    expect(guid, sender=PEOPLE["sam"]["phone"], thread=sam_guid, hours=10.3, body="", content="unavailable", flags=["attachment_only"])

    # Edge case 3 (bad bytes): a lone surrogate's worth of invalid UTF-8 becomes U+FFFD, not a crash.
    guid = message(chat_row=sam_chat, handle_row=sam_phone, hours=10.2,
                   body=typedstream.attributed_body_from_bytes(b"ok \xed\xa0\x80 ok", characters=7))
    expect(guid, sender=PEOPLE["sam"]["phone"], thread=sam_guid, hours=10.2, body="ok ��� ok")

    # Edge case 8: instructions inside a message are data.
    guid = message(chat_row=unknown_chat, handle_row=unknown, hours=9.0, text=INJECTIONS[0])
    expect(guid, sender=PEOPLE["unknown"]["phone"], thread=unknown_guid, hours=9.0, body=INJECTIONS[0])

    # Edge case 14: an edited SMS keeps one event and is flagged.
    guid = message(chat_row=jordan_chat, handle_row=jordan_sms, hours=14.5, text="Running 10 minutes late, sorry!", service="SMS", edited=True)
    expect(guid, sender=PEOPLE["jordan"]["phone"], thread=jordan_guid, hours=14.5, body="Running 10 minutes late, sorry!",
           source="sms", flags=["edited"])

    # Edge case 10: an old database's seconds-since-2001 date, and an impossible date.
    old_moment = COCOA_EPOCH + timedelta(seconds=706_000_000)
    guid = message(chat_row=alex_chat, handle_row=alex_phone, hours=0, text="From an old Mac (seconds, not nanoseconds)", date=706_000_000)
    expect(guid, sender=PEOPLE["alex"]["phone"], thread=alex_guid, hours=0, body="From an old Mac (seconds, not nanoseconds)", moment=old_moment)
    guid = message(chat_row=alex_chat, handle_row=alex_phone, hours=0, text="Impossible date", date=9_000_000_000_000_000_000)
    problems.append(problem("timestamp_out_of_range", "imessage", guid, "9e18 ns is about 285 years after 2001"))

    # Edge case 15: an orphan (no chat), a missing handle, and one person reachable by phone and by email.
    guid = message(chat_row=None, handle_row=alex_phone, hours=6.5, text="A message with no chat")
    expect(guid, sender=PEOPLE["alex"]["phone"], thread=None, hours=6.5, body="A message with no chat")
    problems.append(problem("chat_missing", "imessage", guid))
    guid = message(chat_row=alex_chat, handle_row=999, hours=6.4, text="Sender row missing")
    expect(guid, sender=None, thread=alex_guid, hours=6.4, body="Sender row missing")
    problems.append(problem("missing_handle", "imessage", guid, "handle_id 999 has no handle row"))
    guid = message(chat_row=jose_phone_chat, handle_row=jose_phone, hours=5.0, text="Texting from my phone")
    expect(guid, sender=PEOPLE["jose"]["phone"], thread=jose_phone_guid, hours=5.0, body="Texting from my phone")
    guid = message(chat_row=jose_email_chat, handle_row=jose_email, hours=4.9, text="And now from my email address")
    expect(guid, sender=PEOPLE["jose"]["email"], thread=jose_email_guid, hours=4.9, body="And now from my email address")

    # Edge case 14: a row without a guid can't get a durable id.
    guid = message(chat_row=alex_chat, handle_row=alex_phone, hours=4.0, text="No guid", guid=None)
    problems.append(problem("missing_guid", "imessage", "(null)", "a message row whose guid is NULL"))

    # Edge case 19: optional bulk rows for streaming and memory tests (not in the expected events).
    if extra_rows:
        rows = [(f"BULK-{i:07d}-{rng.uuid()[:8]}", f"Bulk message {i}", alex_phone, cocoa_nanoseconds(at(20 + i / 1000))) for i in range(extra_rows)]
        conn.executemany("INSERT INTO message (guid, text, handle_id, service, date) VALUES (?, ?, ?, 'iMessage', ?)", rows)

    conn.commit()
    conn.close()
    return events, problems, anchors
