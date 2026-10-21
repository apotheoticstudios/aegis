"""Deterministic cross-route merge; scratch storage scales on disk, not in RAM."""
import hashlib
import json
import sqlite3
import tempfile
import unicodedata
from datetime import datetime

MESSAGES_APPS = {"com.apple.mobilesms", "com.apple.ichat"}  # compared in lower case: real databases store it so


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def normalized(value):
    return unicodedata.normalize("NFC", value or "").casefold()


class Merger:
    """Context-managed synthetic event spool. Feed reader callbacks to add(), then events().

    Unique 1:1 twins need no aliases; known groups and ambiguous candidates stay separate.
    Chat records provide the canonical ID and text.
    """
    def __init__(self, aliases=None, tolerance_seconds=5):
        if tolerance_seconds < 0:
            raise ValueError("negative merge tolerance")
        self.aliases = {normalized(k): normalized(v) for k, v in (aliases or {}).items()}
        self.tolerance = tolerance_seconds
        self.tmp = tempfile.TemporaryDirectory(prefix="aegis-pipeline-")
        self.db = sqlite3.connect(self.tmp.name + "/spool.sqlite")
        self.db.executescript("""
            PRAGMA cache_size=-2048;
            PRAGMA temp_store=FILE;
            CREATE TABLE events(id TEXT PRIMARY KEY, source TEXT, bodyhash TEXT, time REAL, payload TEXT);
            CREATE INDEX twins ON events(source, bodyhash, time);
            CREATE TABLE observations(id TEXT, route TEXT, record TEXT, captured TEXT,
                PRIMARY KEY(id,route,record,captured));
            CREATE TABLE links(note TEXT PRIMARY KEY, chat TEXT);
            CREATE INDEX links_chat ON links(chat);
            CREATE TABLE groups(name TEXT PRIMARY KEY);
        """)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.db.close()
        self.tmp.cleanup()

    def add(self, event):
        """Spool one contract event, preserving every distinct observation and latest revision."""
        payload = {k: v for k, v in event.items() if k != "observations"}
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=True)
        old = self.db.execute("SELECT payload FROM events WHERE id=?", (event["id"],)).fetchone()
        # Capture time orders revisions; lexical tie break makes arbitrary arrival order stable.
        if old is None or (event["capture_time"], encoded) > (json.loads(old[0])["capture_time"], old[0]):
            digest = hashlib.sha256(event["body"].encode("utf-8")).hexdigest()
            self.db.execute("INSERT OR REPLACE INTO events VALUES(?,?,?,?,?)",
                            (event["id"], event["source"], digest, timestamp(event["event_time"]), encoded))
        group = self._group_name(event)
        if group:
            self.db.execute("INSERT OR IGNORE INTO groups VALUES(?)", (group,))
        self.db.executemany("INSERT OR IGNORE INTO observations VALUES(?,?,?,?)",
                            ((event["id"], o["route"], o["source_record_id"], o["capture_time"])
                             for o in event["observations"]))

    def _identity(self, value):
        value = normalized(value)
        value = self.aliases.get(value, value)
        if value and all(c.isdigit() or c in "+ ()-." for c in value):
            return "".join(c for c in value if c.isdigit())
        return value

    def _group_name(self, event):
        if event["source"] not in ("imessage", "sms") or not event["title"]:
            return None
        thread = event["thread_id"] or ""
        if ";-;" in thread or self._identity(event["title"]) == self._identity(event["sender"]):
            return None
        # A title filled from a prior notification isn't evidence of a group name.
        if ";+;" in thread or not any(o["route"] in ("notification_db", "accessibility") for o in event.get("observations", [])):
            return normalized(event["title"])
        return None

    def _matches(self, note, chat):
        if (note["app_id"] or "").lower() not in MESSAGES_APPS or (chat["app_id"] or "").lower() not in MESSAGES_APPS:
            return False
        if not note["body"] or note["body"] != chat["body"] or chat["sender"] == "me":
            return False
        if note["thread_id"]:
            return note["thread_id"] == chat["thread_id"]
        title = normalized(note["title"])
        group = self._group_name(chat)
        if group:
            return title == group
        if self.db.execute("SELECT 1 FROM groups WHERE name=?", (title,)).fetchone():
            return False  # a group notification must not fall back to a 1:1 chat
        # Aliases and formatted-phone equality confirm identity, but aren't required.
        return True

    def events(self):
        """Yield canonical events oldest first; repeat calls and re-ingestion are idempotent."""
        self.db.execute("DELETE FROM links")
        for nid, digest, moment, raw in self.db.execute(
                "SELECT id,bodyhash,time,payload FROM events WHERE source='notification' ORDER BY id"):
            note, candidates = json.loads(raw), []
            for cid, data in self.db.execute(
                    "SELECT id,payload FROM events WHERE source IN ('imessage','sms') AND bodyhash=? AND time BETWEEN ? AND ? ORDER BY id",
                    (digest, moment - self.tolerance, moment + self.tolerance)):
                chat = json.loads(data)
                chat["observations"] = [{"route": r} for (r,) in self.db.execute(
                    "SELECT DISTINCT route FROM observations WHERE id=?", (cid,))]
                if self._matches(note, chat):
                    candidates.append(cid)
                    if len(candidates) == 2:
                        break
            if len(candidates) == 1:
                self.db.execute("INSERT INTO links VALUES(?,?)", (nid, candidates[0]))
        for eid, raw in self.db.execute(
                "SELECT id,payload FROM events WHERE id NOT IN (SELECT note FROM links) ORDER BY time,id"):
            event = json.loads(raw)
            event["observations"] = [dict(route=r, source_record_id=s, capture_time=t) for r, s, t in self.db.execute(
                "SELECT DISTINCT route,record,captured FROM observations WHERE id=? OR id IN (SELECT note FROM links WHERE chat=?) ORDER BY route,record,captured",
                (eid, eid))]
            if event["source"] in ("imessage", "sms") and not event["title"]:
                title = self.db.execute("SELECT payload FROM events WHERE id IN (SELECT note FROM links WHERE chat=?) ORDER BY id LIMIT 1", (eid,)).fetchone()
                if title:
                    event["title"] = json.loads(title[0])["title"]
            yield event


def merge_events(events, **kwargs):
    """Streaming convenience API; close the iterator early to release scratch storage."""
    with Merger(**kwargs) as merger:
        for event in events:
            merger.add(event)
        yield from merger.events()
