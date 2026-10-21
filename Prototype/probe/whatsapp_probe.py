#!/usr/bin/env python3
"""WhatsApp store probe (Stage 2 step 0.2, docs/stages/STAGE-2.md).

Answers one question on the owner's own Mac: can Aegis read the WhatsApp Mac app's local store,
and what shape is it? It prints structure only: whether the store exists and opens, table and
column names, row counts, which kinds of chat IDs appear (counts by suffix) and the date range
of messages. It never selects or prints message text, names, phone numbers or IDs.

Safety:
- Structure only, as above. Tests check that invented text never appears in the output.
- Read-only. It copies the store (with its WAL) into a private temporary folder, reads the copy
  and deletes it.
- Local only. Python standard library, no network.

Only the owner runs this against the real store (Terminal needs Full Disk Access). Agents and
tests use an invented store. See README.md in this folder.
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

COCOA_EPOCH = 978307200  # seconds from 1970-01-01 to 2001-01-01

CONTAINER = Path.home() / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared"  # privacy-guard: allow-real-path owner-run structure probe (STAGE-2 0.2)
STORE_NAMES = ("ChatStorage.sqlite", "ContactsV2.sqlite")

# Columns whose values the probe may aggregate (never print individually).
JID_COLUMNS = ("ZFROMJID", "ZTOJID", "ZCONTACTJID")
DATE_COLUMNS = ("ZMESSAGEDATE",)
JID_KINDS = ("@s.whatsapp.net", "@g.us", "@lid", "@broadcast", "@newsletter")


class ProbeError(Exception):
    """A problem the owner can fix. Printed without a traceback."""


def private_copy(store: Path, folder: Path) -> Path:
    """Copy the store and its WAL/SHM into `folder` so the live files are never opened."""
    target = folder / store.name
    for suffix in ("", "-wal", "-shm"):
        source = Path(str(store) + suffix)
        if source.exists():
            shutil.copy2(source, Path(str(target) + suffix))
    return target


def header_kind(path: Path) -> str:
    with open(path, "rb") as handle:
        return "sqlite" if handle.read(16) == b"SQLite format 3\x00" else "not plain SQLite (encrypted or another format)"


def describe(path: Path) -> Dict[str, object]:
    """Structure of one SQLite file: tables, columns, counts and aggregate facts."""
    report: Dict[str, object] = {"header": header_kind(path)}
    if report["header"] != "sqlite":
        return report
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        tables = [row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        details = []
        for table in tables:
            quoted = '"' + table.replace('"', '""') + '"'
            columns = [row[1] for row in connection.execute(f"PRAGMA table_info({quoted})")]
            count = connection.execute(f"SELECT COUNT(*) FROM {quoted}").fetchone()[0]
            facts: Dict[str, object] = {}
            for column in columns:
                if column in JID_COLUMNS:
                    facts[column] = jid_kinds(connection, quoted, column)
                if column in DATE_COLUMNS:
                    facts[column] = date_range(connection, quoted, column)
            details.append({"table": table, "rows": count, "columns": columns, "facts": facts})
        report["tables"] = details
    except sqlite3.DatabaseError as error:
        report["error"] = type(error).__name__
    finally:
        connection.close()
    return report


def jid_kinds(connection: sqlite3.Connection, table: str, column: str) -> Dict[str, int]:
    """Counts of chat ID kinds by suffix; the IDs themselves never leave SQLite."""
    quoted = '"' + column.replace('"', '""') + '"'
    counts = {}
    for kind in JID_KINDS:
        counts[kind] = connection.execute(
            f"SELECT COUNT(*) FROM {table} WHERE {quoted} LIKE ?", ("%" + kind,)).fetchone()[0]
    counts["other"] = connection.execute(
        f"SELECT COUNT(*) FROM {table} WHERE {quoted} IS NOT NULL AND "
        + " AND ".join(f"{quoted} NOT LIKE ?" for _ in JID_KINDS),
        tuple("%" + kind for kind in JID_KINDS)).fetchone()[0]
    return counts


def date_range(connection: sqlite3.Connection, table: str, column: str) -> Optional[List[str]]:
    """Earliest and latest day (Cocoa seconds), to see how much history the Mac holds."""
    quoted = '"' + column.replace('"', '""') + '"'
    low, high = connection.execute(f"SELECT MIN({quoted}), MAX({quoted}) FROM {table}").fetchone()
    if low is None or high is None:
        return None
    day = lambda value: datetime.fromtimestamp(float(value) + COCOA_EPOCH, tz=timezone.utc).strftime("%Y-%m-%d")
    return [day(low), day(high)]


def probe(container: Path) -> List[str]:
    lines = []
    if not container.exists():
        return ["WhatsApp's Mac store wasn't found (is the WhatsApp Mac app installed and signed in?)."]
    try:
        names = sorted(path.name for path in container.iterdir())
    except PermissionError as error:
        raise ProbeError("macOS blocked access. Give Terminal Full Disk Access, quit it (Cmd-Q), reopen and retry.") from error
    lines.append(f"Container found; {len(names)} entries. SQLite files: "
                 + ", ".join(name for name in names if name.endswith(".sqlite")))
    with tempfile.TemporaryDirectory(prefix="aegis-probe-") as folder:
        Path(folder).chmod(0o700)
        for name in STORE_NAMES:
            store = container / name
            if not store.exists():
                lines.append(f"{name}: not present")
                continue
            report = describe(private_copy(store, Path(folder)))
            lines.append(f"{name}: {report['header']}")
            if "error" in report:
                lines.append(f"  could not read: {report['error']}")
            for table in report.get("tables", []):
                lines.append(f"  {table['table']}: {table['rows']} rows; columns: {', '.join(table['columns'])}")
                for column, fact in table["facts"].items():
                    lines.append(f"    {column}: {fact}")
    return lines


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Structure-only probe of the WhatsApp Mac store.")
    parser.add_argument("--container", type=Path, default=CONTAINER, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        for line in probe(args.container):
            print(line)
    except ProbeError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
