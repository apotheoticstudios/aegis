"""Synthetic Apple Mail store (Stage 0, issue #14).

Per the research on #5 (hypothetical until checked on the owner's Mac): `V10/MailData/Envelope Index`
(messages, addresses, subjects, mailboxes, recipients, attachments; dates in Unix seconds) plus one
`.emlx` per message: a decimal byte count line, exactly that many bytes of RFC 822 message, then an XML
plist trailer. `.partial.emlx` uses the same wrapper for messages not fully downloaded.
"""

from __future__ import annotations

import base64
import plistlib
import sqlite3
from datetime import datetime, timedelta, timezone
from email.header import Header
from email.utils import format_datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from common import INJECTIONS, ME, PEOPLE, Rng, at, event, problem, unix_seconds

APP = "com.apple.mail"
BRISBANE = timezone(timedelta(hours=10))


def schema(drift: bool) -> str:
    conversation = "" if drift else ", conversation_id INTEGER"
    return f"""
CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT UNIQUE);
CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, sender INTEGER, subject INTEGER, mailbox INTEGER,
  date_sent INTEGER, date_received INTEGER, read INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0, deleted INTEGER DEFAULT 0{conversation});
CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, name TEXT);
"""


def _trailer(received: datetime) -> bytes:
    return plistlib.dumps({"date-received": unix_seconds(received), "flags": 8590195713, "remote-id": "1"}, sort_keys=True)


def emlx(message: bytes, received: datetime, *, count: Optional[str] = None, trailer: bool = True) -> bytes:
    """The .emlx wrapper: byte count line, the message, then the plist trailer."""
    first = (count if count is not None else str(len(message))).encode() + b"\n"
    return first + message + (_trailer(received) if trailer else b"")


def rfc822(headers: List[Tuple[str, str]], body: bytes) -> bytes:
    lines = [f"{name}: {value}".encode("utf-8") for name, value in headers]
    return b"\n".join(lines) + b"\n\n" + body


def build(folder: Path, rng: Rng, empty: bool = False, drift: bool = False, huge: bool = False) -> Tuple[List[Dict], List[Dict]]:
    """Creates `folder/V10/...`. Returns (expected events, expected problems)."""
    account = rng.uuid()
    data_dir = folder / "V10" / "MailData"
    data_dir.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(data_dir / "Envelope Index"))
    conn.executescript(schema(drift))
    events: List[Dict] = []
    problems: List[Dict] = []
    mailboxes = {}
    for name in ("INBOX", "Archive"):
        url = f"imap://{account}/{name}"
        mailboxes[name] = (conn.execute("INSERT INTO mailboxes (url) VALUES (?)", (url,)).lastrowid,
                           folder / "V10" / account / f"{name}.mbox" / rng.uuid() / "Data" / "Messages")
        mailboxes[name][1].mkdir(parents=True, exist_ok=True)
    if empty:
        conn.commit()
        conn.close()
        return events, problems

    addresses: Dict[str, int] = {}
    subjects: Dict[str, int] = {}

    def address_row(name: Optional[str], email: str) -> int:
        if email not in addresses:
            addresses[email] = conn.execute("INSERT INTO addresses (address, comment) VALUES (?, ?)", (email, name or "")).lastrowid
        return addresses[email]

    def subject_row(subject: str) -> int:
        if subject not in subjects:
            subjects[subject] = conn.execute("INSERT INTO subjects (subject) VALUES (?)", (subject,)).lastrowid
        return subjects[subject]

    def store(*, sender: Tuple[Optional[str], str], subject: str, moment: datetime, raw_emlx: Optional[bytes],
              conversation: int, mailbox: str = "INBOX", partial: bool = False, attachment: Optional[str] = None) -> int:
        columns = "message_id, sender, subject, mailbox, date_sent, date_received" + ("" if drift else ", conversation_id")
        values = [rng.random.getrandbits(48), address_row(*sender), subject_row(subject), mailboxes[mailbox][0],
                  unix_seconds(moment), unix_seconds(moment)]
        if not drift:
            values.append(conversation)
        rowid = conn.execute(f"INSERT INTO messages ({columns}) VALUES ({', '.join('?' * len(values))})", values).lastrowid
        conn.execute("INSERT INTO recipients (message, address, type, position) VALUES (?, ?, 0, 0)", (rowid, address_row(ME["name"], ME["email"])))
        if attachment:
            conn.execute("INSERT INTO attachments (message, name) VALUES (?, ?)", (rowid, attachment))
        if raw_emlx is not None:
            name = f"{rowid}.partial.emlx" if partial else f"{rowid}.emlx"
            (mailboxes[mailbox][1] / name).write_bytes(raw_emlx)
        return rowid

    def headers(message_id: str, sender: Tuple[Optional[str], str], subject: str, moment: Optional[datetime],
                content_type: str = "text/plain; charset=utf-8", encoding: str = "7bit", extra: Optional[List[Tuple[str, str]]] = None):
        name, email = sender
        # Non-ASCII names and subjects are RFC 2047 encoded, as real mail does (folded subjects arrive pre-folded).
        display = Header(name, "utf-8").encode() if name and not name.isascii() else name
        subject_value = Header(subject, "utf-8").encode() if not subject.isascii() else subject
        result = [("From", f"{display} <{email}>" if name else email), ("To", f"{ME['name']} <{ME['email']}>"),
                  ("Subject", subject_value), ("Message-ID", message_id)]
        if moment is not None:
            result.append(("Date", format_datetime(moment.astimezone(BRISBANE))))
        result += [("MIME-Version", "1.0"), ("Content-Type", content_type), ("Content-Transfer-Encoding", encoding)]
        return result + (extra or [])

    conversation_counter = [100]

    def mail(key: str, person: str, subject: str, hours: float, body_raw: bytes, expected_body: str, *,
             content: str = "complete", flags: Optional[List[str]] = None, content_type: str = "text/plain; charset=utf-8",
             encoding: str = "7bit", subject_header: Optional[str] = None, mailbox: str = "INBOX", attachment: Optional[str] = None,
             moment: Optional[datetime] = None, date_header: Optional[datetime] = "same", extra_headers=None,
             time_source: str = "header", expect: bool = True) -> str:
        conversation_counter[0] += 1
        message_id = f"<{key}@example.com>"
        sender = (PEOPLE[person]["name"], PEOPLE[person]["email"]) if person in PEOPLE else (None, person)
        when = moment or at(hours)
        header_date = when if date_header == "same" else date_header
        raw = rfc822(headers(message_id, sender, subject_header or subject, header_date, content_type, encoding, extra_headers), body_raw)
        store(sender=sender, subject=subject, moment=when, raw_emlx=emlx(raw, when), conversation=conversation_counter[0],
              mailbox=mailbox, attachment=attachment)
        if expect:
            events.append(event(source="email", source_record_id=message_id, route="mail_store", app_id=APP,
                                sender=f"{sender[0]} <{sender[1]}>" if sender[0] else sender[1],
                                thread_id=None if drift else str(conversation_counter[0]), title=subject, body=expected_body,
                                content=content, event_time=when, event_time_source=time_source, flags=flags))
        return message_id

    # Ordinary mail.
    invoice_text = "Hi, just a reminder that invoice 1043 ($1,250.00) is due this Friday. Thanks, Jordan"
    mail("invoice-1043", "jordan", "Invoice 1043 due Friday", 20.9, invoice_text.encode(), invoice_text)
    mail("lunch-0001", "jose", "Lunch?", 15.0, "Lunch on Thursday?".encode(), "Lunch on Thursday?")  # NFC "José"

    # Edge case 8: instructions inside an email are data.
    mail("notice-7781", "deals@example.com", "Important system notice", 9.5, INJECTIONS[1].encode(), INJECTIONS[1])

    # Edge case 6: transfer encodings and charsets.
    qp = b"Caf=E9 tomorrow at 9? This line is long enough that it needs a soft line=\n break in the middle."
    mail("charset-qp", "riley", "Coffee", 19.0, qp, "Café tomorrow at 9? This line is long enough that it needs a soft line break in the middle.",
         content_type="text/plain; charset=iso-8859-1", encoding="quoted-printable")
    beach = "See you at the 🏖 beach"
    unpadded = base64.b64encode(beach.encode()).rstrip(b"=")
    mail("charset-b64", "sam", "Beach", 18.5, unpadded, beach, encoding="base64")
    mail("charset-1252", "casey", "Quotes", 18.0, b"She said \x93see you soon\x94 \x96 nice.", "She said “see you soon” – nice.",
         content_type="text/plain; charset=windows-1252")
    meeting = "会议改到明天上午十点"
    mail("charset-gb18030", "casey", "会议", 17.8, meeting.encode("gb18030"), meeting, content_type="text/plain; charset=gb18030",
         encoding="8bit")
    html = b'--alt\nContent-Type: text/html; charset=utf-8\n\n<html><body><p>Your package has shipped.</p></body></html>\n--alt--\n'
    mail("html-only", "deals@example.com", "Shipping update", 16.0, html, "Your package has shipped.",
         content_type='multipart/alternative; boundary="alt"')
    mail("folded-subject", "jordan", "A very long subject line that wraps onto the next line", 15.5, b"Body of the folded one.",
         "Body of the folded one.", subject_header="A very long subject line that\n wraps onto the next line")
    smuggled = "Subject: HACKED\n\nThe real message is here."
    mail("header-smuggling", "riley", "Weekly update", 14.0, smuggled.encode(), smuggled)
    fake_boundary = "--boundary-fake\nStill the same part."
    mail("fake-boundary", "sam", "Boundary", 13.5, fake_boundary.encode(), fake_boundary)

    # Edge case 7: an encrypted body: metadata only, no ciphertext in the body.
    mail("encrypted-0001", "jordan", "Contract", 13.0, base64.b64encode(bytes(range(64))), "", content="unavailable", flags=["encrypted"],
         content_type='application/pkcs7-mime; smime-type=enveloped-data; name="smime.p7m"', encoding="base64")

    # Attachment-only mail (also edge case 3's policy for mail).
    photo = (b'--mixed\nContent-Type: image/jpeg; name="weekend.jpg"\nContent-Transfer-Encoding: base64\n'
             b'Content-Disposition: attachment; filename="weekend.jpg"\n\n' + base64.b64encode(b"\xff\xd8\xff" + bytes(120)) + b"\n--mixed--\n")
    mail("photos-0001", "riley", "Photos from the weekend", 11.0, photo, "", content="unavailable", flags=["attachment_only"],
         content_type='multipart/mixed; boundary="mixed"', attachment="weekend.jpg")

    # Edge case 11: time zones and daylight saving (US Eastern fall-back night), -0000, and a missing Date.
    eastern_edt = datetime(2025, 11, 2, 1, 30, tzinfo=timezone(timedelta(hours=-4)))
    eastern_est = datetime(2025, 11, 2, 1, 30, tzinfo=timezone(timedelta(hours=-5)))
    mail("dst-edt", "casey", "Before the clocks changed", 0, b"01:30 EDT", "01:30 EDT", moment=eastern_edt)
    mail("dst-est", "casey", "After the clocks changed", 0, b"01:30 EST", "01:30 EST", moment=eastern_est)
    utc_unknown = datetime(2026, 10, 6, 3, 0, tzinfo=timezone.utc)
    mail("zone-unknown", "sam", "Zone unknown", 0, b"-0000 means UTC", "-0000 means UTC", moment=utc_unknown,
         date_header=None, extra_headers=[("Date", "Tue, 06 Oct 2026 03:00:00 -0000")])
    received = datetime(2026, 10, 6, 1, 23, 45, tzinfo=timezone.utc)
    mail("no-date", "riley", "No Date header", 0, b"Dated by Received", "Dated by Received", moment=received, date_header=None,
         extra_headers=[("Received", "from mx.example.com by mail.example.com; Tue, 06 Oct 2026 01:23:45 +0000")], time_source="received")

    # Edge case 4: .emlx framing errors (problems, no events), and a missing trailer (fine).
    for key, mangle in (("framing-not-a-number", "count"), ("framing-truncated", "truncate")):
        message_id = f"<{key}@example.com>"
        raw = rfc822(headers(message_id, (PEOPLE["sam"]["name"], PEOPLE["sam"]["email"]), "Broken", at(3)), base64.b64encode(bytes(300)))
        wrapped = emlx(raw, at(3), count="abc") if mangle == "count" else emlx(raw, at(3))[: len(raw) // 2]
        rowid = store(sender=(PEOPLE["sam"]["name"], PEOPLE["sam"]["email"]), subject="Broken", moment=at(3), raw_emlx=wrapped, conversation=1)
        problems.append(problem("emlx_framing_error", "email", str(rowid), mangle))
    message_id = "<no-trailer@example.com>"
    raw = rfc822(headers(message_id, (PEOPLE["alex"]["name"], PEOPLE["alex"]["email"]), "No trailer", at(2.5)), b"Plist trailer missing.")
    store(sender=(PEOPLE["alex"]["name"], PEOPLE["alex"]["email"]), subject="No trailer", moment=at(2.5),
          raw_emlx=emlx(raw, at(2.5), trailer=False), conversation=900)
    events.append(event(source="email", source_record_id=message_id, route="mail_store", app_id=APP,
                        sender=f"{PEOPLE['alex']['name']} <{PEOPLE['alex']['email']}>", thread_id=None if drift else "900",
                        title="No trailer", body="Plist trailer missing.", content="complete", event_time=at(2.5), event_time_source="header"))

    # Edge case 5: a partly downloaded message, and an index row whose file is gone.
    message_id = "<partial-0001@example.com>"
    raw = rfc822(headers(message_id, (PEOPLE["jordan"]["name"], PEOPLE["jordan"]["email"]), "Report attached", at(2)), b"Summary first; the rest is still downloading.")
    store(sender=(PEOPLE["jordan"]["name"], PEOPLE["jordan"]["email"]), subject="Report attached", moment=at(2),
          raw_emlx=emlx(raw, at(2)), conversation=901, partial=True)
    events.append(event(source="email", source_record_id=message_id, route="mail_store", app_id=APP,
                        sender=f"{PEOPLE['jordan']['name']} <{PEOPLE['jordan']['email']}>", thread_id=None if drift else "901",
                        title="Report attached", body="Summary first; the rest is still downloading.", content="preview",
                        flags=["truncated"], event_time=at(2), event_time_source="header"))
    rowid = store(sender=(PEOPLE["riley"]["name"], PEOPLE["riley"]["email"]), subject="File missing", moment=at(1.5), raw_emlx=None, conversation=902)
    problems.append(problem("body_file_missing", "email", str(rowid)))

    # Edge case 14: the same Message-ID in Inbox and Archive yields one event.
    duplicate = mail("dup-0001", "alex", "Saved twice", 1.0, b"Filed in two mailboxes.", "Filed in two mailboxes.")
    raw = rfc822(headers(duplicate, (PEOPLE["alex"]["name"], PEOPLE["alex"]["email"]), "Saved twice", at(1.0)), b"Filed in two mailboxes.")
    rowid = store(sender=(PEOPLE["alex"]["name"], PEOPLE["alex"]["email"]), subject="Saved twice", moment=at(1.0),
                  raw_emlx=emlx(raw, at(1.0)), conversation=conversation_counter[0], mailbox="Archive")
    problems.append(problem("duplicate_message_id", "email", str(rowid), duplicate))

    # Edge case 19 (optional): a huge attachment that must never be decoded into the body.
    if huge:
        big = (b'--mixed\nContent-Type: text/plain; charset=utf-8\n\nHere is the big file.\n--mixed\n'
               b'Content-Type: application/octet-stream; name="big.bin"\nContent-Transfer-Encoding: base64\n\n'
               + base64.encodebytes(bytes(18 * 1024 * 1024)) + b"--mixed--\n")
        mail("huge-0001", "jordan", "Big file", 0.5, big, "Here is the big file.", content_type='multipart/mixed; boundary="mixed"',
             attachment="big.bin")

    conn.commit()
    conn.close()
    return events, problems
