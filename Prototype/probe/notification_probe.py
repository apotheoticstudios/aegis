#!/usr/bin/env python3
"""Notification probe (Stage 0, issue #3).

Answers one question on the owner's own Mac: are notifications, including iPhone
notifications shown through iPhone Mirroring, recorded in the macOS Notification Center
database? Under which app identifier, and how long do they stay there?

Safety:
- Metadata only. It reads app identifiers, record ids and timestamps. It never selects the
  column that holds titles and bodies, so nothing it prints contains message content.
- Read-only. It opens the database in SQLite's read-only mode and never writes to it.
- Local only. Python standard library, no network.

Only the owner runs this against the real database (Terminal needs Full Disk Access).
Agents and tests use a synthetic database. See README.md in this folder.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterator, List, Optional, Tuple

COCOA_EPOCH = 978307200  # seconds from 1970-01-01 to 2001-01-01, Apple's reference date

# The only columns this probe ever reads. Notification text lives in other columns
# (such as `data`), which are deliberately absent.
SAFE_COLUMNS = {"rec_id", "rowid", "uuid", "app_id", "identifier", "delivered_date", "request_date", "presented"}

COPY_ATTEMPTS = 10  # tries at a consistent private copy when the live file can't be opened read-only

FDA_HELP = """macOS blocked access to the notification database.
Give Terminal Full Disk Access:
  System Settings > Privacy & Security > Full Disk Access > turn on Terminal
  (use + to add it from Applications > Utilities if it isn't listed).
Then quit Terminal completely (Cmd-Q), reopen it and run this again."""


class ProbeError(Exception):
    """A problem the owner can fix. Printed without a traceback."""


@dataclass
class Note:
    """One notification record, metadata only."""

    rec_id: int
    app: str
    when: Optional[float]  # Unix seconds
    presented: Optional[bool]
    token: str = ""  # tells apart two records that reuse the same row id (the record's uuid when there is one)


@dataclass
class WatchState:
    """What the database held at the last check. Row ids can be reused after a deletion
    (SQLite hands out max(id) + 1 again), so records are compared by (id, token), not by "id > last"."""

    present: dict  # rec_id -> Note, as of the last check
    arrived: dict = field(default_factory=dict)  # (rec_id, token) -> time first seen, for records new while watching
    new: List[Note] = field(default_factory=list)  # reported once delivered
    stays: List[float] = field(default_factory=list)  # seconds a record stayed before removal
    pending: set = field(default_factory=set)  # (rec_id, token) seen as requests, not yet delivered
    removed_undelivered: int = 0  # requests that disappeared before they were ever delivered


# ---------------------------------------------------------------- finding and opening


def candidate_paths() -> List[Path]:
    paths = [Path.home() / "Library/Group Containers/group.com.apple.usernoted/db2/db"]  # macOS 15+
    try:
        out = subprocess.run(["getconf", "DARWIN_USER_DIR"], capture_output=True, text=True, timeout=5)
        if out.stdout.strip():
            paths.append(Path(out.stdout.strip()) / "com.apple.notificationcenter/db2/db")  # macOS 14 and earlier
    except (OSError, subprocess.SubprocessError):
        pass
    return paths


def pretty(path: Path) -> str:
    """The path with the home folder shown as ~, so output never contains the user name."""
    home = str(Path.home())
    text = str(path)
    return "~" + text[len(home) :] if text.startswith(home) else text


def check_readable(path: Path) -> None:
    try:
        with open(path, "rb") as f:
            f.read(16)  # the SQLite file header only
    except (FileNotFoundError, NotADirectoryError):
        raise ProbeError(f"No database at {pretty(path)}") from None
    except PermissionError:
        raise ProbeError(FDA_HELP) from None


def find_database(explicit: Optional[str]) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        check_readable(path)
        return path
    tried = []
    for path in candidate_paths():
        try:
            check_readable(path)
            return path
        except ProbeError as error:
            if str(error) == FDA_HELP:
                raise
            tried.append(pretty(path))
    raise ProbeError(
        "Couldn't find the notification database. Looked in:\n  "
        + "\n  ".join(tried)
        + "\nIf you know where it is, pass --db PATH."
    )


def _uses_wal(path: Path) -> bool:
    """True if the database file's header says it is in write-ahead-log mode."""
    with open(path, "rb") as f:
        header = f.read(20)
    return len(header) == 20 and 2 in (header[18], header[19])


def _open_direct(path: Path) -> sqlite3.Connection:
    """Read-only connection to the live file (SQLite still sees its write-ahead log).

    A WAL database whose -wal/-shm files are missing would make SQLite create them even in
    read-only mode, i.e. write into the protected folder, so that case uses the private copy.
    """
    if _uses_wal(path) and not all(Path(str(path) + s).exists() for s in ("-wal", "-shm")):
        raise sqlite3.OperationalError("WAL sidecars absent; using a private copy instead")
    conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    try:
        conn.execute("PRAGMA query_only = ON")
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
    except sqlite3.Error:
        conn.close()
        raise
    return conn


def _stamp(path: Path) -> Tuple:
    """Size and modification time of the database and its write-ahead log (None if absent)."""
    stamps = []
    for suffix in ("", "-wal"):
        try:
            info = os.stat(str(path) + suffix)
            stamps.append((info.st_size, info.st_mtime_ns))
        except FileNotFoundError:
            stamps.append(None)
    return tuple(stamps)


@contextmanager
def connect(path: Path) -> Iterator[sqlite3.Connection]:
    """Read-only connection to the live file, or to a consistent private copy if that fails."""
    try:
        conn = _open_direct(path)
    except sqlite3.OperationalError:
        conn = None
    if conn is not None:
        try:
            yield conn
        finally:
            conn.close()
        return
    # Fallback: copy the database and its write-ahead log (not the shared-memory index, which
    # SQLite rebuilds) into a private temp folder. Retry until neither file changed during the
    # copy and the copy passes a quick check; delete it straight after use.
    with tempfile.TemporaryDirectory(prefix="aegis-probe-") as tmp:
        copy = Path(tmp) / "db"
        for attempt in range(COPY_ATTEMPTS):
            for suffix in ("", "-wal", "-shm"):
                Path(str(copy) + suffix).unlink(missing_ok=True)
            before = _stamp(path)
            try:
                for suffix in ("", "-wal"):
                    source = Path(str(path) + suffix)
                    if source.exists():
                        shutil.copyfile(source, str(copy) + suffix)
            except FileNotFoundError:  # the log was checkpointed away mid-copy
                before = None
            if before is not None and _stamp(path) == before:
                candidate = sqlite3.connect(str(copy))
                try:
                    if candidate.execute("PRAGMA quick_check").fetchone()[0] == "ok":
                        conn = candidate
                        break
                except sqlite3.DatabaseError:
                    pass
                candidate.close()
            time.sleep(0.05 * (attempt + 1))
        if conn is None:
            raise ProbeError("The notification database kept changing while being copied. Try again in a moment.")
        try:
            yield conn
        finally:
            conn.close()


# ---------------------------------------------------------------- reading


def quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


class Layout:
    """Which tables and columns hold the metadata the probe needs."""

    def __init__(self, conn: sqlite3.Connection):
        names = [row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")]
        self.tables = {name: [row[1] for row in conn.execute(f"PRAGMA table_info({quote(name)})")] for name in names}
        self.app = next((t for t, c in self.tables.items() if {"app_id", "identifier"} <= set(c)), None)
        self.record = next(
            (
                t
                for t, c in self.tables.items()
                if t != self.app and "app_id" in c and ({"delivered_date", "request_date"} & set(c))
            ),
            None,
        )
        record_columns = set(self.tables.get(self.record, []))
        self.time_col = next((c for c in ("delivered_date", "request_date") if c in record_columns), None)
        self.id_col = "rec_id" if "rec_id" in record_columns else "rowid"  # SQLite's built-in row id as fallback
        self.has_presented = "presented" in record_columns
        self.has_uuid = "uuid" in record_columns
        self.has_request_date = "request_date" in record_columns

    @property
    def ok(self) -> bool:
        return bool(self.app and self.record and self.time_col)


def require_layout(conn: sqlite3.Connection) -> Layout:
    layout = Layout(conn)
    if not layout.ok:
        raise ProbeError(
            "This database doesn't have the layout the probe expects.\n"
            "Run the probe's `schema` command and paste its output into issue #4 so Claude can adapt the probe."
        )
    return layout


def to_unix(value) -> Optional[float]:
    """Notification Center times are seconds since 2001-01-01; accept Unix seconds or nanoseconds too."""
    if value is None:
        return None
    seconds = float(value)
    if seconds > 1e11:  # nanoseconds
        seconds /= 1e9
    return seconds + COCOA_EPOCH if seconds < 1.5e9 else seconds


def fetch(conn: sqlite3.Connection, layout: Layout) -> List[Note]:
    """Every record, metadata only."""
    names = [layout.id_col, "identifier", layout.time_col, "presented", "uuid"]
    assert all(n in SAFE_COLUMNS for n in names), "probe may only read metadata columns"
    presented = "r.presented" if layout.has_presented else "NULL"
    # What tells two records with the same id apart. It must not change when a record is delivered,
    # so the delivery time is never part of it: the uuid, else the request time, else just the app.
    uuid = "hex(r.uuid)" if layout.has_uuid else "NULL"
    requested = "CAST(r.request_date AS TEXT)" if layout.has_request_date else "NULL"
    sql = (
        f"SELECT r.{layout.id_col}, a.identifier, r.{layout.time_col}, {presented}, {uuid}, {requested} "
        f"FROM {quote(layout.record)} r LEFT JOIN {quote(layout.app)} a ON a.app_id = r.app_id "
        f"ORDER BY r.{layout.id_col}"
    )
    notes = []
    for rec_id, app, when, shown, uuid_hex, requested_at in conn.execute(sql):
        app = app or "(unknown)"
        notes.append(
            Note(
                rec_id=rec_id,
                app=app,
                when=to_unix(when),
                presented=None if shown is None else bool(shown),
                token=uuid_hex or f"{requested_at}|{app}",  # per row: a NULL uuid falls back too
            )
        )
    return notes


_BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_app_cache: dict = {}


def on_this_mac(identifier: str) -> str:
    """'yes' if an app with this bundle ID is installed on this Mac, 'no' if not, '?' if unknown.

    'no' usually means an iPhone-only app, i.e. a notification mirrored from the iPhone.
    """
    if identifier in _app_cache:
        return _app_cache[identifier]
    result = "?"
    if _BUNDLE_ID.match(identifier or ""):
        try:
            out = subprocess.run(
                ["mdfind", f"kMDItemCFBundleIdentifier == '{identifier}'"], capture_output=True, text=True, timeout=10
            )
            if out.returncode == 0:
                result = "yes" if any(line.strip().endswith(".app") for line in out.stdout.splitlines()) else "no"
        except (OSError, subprocess.SubprocessError):
            pass
    _app_cache[identifier] = result
    return result


def fmt_time(unix: Optional[float], with_date: bool = True) -> str:
    if unix is None:
        return "?"
    return datetime.fromtimestamp(unix).strftime("%Y-%m-%d %H:%M" if with_date else "%H:%M:%S")


# ---------------------------------------------------------------- watching


def poll(
    conn: sqlite3.Connection, layout: Layout, state: WatchState
) -> Tuple[List[Note], List[Tuple[Note, Optional[float]]]]:
    """Records that appeared and disappeared since the last check.

    A removed record comes with how long it stayed, or None if it was there before watching began.
    """
    now = time.time()
    current = {note.rec_id: note for note in fetch(conn, layout)}
    removed = []
    for rid, old in state.present.items():
        still = current.get(rid)
        if still is None or still.token != old.token:
            key = (rid, old.token)
            first_seen = state.arrived.pop(key, None)
            if key in state.pending:  # never delivered, so never reported: count it, don't list it
                state.pending.discard(key)
                state.removed_undelivered += 1
                continue
            stayed = None if first_seen is None else now - first_seen
            if stayed is not None:
                state.stays.append(stayed)
            removed.append((old, stayed))
    new = []
    for rid, note in current.items():
        old = state.present.get(rid)
        key = (rid, note.token)
        if old is None or old.token != note.token:
            state.arrived[key] = now
            if note.when is None:  # a request row whose delivery time is filled in later
                state.pending.add(key)
                continue
        elif not (old.when is None and note.when is not None):
            continue  # unchanged, or still waiting for delivery
        state.pending.discard(key)
        state.new.append(note)
        new.append(note)
    state.present = current
    return new, removed


# ---------------------------------------------------------------- commands


def cmd_schema(path: Path, args: argparse.Namespace) -> None:
    with connect(path) as conn:
        layout = Layout(conn)
    print(f"Database: {pretty(path)}")
    for table, columns in layout.tables.items():
        print(f"{table}: {', '.join(columns)}")
    print("\n(Table and column names only. Safe to paste into issue #4.)")


def cmd_summary(path: Path, args: argparse.Namespace) -> None:
    with connect(path) as conn:
        layout = require_layout(conn)
        notes = fetch(conn, layout)
    per_app: dict = {}
    for note in notes:
        count, newest = per_app.get(note.app, (0, None))
        per_app[note.app] = (count + 1, max(filter(None, [newest, note.when]), default=None))
    print(f"Database: {pretty(path)}  ({len(notes)} notifications from {len(per_app)} apps)\n")
    print(f"{'count':>5}  {'newest':16}  {'on this Mac?':12}  app")
    for app, (count, newest) in sorted(per_app.items(), key=lambda item: -item[1][0]):
        print(f"{count:>5}  {fmt_time(newest):16}  {on_this_mac(app):12}  {app}")
    print("\n'no' under 'on this Mac?' means no Mac app has that ID: probably an iPhone app (mirrored).")


def cmd_recent(path: Path, args: argparse.Namespace) -> None:
    since = time.time() - args.minutes * 60
    with connect(path) as conn:
        notes = [n for n in fetch(conn, require_layout(conn)) if n.when is not None and n.when >= since]
    print(f"{len(notes)} notifications in the last {args.minutes:g} minutes (metadata only)\n")
    print(f"{'delivered':16}  {'on this Mac?':12}  app")
    for note in notes:
        print(f"{fmt_time(note.when):16}  {on_this_mac(note.app):12}  {note.app}")


def cmd_watch(path: Path, args: argparse.Namespace) -> None:
    with connect(path) as conn:
        layout = require_layout(conn)
        state = WatchState(present={note.rec_id: note for note in fetch(conn, layout)})
    print(f"Watching {pretty(path)} (metadata only). Press Ctrl-C to stop.\n")
    print(f"{'seen':8}  {'delay':>6}  {'on this Mac?':12}  app")
    polls = 0
    try:
        while args.max_polls is None or polls < args.max_polls:
            try:
                with connect(path) as conn:
                    new, removed = poll(conn, layout, state)
            except (ProbeError, sqlite3.DatabaseError) as error:
                if str(error) == FDA_HELP:
                    raise
                print(f"{fmt_time(time.time(), False):8}  (skipped one check: {type(error).__name__})", flush=True)
                new, removed = [], []
            now = time.time()
            for note in new:
                delay = f"{now - note.when:5.1f}s" if note.when is not None else "     ?"
                print(f"{fmt_time(now, False):8}  {delay:>6}  {on_this_mac(note.app):12}  {note.app}", flush=True)
            for note, stayed in removed:
                how_long = f"after {stayed:.0f}s" if stayed is not None else "(it was there before watching)"
                print(f"{fmt_time(now, False):8}  removed from the database {how_long}: {note.app}", flush=True)
            polls += 1
            if args.max_polls is None or polls < args.max_polls:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        print()
    print_watch_summary(state)


def print_watch_summary(state: WatchState) -> None:
    apps = sorted({note.app for note in state.new})
    not_on_mac = [app for app in apps if on_this_mac(app) == "no"]
    print(f"\nSeen {len(state.new)} new notifications from {len(apps)} apps.")
    if not_on_mac:
        print(f"From apps not installed on this Mac (probably mirrored from the iPhone): {', '.join(not_on_mac)}")
    else:
        print("None came from an app missing on this Mac, so nothing was clearly mirrored from the iPhone.")
    if state.stays:
        print(f"Removed from the database while watching: {len(state.stays)} (shortest stay {min(state.stays):.0f}s).")
    if state.pending:
        print(f"Recorded but never marked delivered while watching: {len(state.pending)}.")
    if state.removed_undelivered:
        print(f"Recorded, then removed before ever being delivered: {state.removed_undelivered}.")
    print(
        "\nFor issue #4, record: whether your iPhone-only test apps appeared, their app IDs, the delay, "
        "and the conditions you tested. Never paste message text."
    )


def main(argv: Optional[List[str]] = None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--db", help="path to the notification database (default: find it automatically)")
    parser = argparse.ArgumentParser(
        description="Metadata-only, read-only probe of the macOS Notification Center database (Aegis Stage 0)."
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("schema", parents=[common], help="table and column names only")
    sub.add_parser("summary", parents=[common], help="notification counts per app")
    recent = sub.add_parser("recent", parents=[common], help="notifications delivered in the last N minutes")
    recent.add_argument("--minutes", type=float, default=60)
    watch = sub.add_parser("watch", parents=[common], help="live: one line per new notification")
    watch.add_argument("--interval", type=float, default=1.0, help="seconds between checks (default 1)")
    watch.add_argument("--max-polls", type=int, default=None, help=argparse.SUPPRESS)  # for tests
    args = parser.parse_args(argv)

    commands = {"schema": cmd_schema, "summary": cmd_summary, "recent": cmd_recent, "watch": cmd_watch}
    try:
        commands[args.command](find_database(args.db), args)
    except ProbeError as error:
        print(error, file=sys.stderr)
        return 1
    except sqlite3.DatabaseError as error:
        print(f"SQLite error ({type(error).__name__}): {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
