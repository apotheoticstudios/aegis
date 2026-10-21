"""Notification Center database → contract events (Stage 0, issue #15).

Rules (they match `Fixtures/generate`'s expected output):
- One event per delivered record. The id is the record's `uuid` as an upper-case UUID string; the app is
  the `app` row's identifier (null when the row is missing); sender and thread are null.
- title is `req.titl` (null when it isn't a string); body is `req.body`; content is `preview`, or `redacted`
  when the body is empty (previews hidden).
- The time is `delivered_date` (seconds since 2001). Times more than 10 minutes ahead are kept and flagged
  `clock_skew`; times before 2001 or after 2100 are problems.
- Problems instead of events: an unreadable payload, no usable time, no uuid. A record requested but not
  delivered yet is skipped (`not_delivered`) and read on a later run.
"""

from __future__ import annotations

import plistlib
import sqlite3
import uuid
from datetime import datetime
from typing import Iterator, Optional

from reader_base import Item, ReadResult, cocoa, cocoa_seconds, iso, make_event, number, problem, require, scan, skew_flags

SOURCE = "notification"


def _uuid_string(raw) -> Optional[str]:
    if isinstance(raw, (bytes, bytearray)) and len(raw) == 16:
        return str(uuid.UUID(bytes=bytes(raw))).upper()
    return None


def iter_notifications(conn: sqlite3.Connection, now: datetime, since: Optional[datetime] = None) -> Iterator[Item]:
    """Yields ("event", event) and ("problem", problem) one record at a time."""
    require(conn, "app", ["app_id", "identifier"])
    require(conn, "record", ["app_id", "uuid", "data", "delivered_date", "request_date"])
    query = (
        "SELECT r.rowid, r.uuid, a.identifier, r.data, r.delivered_date, r.request_date "
        "FROM record r LEFT JOIN app a ON a.app_id = r.app_id"
    )
    params = ()
    if since is not None:
        query, params = query + " WHERE r.delivered_date >= ?", (cocoa_seconds(since),)
    captured = iso(now)
    for rowid, raw_uuid, identifier, data, delivered, requested in conn.execute(query + " ORDER BY r.rowid", params):
        record = _uuid_string(raw_uuid)
        if record is None:
            yield "problem", problem("missing_uuid", SOURCE, "(null)", f"record rowid {rowid}")
            continue
        try:
            payload = plistlib.loads(data)
            if not isinstance(payload, dict):
                raise ValueError("payload is not a dictionary")
        except Exception:
            yield "problem", problem("bplist_parse_error", SOURCE, record)
            continue
        delivered = number(delivered)
        if not delivered:  # NULL, or 0 (which means 2001-01-01, not a real time)
            requested = number(requested)
            if requested and cocoa(requested) is not None:
                yield "problem", problem("not_delivered", SOURCE, record, "requested, not delivered yet")
            else:
                yield "problem", problem("missing_timestamp", SOURCE, record)
            continue
        moment = cocoa(delivered)
        if moment is None:
            yield "problem", problem("timestamp_out_of_range", SOURCE, record)
            continue
        request = payload.get("req") if isinstance(payload.get("req"), dict) else {}
        title = request.get("titl")
        body = request.get("body") if isinstance(request.get("body"), str) else ""
        yield "event", make_event(
            source=SOURCE,
            source_record_id=record,
            route="notification_db",
            app_id=identifier,
            title=title if isinstance(title, str) else None,
            body=body,
            content="preview" if body else "redacted",
            event_time=moment,
            event_time_source="delivered",
            capture_time=captured,
            flags=skew_flags(moment, now),
        )


def read_notifications(path, now=None, since=None, busy_timeout: float = 5.0, on_item=None) -> ReadResult:
    """Reads a Notification Center database (`db2/db`). See `reader_base.scan` for statuses and streaming."""
    return scan(path, iter_notifications, now, since, busy_timeout, on_item)
