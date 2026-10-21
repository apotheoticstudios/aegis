"""Read-only Mail Envelope Index + emlx reader; collected content is inert data."""
from __future__ import annotations

import os
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from email import policy
from email.header import decode_header, make_header
from email.parser import BytesHeaderParser, BytesParser
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from pathlib import Path

from reader_base import (COCOA_EPOCH, LATEST_PLAUSIBLE, PERMISSION_DENIED,
                         ReadResult, SourceStatus, StoreUnavailable, iso,
                         make_event, problem, require, scan, skew_flags)


class _FramingError(ValueError):
    pass


class _HTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text = []
        self.hidden = []

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.hidden.clear()  # a missing </head> or </title> must not hide the whole message
        elif tag in ("style", "script", "head", "title"):
            self.hidden.append(tag)

    def handle_endtag(self, tag):
        if tag in self.hidden:
            del self.hidden[self.hidden.index(tag):]

    def handle_startendtag(self, tag, attrs):
        pass

    def handle_data(self, data):
        if not self.hidden:
            self.text.append(data)


def _parts(lines, boundary):
    """Yield child iterators, draining each before advancing; never retain attachments."""
    opening, closing = b"--" + boundary, b"--" + boundary + b"--"
    marker = None

    def child():
        nonlocal marker
        for line in lines:
            marker = line.rstrip(b"\r\n \t")
            if marker in (opening, closing):
                return
            yield line
        marker = closing

    for line in lines:
        if line.rstrip(b"\r\n \t") == opening:
            break
    else:
        return
    while True:
        part = child()
        yield part
        for _ in part:
            pass
        if marker == closing:
            break
    for _ in lines:  # epilogue
        pass


def _mime(lines, nested=False):
    header = bytearray()
    for line in lines:
        header.extend(line)
        if line in (b"\n", b"\r\n"):
            break
    msg = BytesHeaderParser(policy=policy.default).parsebytes(bytes(header))
    kind = msg.get_content_type()
    encrypted = kind in ("application/pkcs7-mime", "application/x-pkcs7-mime", "multipart/encrypted")
    texts = []
    boundary = msg.get_boundary()
    if encrypted or msg.get_content_disposition() == "attachment":
        for _ in lines:
            pass
    elif msg.get_content_maintype() == "multipart" and boundary:
        for child in _parts(lines, boundary.encode("ascii", errors="replace")):
            _, found, secret = _mime(child, nested=True)
            texts.extend(found)
            encrypted |= secret
    elif kind in ("text/plain", "text/html"):
        raw = b"".join(lines)
        if nested:  # separator newline belongs to the MIME delimiter
            raw = raw[:-2] if raw.endswith(b"\r\n") else raw[:-1] if raw.endswith(b"\n") else raw
        leaf = BytesParser(policy=policy.default).parsebytes(bytes(header) + raw)
        payload = leaf.get_payload(decode=True)
        try:
            text = payload.decode(leaf.get_content_charset() or "utf-8", errors="replace")
        except LookupError:
            text = payload.decode("utf-8", errors="replace")
        if kind == "text/html":
            html = _HTML()
            html.feed(text)
            text = " ".join(" ".join(html.text).split())
        texts.append((kind, text))
    else:
        for _ in lines:
            pass
    return msg, texts, encrypted


def _emlx(path):
    with path.open("rb") as f:
        count = f.readline(64)
        if not count.endswith(b"\n") or not count.strip().isdigit():
            raise _FramingError("count")
        remaining = int(count)
        if remaining > os.fstat(f.fileno()).st_size - f.tell():
            raise _FramingError("truncate")

        def lines():
            nonlocal remaining
            while remaining:
                line = f.readline(min(remaining, 65536))
                if not line:
                    raise _FramingError("truncate")
                remaining -= len(line)
                yield line

        return _mime(iter(lines()))


def _walk_files(folder):
    """One streaming tree walk; a concurrently removed directory is harmless."""
    try:
        with os.scandir(folder) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    yield from _walk_files(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    yield Path(entry.path)
    except FileNotFoundError:
        return


def _index_files(folder, pending):
    for path in _walk_files(folder):
        name = path.name
        partial = name.endswith(".partial.emlx")
        stem = name[:-13] if partial else name[:-5] if name.endswith(".emlx") else ""
        if stem.isascii() and stem.isdecimal():
            # Keep only selected rowids. Prefer a complete file over a partial one.
            pending.execute("UPDATE pending SET path=?, partial=? WHERE rowid=? "
                            "AND (path IS NULL OR partial>?)",
                            (str(path), int(partial), stem, int(partial)))


def _raw_header(msg, name):
    """The header's raw text, unfolded, with RFC 2047 words decoded where possible."""
    for key, value in msg.raw_items():
        if key.lower() == name.lower():
            text = " ".join(str(value).split()).encode("utf-8", "surrogateescape").decode("utf-8", "replace")
            try:
                return str(make_header(decode_header(text)))
            except Exception:
                return text
    return None


def _header(msg, name):
    """A header's text. Defects never drop a message (real mail is full of minor ones, e.g. an
    unquoted "J. Sample" display name); when Python can't parse a header at all (3.9 raises for
    some), the raw text stands in."""
    try:
        value = msg.get(name)
    except Exception:
        return _raw_header(msg, name)
    return None if value is None else str(value)


def _moment(text):
    try:
        moment = parsedate_to_datetime(text)
    except (ValueError, TypeError, OverflowError, IndexError):
        return None
    return (moment.replace(tzinfo=timezone.utc) if moment.tzinfo is None else moment).astimezone(timezone.utc)


def _message(path, rowid, thread, received_at, now, since, seen):
    msg, texts, encrypted = _emlx(path)
    record = _header(msg, "Message-ID")
    sender, title = _header(msg, "From"), _header(msg, "Subject")
    if not record:
        return "problem", problem("missing_message_id", "email", str(rowid))
    # Time: the Date header; else the newest Received hop; else when Mail received it (index).
    date = _header(msg, "Date")
    moment, source = (_moment(date), "header") if date else (None, "received")
    if moment is None:
        received = _header(msg, "Received")
        moment, source = _moment(received.rsplit(";", 1)[-1].strip() if received else None), "received"
    if moment is None and received_at is not None:
        moment, source = received_at, "received"
    if moment is None:
        return "problem", problem("missing_timestamp", "email", str(rowid))
    if not COCOA_EPOCH <= moment < LATEST_PLAUSIBLE:
        return "problem", problem("timestamp_out_of_range", "email", str(rowid))
    if since is not None and moment < since:
        return None
    plain = [text for kind, text in texts if kind == "text/plain"]
    body = (plain or [text for _, text in texts] or [""])[0]
    content, flags = "complete", []
    if encrypted:
        body, content, flags = "", "unavailable", ["encrypted"]
    elif not texts:
        content, flags = "unavailable", ["attachment_only"]
    if path.name.endswith(".partial.emlx"):
        content = "preview" if body else "unavailable"
        flags.append("truncated")
    event = make_event(source="email", source_record_id=record, route="mail_store",
        app_id="com.apple.mail", sender=sender, title=title,
        thread_id=str(thread) if thread is not None else None, body=body, content=content,
        flags=flags + skew_flags(moment, now), event_time=moment, event_time_source=source, capture_time=iso(now))
    if not seen.execute("INSERT OR IGNORE INTO ids VALUES (?)", (record,)).rowcount:
        return "problem", problem("duplicate_message_id", "email", str(rowid), record)
    return "event", event


def _epoch_offset(conn):
    """Index dates are Unix seconds on modern macOS, seconds since 2001 on older builds (any post-2001
    Unix value is above 1e9)."""
    (latest,) = conn.execute("SELECT MAX(date_received) FROM messages").fetchone()
    return 0.0 if not latest or latest > 1e9 else COCOA_EPOCH.timestamp()


def _index_time(value, offset):
    try:
        return datetime.fromtimestamp(float(value) + offset, timezone.utc) if value else None
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def iter_mail(conn, now, since, folder):
    found = require(conn, "messages", ["date_received"])
    conversation = "conversation_id" if "conversation_id" in found else "NULL"
    # Some macOS releases keep "deleted" as bit 1 of `flags` instead of a column.
    keep = ("COALESCE(deleted, 0) != 1" if "deleted" in found
            else "(COALESCE(flags, 0) & 2) = 0" if "flags" in found else "1 = 1")
    offset = _epoch_offset(conn)
    query = f"SELECT ROWID, {conversation}, date_received FROM messages WHERE {keep}"
    params = ()
    if since is not None:
        query += " AND date_received >= ?"
        params = ((since - timedelta(days=1)).timestamp() - offset,)
    # Stage selected rows and file paths on disk: one tree walk, bounded RAM.
    with tempfile.TemporaryDirectory(prefix="aegis-mail-index-") as tmp:
        with sqlite3.connect(str(Path(tmp) / "index")) as seen:
            seen.execute("CREATE TABLE ids (id TEXT PRIMARY KEY)")
            seen.execute("CREATE TABLE pending (rowid INTEGER PRIMARY KEY, thread, received, path TEXT, partial INTEGER)")
            seen.executemany("INSERT INTO pending (rowid, thread, received) VALUES (?, ?, ?)", conn.execute(query, params))
            if seen.execute("SELECT 1 FROM pending LIMIT 1").fetchone() is None:
                return
            _index_files(folder, seen)
            for rowid, thread, received, filename in seen.execute("SELECT rowid, thread, received, path FROM pending ORDER BY rowid"):
                if filename is None:
                    yield "problem", problem("body_file_missing", "email", str(rowid))
                    continue
                try:
                    item = _message(Path(filename), rowid, thread, _index_time(received, offset), now, since, seen)
                except FileNotFoundError:
                    item = "problem", problem("body_file_missing", "email", str(rowid))
                except _FramingError as error:
                    item = "problem", problem("emlx_framing_error", "email", str(rowid), str(error))
                except (OSError, sqlite3.Error):
                    raise  # Preserve access/SQLite failures as source statuses, not parse errors.
                except Exception:
                    item = "problem", problem("message_parse_error", "email", str(rowid))
                if item is not None:
                    yield item


def read_mail(path, now=None, since=None, busy_timeout=5.0, on_item=None) -> ReadResult:
    """Accept an Envelope Index, version directory, or Mail root. Stream via on_item."""
    path = Path(path)
    try:
        if path.is_dir():
            if (path / "MailData").is_dir():
                path = path / "MailData" / "Envelope Index"
            else:
                with os.scandir(path) as entries:
                    versions = [entry.name for entry in entries if entry.name.startswith("V") and entry.name[1:].isdigit()]
                version = max(versions, key=lambda name: int(name[1:]), default="V0")
                path = path / version / "MailData" / "Envelope Index"
        folder = path.parent.parent

        def reader(conn, captured, cutoff):
            try:
                yield from iter_mail(conn, captured, cutoff, folder)
            except PermissionError:
                raise StoreUnavailable(PERMISSION_DENIED) from None

        return scan(path, reader, now, since, busy_timeout, on_item)
    except PermissionError:
        return ReadResult(SourceStatus(False, PERMISSION_DENIED))
