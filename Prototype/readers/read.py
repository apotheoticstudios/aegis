#!/usr/bin/env python3
"""Runs the Stage 0 readers and prints counts only, never message text (issue #15; the owner's trial is #19).

    python3 Prototype/readers/read.py --fixtures DIR      fake data made by Fixtures/generate (anyone)
    python3 Prototype/readers/read.py [--hours 24]        the owner's real stores (Terminal needs Full Disk Access)

--save writes the events and problems to Prototype/output/readers/ (git-ignored, readable only by you) for
the brief pipeline. Exit status: 0 when every source read cleanly or was empty, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import sys
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mail_reader  # noqa: E402
import messages_reader  # noqa: E402
import notification_reader  # noqa: E402
from reader_base import UnknownSchemaError  # noqa: E402

REAL_STORES = {
    "mail": Path.home() / "Library/Mail",  # privacy-guard: allow-real-path owner-run reader
    "notifications": Path.home() / "Library/Group Containers/group.com.apple.usernoted/db2/db",  # privacy-guard: allow-real-path owner-run reader, macOS 15+
    "messages": Path.home() / "Library/Messages/chat.db",  # privacy-guard: allow-real-path owner-run reader
}
READERS = {"mail": mail_reader.read_mail, "notifications": notification_reader.read_notifications, "messages": messages_reader.read_messages}
OUTPUT = HERE.parent / "output" / "readers"
ADVICE = {
    "not_found": "no database at that path on this Mac",
    "permission_denied": "give Terminal Full Disk Access (System Settings > Privacy & Security), quit and reopen Terminal, run again",
    "busy": "the database was locked or kept changing; run again",
    "unreadable": "the file isn't a readable SQLite database",
    "unknown_schema": "the layout differs from what the reader knows; paste this output on the issue",
}


def _private_file(path: Path):
    """A file only the owner can read (it may hold message text)."""
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8")


def _peak_memory_mb() -> float:
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / 2**20 if sys.platform == "darwin" else peak / 2**10  # bytes on macOS, KiB on Linux


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Run the Stage 0 readers. Prints counts only, never message text.")
    parser.add_argument("--source", choices=["all", "notifications", "messages", "mail"], default="all")
    parser.add_argument("--fixtures", type=Path, help="read a folder made by Fixtures/generate/generate.py instead of your real stores")
    parser.add_argument("--hours", type=float, help="only events from the last N hours (default: 24 for real stores, everything for fixtures)")
    parser.add_argument("--save", action="store_true", help="write events and problems as JSON lines (they include message text)")
    parser.add_argument("--out", type=Path, default=OUTPUT, help="where --save writes (default: Prototype/output/readers)")
    args = parser.parse_args(argv)

    names = ["notifications", "messages", "mail"] if args.source == "all" else [args.source]
    if args.fixtures:
        manifest = json.loads((args.fixtures / "manifest.json").read_text(encoding="utf-8"))
        stores = {name: args.fixtures / manifest["stores"][name] for name in names}
        now = datetime.strptime(manifest["capture_time_in_expected_events"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        hours = args.hours or 0
    else:
        stores = {name: REAL_STORES[name] for name in names}
        now = datetime.now(timezone.utc)
        hours = 24 if args.hours is None else args.hours
    since = now - timedelta(hours=hours) if hours else None
    if args.save:
        args.out.mkdir(parents=True, exist_ok=True)
        os.chmod(args.out, 0o700)

    print(f"Aegis readers: counts only, no message text. {'Fake data' if args.fixtures else 'Your real stores'}, "
          f"{f'last {hours:g} hours' if hours else 'everything'}.")
    clean = True
    for name in names:
        codes: Counter = Counter()
        files = {kind: _private_file(args.out / f"{name}-{kind}s.jsonl") for kind in ("event", "problem")} if args.save else {}

        def on_item(kind: str, item: dict) -> None:
            if kind == "problem":
                codes[item["code"]] += 1
            if files:
                files[kind].write(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n")

        started = time.monotonic()
        detail = ""
        try:
            status = READERS[name](stores[name], now=now, since=since, on_item=on_item).status
            code, count, ok = status.code, status.count, status.ok
        except UnknownSchemaError as error:
            code, count, ok, detail = "unknown_schema", 0, False, str(error)
        finally:
            for f in files.values():
                f.close()
        problems = ", ".join(f"{c} {n}" for c, n in sorted(codes.items())) or "none"
        print(f"{name:<14} {code:<18} events {count:<7} problems {sum(codes.values())} ({problems})  {time.monotonic() - started:.2f} s")
        if detail:
            print(f"{'':<14} {detail}")
        if not ok:
            clean = False
            print(f"{'':<14} -> {ADVICE.get(code, 'see Prototype/readers/README.md')}")
    print(f"Peak memory for the whole run: {_peak_memory_mb():.0f} MB.")
    if args.save:
        print(f"Saved to {args.out} (includes message text: never commit or share it; delete it when you're done).")
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
