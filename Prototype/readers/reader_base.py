"""Shared pieces for the Stage 0 readers (issue #15): read-only SQLite access, source status, timestamps.

Readers turn a store into contract events (`Prototype/contracts`) plus problems (errors and skips, codes
from #6). They never write to a store and never log message text. Only the owner runs them on real data
(#19); tests use `Fixtures/generate`.
"""

from __future__ import annotations

import shutil
import sqlite3
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Dict, Iterator, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Prototype" / "contracts"))
import aegis_contracts  # noqa: E402

COCOA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
LATEST_PLAUSIBLE = datetime(2100, 1, 1, tzinfo=timezone.utc)
CLOCK_SKEW_ALLOWANCE = timedelta(minutes=10)
COPY_ATTEMPTS = 3

Item = Tuple[str, Dict]  # ("event", event) or ("problem", problem)
Reader = Callable[[sqlite3.Connection, datetime, Optional[datetime]], Iterator[Item]]

# Status codes. `ok` is False when someone has to do something (grant access, retry, investigate).
OK, NO_DATA = "ok", "no_data"  # events read / readable store with nothing (in the window)
NOT_FOUND, PERMISSION_DENIED = "not_found", "permission_denied"  # no store at the path / no access (Full Disk Access)
BUSY, UNREADABLE = "busy", "unreadable"  # locked or changing too fast; try again / not SQLite, or damaged


class UnknownSchemaError(Exception):
    """The store doesn't have the tables and columns this reader understands."""

    def __init__(self, table: str, found: List[str]):
        super().__init__(f"unknown schema: table {table!r} has columns {found}")
        self.table = table
        self.found = found


class StoreUnavailable(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass
class SourceStatus:
    ok: bool
    code: str
    count: int = 0  # events
    problems: int = 0


@dataclass
class ReadResult:
    status: SourceStatus
    events: List[Dict] = field(default_factory=list)
    problems: List[Dict] = field(default_factory=list)


def problem(code: str, source: str, record: str, note: str = "") -> Dict:
    return {"code": code, "source": source, "record": record, "note": note}


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def number(value) -> Optional[float]:
    """A stored time as a float; None for NULL or anything that isn't a number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def cocoa(seconds: float) -> Optional[datetime]:
    """Seconds since 2001-01-01 to a UTC time, or None if outside 2001–2100."""
    if seconds < 0:
        return None
    try:
        moment = COCOA_EPOCH + timedelta(seconds=seconds)
    except OverflowError:
        return None
    return moment if moment < LATEST_PLAUSIBLE else None


def cocoa_seconds(moment: datetime) -> float:
    return (moment - COCOA_EPOCH).total_seconds()


def skew_flags(moment: datetime, now: datetime) -> List[str]:
    """Times well ahead of capture (a device clock off) are kept and flagged."""
    return ["clock_skew"] if moment > now + CLOCK_SKEW_ALLOWANCE else []


def make_event(**fields) -> Dict:
    """A contract event (schema 0.1) with one observation from this reader's route."""
    source, record, captured = fields["source"], fields["source_record_id"], fields["capture_time"]
    return {
        "schema_version": "0.1",
        "id": aegis_contracts.event_id(source, record),
        "source": source,
        "source_record_id": record,
        "app_id": fields.get("app_id"),
        "sender": fields.get("sender"),
        "thread_id": fields.get("thread_id"),
        "event_time": iso(fields["event_time"]),
        "event_time_source": fields["event_time_source"],
        "capture_time": captured,
        "title": fields.get("title"),
        "body": fields["body"],
        "content": fields["content"],
        "flags": fields.get("flags", []),
        "observations": [{"route": fields["route"], "source_record_id": record, "capture_time": captured}],
    }


def columns(conn: sqlite3.Connection, table: str) -> List[str]:
    return [row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')]


def require(conn: sqlite3.Connection, table: str, needed: List[str]) -> List[str]:
    found = columns(conn, table)
    if not set(needed) <= set(found):
        raise UnknownSchemaError(table, found)
    return found


def _uses_wal(path: Path) -> bool:
    with open(path, "rb") as f:
        header = f.read(20)
    return len(header) == 20 and 2 in (header[18], header[19])


def _stamp(path: Path) -> Optional[Tuple[int, int]]:
    try:
        info = path.stat()
    except FileNotFoundError:
        return None
    return info.st_size, info.st_mtime_ns


def _private_copy(path: Path, folder: str) -> Path:
    """Copies the database together with its write-ahead log (committed changes may still be only there),
    retrying while either file changes during the copy."""
    copy, wal, wal_copy = Path(folder) / path.name, Path(str(path) + "-wal"), Path(folder) / (path.name + "-wal")
    for _ in range(COPY_ATTEMPTS):
        before = (_stamp(path), _stamp(wal))
        if before[0] is None:
            raise FileNotFoundError(str(path))
        shutil.copyfile(path, copy)
        if before[1] is not None:
            shutil.copyfile(wal, wal_copy)
        elif wal_copy.exists():
            wal_copy.unlink()  # left over from an earlier attempt
        if (_stamp(path), _stamp(wal)) == before:
            return copy
    raise sqlite3.OperationalError("database is busy: it kept changing while being copied")


@contextmanager
def open_readonly(path: Path, busy_timeout: float = 5.0) -> Iterator[sqlite3.Connection]:
    """A read-only connection that never creates or changes files next to the store.

    `mode=ro` (never `immutable=1`, which would ignore the write-ahead log). A WAL database whose -wal/-shm
    files are absent would make SQLite create them, so that case reads a private copy of the database and
    its log instead.
    Raises StoreUnavailable("not_found" or "permission_denied") when the store can't be opened.
    """
    path = Path(path)
    try:
        uses_wal = _uses_wal(path)  # also surfaces a missing file or no access before SQLite does
        sidecars = all(Path(str(path) + suffix).exists() for suffix in ("-wal", "-shm"))
    except FileNotFoundError:
        raise StoreUnavailable(NOT_FOUND) from None
    except PermissionError:
        raise StoreUnavailable(PERMISSION_DENIED) from None
    with tempfile.TemporaryDirectory(prefix="aegis-reader-") as tmp:
        try:
            if uses_wal and not sidecars:
                conn = sqlite3.connect(str(_private_copy(path, tmp)), timeout=busy_timeout)
            else:
                conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=busy_timeout)
        except FileNotFoundError:
            raise StoreUnavailable(NOT_FOUND) from None
        except PermissionError:
            raise StoreUnavailable(PERMISSION_DENIED) from None
        except sqlite3.OperationalError as error:
            if "unable to open" in str(error):
                raise StoreUnavailable(PERMISSION_DENIED) from None
            raise
        try:
            conn.execute("PRAGMA query_only = ON")
            yield conn
        finally:
            conn.close()


def is_locked(error: sqlite3.OperationalError) -> bool:
    return "locked" in str(error) or "busy" in str(error)


def scan(
    path,
    reader: Reader,
    now: Optional[datetime] = None,
    since: Optional[datetime] = None,
    busy_timeout: float = 5.0,
    on_item: Optional[Callable[[str, Dict], None]] = None,
) -> ReadResult:
    """Runs a reader over one store and turns failures into a status (UnknownSchemaError is raised).

    Events and problems are kept in the result, or, with `on_item`, handed over one at a time and not
    kept, so memory stays flat however big the store is. `since` limits events to that time onwards.
    """
    now = now or datetime.now(timezone.utc)
    result = ReadResult(status=SourceStatus(ok=True, code=OK))
    status = result.status
    try:
        with open_readonly(Path(path), busy_timeout) as conn:
            for kind, item in reader(conn, now, since):
                if kind == "event":
                    status.count += 1
                else:
                    status.problems += 1
                if on_item is not None:
                    on_item(kind, item)
                else:
                    (result.events if kind == "event" else result.problems).append(item)
    except StoreUnavailable as error:
        status.ok, status.code = False, error.code
    except sqlite3.OperationalError as error:
        if is_locked(error):
            status.ok, status.code = False, BUSY
        elif "unable to open" in str(error):
            status.ok, status.code = False, PERMISSION_DENIED
        else:
            raise
    except sqlite3.DatabaseError:  # "file is not a database", "database disk image is malformed"
        status.ok, status.code = False, UNREADABLE
    if status.ok and status.count == 0:
        status.code = NO_DATA
    return result
