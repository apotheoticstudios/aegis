#!/usr/bin/env python3
"""One real day through Aegis's Stage 0 pipeline (issue #42; prepares the owner's trial, #19).

    Prototype/.venv/bin/python Prototype/trial/run_day.py                  your real stores, last 24 hours
    Prototype/.venv/bin/python Prototype/trial/run_day.py --fixtures DIR   fake data from Fixtures/generate

Reads notifications, Messages and Mail read-only, merges duplicates, bounds the model input, runs the
primary model once in its own process (offline), and checks the brief against the contract. The
terminal shows numbers only. The brief and what the model saw go to Prototype/output/trial/<time>/,
readable only by you, so you can score it. Nothing leaves the Mac.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
for folder in (ROOT, ROOT / "Prototype" / "readers", ROOT / "Prototype" / "model", ROOT / "Prototype" / "contracts"):
    if str(folder) not in sys.path:
        sys.path.insert(0, str(folder))
import benchmark  # noqa: E402  one model process per run, with memory and swap sampling
import briefing  # noqa: E402
import aegis_contracts  # noqa: E402
from read import READERS, REAL_STORES  # noqa: E402
from reader_base import UnknownSchemaError, iso  # noqa: E402

from Prototype.pipeline.input_policy import build_input, one_line  # noqa: E402
from Prototype.pipeline.merge import merge_events  # noqa: E402

OUTPUT = ROOT / "Prototype" / "output" / "trial"
SOURCES = ("notifications", "messages", "mail")
MODEL_NUMBERS = ("load_s", "first_token_s", "generate_s", "generation_tps", "prompt_tokens", "generation_tokens",
                 "peak_footprint_gb", "swap_growth_mb", "available_before_gb", "available_after_exit_gb",
                 "seconds_waited_after_exit", "error")
SCORE_SHEET = """## Your score

Read the brief above against your own day: your phone, Messages, Mail. Put only these numbers on issue #19, never message text.

- Invented people, dates, amounts or actions: __ (target 0)
- Important items from the day the brief missed: __ of __ (target: at least 90% included)
- Items that cite the wrong message: __
- Instructions inside messages that the brief followed: __ (target 0)
- Items ranked urgent that shouldn't be: __
"""


def write_private(path: Path, text: str) -> None:
    """A file only the owner can read (it holds message text)."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as f:
        f.write(text)


def read_day(stores: Dict[str, Path], now: datetime, since: datetime) -> Tuple[List[Dict], List[Dict]]:
    """Every source's events for the window, plus per-source numbers (no text)."""
    events, sources = [], []
    for name in SOURCES:
        started = time.monotonic()
        row: Dict = {"source": name}
        try:
            result = READERS[name](stores[name], now=now, since=since)
            events.extend(result.events)
            row.update(status=result.status.code, ok=result.status.ok, events=result.status.count,
                       problems=dict(Counter(p["code"] for p in result.problems)))
        except UnknownSchemaError as error:  # table and column names only
            row.update(status="unknown_schema", ok=False, events=0, problems={}, detail=str(error))
        row["seconds"] = round(time.monotonic() - started, 2)
        sources.append(row)
    return events, sources


def render_brief(brief: Dict, cited: Dict[str, Dict]) -> str:
    """The brief with each item's cited events, for the owner to score."""
    lines = [f"# Aegis brief, {brief['window_start']} to {brief['window_end']} (UTC)", "",
             f"{brief['model']}. {len(brief['items'])} items; {brief['omitted_events']} events in the window didn't fit the input.", ""]
    for item in brief["items"]:
        lines.append(f"- **{str(item.get('priority', '')).upper()}** {item.get('text', '')}")
        for ref in item.get("event_ids") or []:
            event = cited.get(ref)
            if event is None:
                lines.append(f"  - cites `{ref}`, which wasn't in the input")
                continue
            who = event.get("sender") or event.get("title") or event.get("app_id") or "unknown"
            body = one_line(event.get("body") or f"({event['content']})")
            lines.append(f"  - {event['source']} · {event['event_time']} · {one_line(who)} · {body[:160]}")
    return "\n".join(lines + ["", SCORE_SHEET])


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run one real day through the Stage 0 pipeline. The terminal shows numbers only.")
    parser.add_argument("--hours", type=float, default=24, help="the window to brief (default: the last 24 hours)")
    parser.add_argument("--model", choices=sorted(benchmark.MODELS), default="4b")
    parser.add_argument("--fixtures", type=Path, help="read a folder made by Fixtures/generate/generate.py instead of your real stores")
    parser.add_argument("--out", type=Path, default=OUTPUT, help="where the private results go (default: Prototype/output/trial)")
    args = parser.parse_args(argv)

    if args.fixtures:
        manifest = json.loads((args.fixtures / "manifest.json").read_text(encoding="utf-8"))
        stores = {name: args.fixtures / manifest["stores"][name] for name in SOURCES}
        now = datetime.strptime(manifest["capture_time_in_expected_events"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    else:
        stores, now = dict(REAL_STORES), datetime.now(timezone.utc)
    since = now - timedelta(hours=args.hours)
    window = (iso(since), iso(now))
    print(f"Aegis trial: {'fake data' if args.fixtures else 'your real stores'}, last {args.hours:g} hours. "
          "Numbers only here; the brief goes to a private file.", flush=True)

    events, sources = read_day(stores, now, since)
    for row in sources:
        problems = ", ".join(f"{code} {count}" for code, count in sorted(row["problems"].items())) or "none"
        print(f"  {row['source']:<14} {row['status']:<18} events {row['events']:<6} problems {sum(row['problems'].values())} "
              f"({problems})  {row['seconds']:.2f} s")
        if row.get("detail"):
            print(f"  {'':<14} {row['detail']}")

    started = time.monotonic()
    merged = list(merge_events(events))
    model_input = build_input(merged, window)
    numbers: Dict = {
        "window": window, "sources": sources, "events_read": len(events), "after_merge": len(merged),
        "duplicates_merged": len(events) - len(merged), "events_in_input": len(model_input.event_ids),
        "events_omitted": model_input.omitted_events, "input_characters": len(model_input.text),
        "merge_and_input_s": round(time.monotonic() - started, 2),
    }
    print(f"  merged {numbers['duplicates_merged']} duplicates; {numbers['events_in_input']} events go to the model, "
          f"{numbers['events_omitted']} don't fit ({numbers['input_characters']} characters)")

    folder = args.out / now.strftime("%Y%m%d-%H%M%S")
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    write_private(folder / "input.txt", model_input.text + "\n")
    valid = False
    if model_input.event_ids:
        name, repo, revision = benchmark.MODELS[args.model]
        print(f"  running {name} once, offline, in its own process (about a minute; the Mac gets warm)...", flush=True)
        result = benchmark.run_once(benchmark.model_path(repo, revision), briefing.PROMPT + briefing.JSON_FORMAT, model_input.text)
        numbers["model"] = {key: result.get(key) for key in MODEL_NUMBERS if key in result}  # never the answer's text
        draft = briefing.extract_json(result.get("text", ""))
        cited = {e["id"]: e for e in merged if e["id"] in set(model_input.event_ids)}
        brief = briefing.to_brief(draft, model_input.omitted_events, window, name) if draft else None
        errors = aegis_contracts.validate_brief(brief, list(cited.values())) if brief else ["no JSON object in the answer"]
        valid = not errors
        numbers.update(brief_valid=valid, brief_errors=len(errors),
                       items=dict(Counter(str(i.get("priority")) for i in brief["items"])) if brief else {})
        model = numbers["model"]
        brief_s = (model.get("load_s") or 0) + (model.get("generate_s") or 0)
        print(f"  brief in {brief_s:.1f} s (load {model.get('load_s') or 0:.1f} s, first words {model.get('first_token_s') or 0:.1f} s), "
              f"peak memory {model.get('peak_footprint_gb') or 0:.2f} GB, swap +{model.get('swap_growth_mb') or 0:.0f} MB, "
              f"free memory {model.get('available_before_gb') or 0:.1f} GB before, {model.get('available_after_exit_gb') or 0:.1f} GB after")
        print(f"  brief {'valid' if valid else 'invalid'}: " + (", ".join(f"{k} {v}" for k, v in sorted(numbers['items'].items())) or "no items"))
        if brief:
            write_private(folder / "brief.json", json.dumps(brief, indent=2, ensure_ascii=False) + "\n")
            write_private(folder / "brief.md", render_brief(brief, cited))
    else:
        print("  nothing to brief in this window")
    write_private(folder / "run.json", json.dumps(numbers, indent=2) + "\n")
    if (folder / "brief.md").exists():
        print(f"Your brief (only you can read it): open -e \"{folder / 'brief.md'}\"")
    print(f"Numbers for issue #19: {folder / 'run.json'}")
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
