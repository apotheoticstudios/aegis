"""Synthetic macOS Notification Center database (Stage 0, issue #14).

Layout (hypothetical until the owner's `schema` output on #4 confirms it), per the research on #5:
`app(app_id, identifier)`, `record(rec_id, app_id, uuid, data, request_date, request_last_date,
delivered_date, presented, style, snooze_fire_date)`, `dbinfo(key, value)`; `record.data` is a binary
plist with `app` and `req` {titl, subt, body, iden}; times are seconds since 2001-01-01; WAL mode.
"""

from __future__ import annotations

import plistlib
import sqlite3
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from common import INJECTIONS, PEOPLE, Rng, at, cocoa_seconds, event, problem

SCHEMA = """
CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL,
  request_last_date REAL, delivered_date REAL, presented Bool, style INTEGER, snooze_fire_date REAL);
CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
"""

# Shared with messages.py so the cross-route duplicates line up.
ALEX_CALL_TEXT = "Can you call me when you're free? It's about Saturday."
ALEX_CALL_HOURS = 13.8
FAMILY_TEXT = "Who's bringing dessert on Sunday?"
FAMILY_HOURS = 12.4


def _payload(app: Optional[str], title, body: Optional[str], subtitle: str = "", iden: str = "") -> bytes:
    request = {"titl": title, "subt": subtitle, "body": body if body is not None else "", "iden": iden}
    return plistlib.dumps({"app": app or "", "req": request}, fmt=plistlib.FMT_BINARY, sort_keys=True)


def build(folder: Path, rng: Rng, empty: bool = False) -> Tuple[List[Dict], List[Dict], List[Dict]]:
    """Creates `folder/db`. Returns (expected events, expected problems, cross-route duplicate hints)."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "db"
    conn = sqlite3.connect(str(path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    conn.executemany("INSERT INTO dbinfo VALUES (?, ?)", [("compatibleVersion", "33"), ("dbVersion", "33")])
    events: List[Dict] = []
    problems: List[Dict] = []
    duplicates: List[Dict] = []
    if empty:
        conn.commit()
        _close(conn)
        return events, problems, duplicates

    apps: Dict[str, int] = {}

    def app_id(identifier: Optional[str]) -> Optional[int]:
        if identifier is None:
            return None
        if identifier not in apps:
            apps[identifier] = conn.execute("INSERT INTO app (identifier) VALUES (?)", (identifier,)).lastrowid
        return apps[identifier]

    def add(
        identifier: Optional[str],
        *,
        title,
        body: Optional[str],
        delivered: Optional[float],
        requested: Optional[float],
        data: Optional[bytes] = None,
        plist_app: Optional[str] = None,
    ) -> str:
        record_uuid = rng.uuid()
        payload = data if data is not None else _payload(plist_app or identifier, title, body, iden=rng.uuid())
        conn.execute(
            "INSERT INTO record (app_id, uuid, data, request_date, request_last_date, delivered_date, presented, style) "
            "VALUES (?, ?, ?, ?, ?, ?, 1, 1)",
            (app_id(identifier), bytes.fromhex(record_uuid.replace("-", "")), payload, requested, requested, delivered),
        )
        return record_uuid

    def normal(identifier: Optional[str], title, body: str, hours: float, flags: Optional[List[str]] = None) -> str:
        moment = at(hours)
        record = add(identifier, title=title, body=body, delivered=cocoa_seconds(moment), requested=cocoa_seconds(moment))
        events.append(
            event(
                source="notification",
                source_record_id=record,
                route="notification_db",
                app_id=identifier,
                title=title if isinstance(title, str) else None,
                body=body,
                content="preview" if body else "redacted",
                event_time=moment,
                event_time_source="delivered",
                flags=flags,
            )
        )
        return record

    # Ordinary notifications.
    alex = normal("com.apple.MobileSMS", PEOPLE["alex"]["name"], ALEX_CALL_TEXT, ALEX_CALL_HOURS)
    duplicates.append({"notification": alex, "matches": "message:alex-call", "rule": "same text, handle and time"})
    normal("com.example.bank", "Example Bank", "Card payment of $42.10 at Example Cafe", 19.5)
    normal("com.example.chat", PEOPLE["sam"]["name"], "", 17.25)  # previews hidden: redacted
    normal("com.example.delivery", "Example Eats", "Your order is 5 minutes away", 12.1)  # iPhone-only app (mirrored)
    family = normal("com.apple.MobileSMS", "Family", FAMILY_TEXT, FAMILY_HOURS - 1 / 3600)
    duplicates.append({"notification": family, "matches": "message:family-dessert", "rule": "same text and chat, 1 s apart"})

    # Edge case 8: instructions inside collected text are data.
    normal("com.example.promo", "Aegis", INJECTIONS[2], 8.75)

    # Edge case 9: Unicode — NFD sender name, ZWJ emoji and flags, bidi override and zero-width characters.
    normal("com.example.chat", unicodedata.normalize("NFD", PEOPLE["jose"]["name"]), "👨‍👩‍👧‍👦 🇬🇧 👍🏽", 7.5)
    normal("com.example.chat", "safe‮txet desrever", "\u0000​hidden characters", 7.2)

    # Edge case 2: no app row, a title that is an array, an empty body from a known app.
    normal(None, "Orphan app", "A notification whose app row is missing", 6.0)
    record = add("com.example.news", title=["Breaking", "news"], body="Arrays where strings belong", delivered=cocoa_seconds(at(5.5)), requested=cocoa_seconds(at(5.5)))
    events.append(
        event(
            source="notification",
            source_record_id=record,
            route="notification_db",
            app_id="com.example.news",
            title=None,  # an array where the title belongs: unknown, so null
            body="Arrays where strings belong",
            content="preview",
            event_time=at(5.5),
            event_time_source="delivered",
        )
    )

    # Edge case 12: a future time (device clock skew) is kept and flagged.
    normal("com.example.weather", "Example Weather", "Storm warning for your area this afternoon", -72, flags=["clock_skew"])

    # Edge case 1: a corrupt plist blob is skipped and reported; the scan carries on.
    record = add("com.example.bank", title=None, body=None, delivered=cocoa_seconds(at(4)), requested=cocoa_seconds(at(4)), data=b"bplist00\x00\x01garbage")
    problems.append(problem("bplist_parse_error", "notification", record))

    # Edge case 2: no usable timestamp (both NULL, or the 2001-01-01 sentinel).
    record = add("com.example.chat", title="No time", body="Missing timestamps", delivered=None, requested=None)
    problems.append(problem("missing_timestamp", "notification", record, "delivered_date and request_date are NULL"))
    record = add("com.example.chat", title="Zero time", body="Sentinel timestamp", delivered=0.0, requested=0.0)
    problems.append(problem("missing_timestamp", "notification", record, "0 means 2001-01-01, not a real time"))

    # Edge case 12: a negative time (before 2001) is rejected.
    record = add("com.example.chat", title="Old", body="Negative timestamp", delivered=-1000.0, requested=-1000.0)
    problems.append(problem("timestamp_out_of_range", "notification", record))

    conn.commit()
    _close(conn)
    return events, problems, duplicates


def _close(conn: sqlite3.Connection) -> None:
    """Checkpoint so the main file holds everything (deterministic bytes), keeping WAL mode in the header."""
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()

