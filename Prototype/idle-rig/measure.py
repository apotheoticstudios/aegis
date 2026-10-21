#!/usr/bin/env python3
"""Empty-shell memory rig (Stage 0, issue #12).

Runs an empty menu-bar app and an empty background agent, samples each one's memory footprint with
macOS's `footprint` tool (dirty memory, what Activity Monitor's "Memory" column shows, not RSS, which
double-counts shared pages), and prints a summary. It is a lower bound for Aegis's 300 MB idle
budget: real code only adds to it. Synthetic: it touches no personal data. Standard library only.

    python3 Prototype/idle-rig/measure.py [--minutes 30] [--interval 60]

Samples go to Prototype/output/idle-rig/samples.csv (gitignored). An icon (a hexagon) sits in the
menu bar while it runs.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
OUTPUT = HERE.parent / "output" / "idle-rig"
FLAG_MB = 100  # combined footprint above this is flagged (STAGE-0.md thresholds)
MB = 1024 * 1024


def footprint_bytes(pid: int) -> Optional[int]:
    """The process's footprint in bytes, or None if it can't be read (e.g. the process exited)."""
    with tempfile.NamedTemporaryFile(suffix=".json") as out:
        done = subprocess.run(
            ["footprint", "-p", str(pid), "--noCategories", "-f", "bytes", "-j", out.name],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if done.returncode != 0:
            return None
        data = json.loads(Path(out.name).read_text() or "{}")
    for process in data.get("processes", []):
        if process.get("pid") == pid:
            return int(process["footprint"])
    return None


def summarize(samples: Dict[str, List[int]]) -> List[str]:
    """Median, minimum and maximum per process and combined, in MB."""
    lines = [f"{'process':14} {'median MB':>10} {'min MB':>8} {'max MB':>8}"]
    combined = [sum(values) for values in zip(*samples.values())]
    for name, values in list(samples.items()) + [("combined", combined)]:
        if values:
            lines.append(
                f"{name:14} {statistics.median(values) / MB:10.1f} {min(values) / MB:8.1f} {max(values) / MB:8.1f}"
            )
    if combined:
        median = statistics.median(combined) / MB
        verdict = "FLAG: above" if median > FLAG_MB else "within"
        lines.append(f"\nCombined median {median:.1f} MB: {verdict} the {FLAG_MB} MB flag (lower bound for the 300 MB budget).")
    return lines


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Measure the memory floor of an empty Aegis shell.")
    parser.add_argument("--minutes", type=float, default=30)
    parser.add_argument("--interval", type=float, default=60, help="seconds between samples")
    args = parser.parse_args(argv)

    subprocess.run(["swift", "build", "-c", "release"], cwd=HERE, check=True, capture_output=True)
    binaries = {name: HERE / ".build" / "release" / name for name in ("idle-menubar", "idle-agent")}
    processes = {name: subprocess.Popen([str(path)]) for name, path in binaries.items()}
    samples: Dict[str, List[int]] = {name: [] for name in processes}
    OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        time.sleep(5)  # let both settle after launch
        rounds = int(args.minutes * 60 / args.interval) + 1
        with open(OUTPUT / "samples.csv", "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["time"] + [f"{name}_bytes" for name in processes])
            for index in range(rounds):
                row = {name: footprint_bytes(proc.pid) for name, proc in processes.items()}
                if None in row.values():
                    print("A process stopped or couldn't be measured; ending early.", file=sys.stderr)
                    break
                for name, value in row.items():
                    samples[name].append(value)
                writer.writerow([datetime.now().strftime("%H:%M:%S")] + list(row.values()))
                f.flush()
                print(f"sample {index + 1}/{rounds}: " + ", ".join(f"{n} {v / MB:.1f} MB" for n, v in row.items()), flush=True)
                if index + 1 < rounds:
                    time.sleep(args.interval)
    except KeyboardInterrupt:
        print()
    finally:
        for proc in processes.values():
            proc.terminate()
        for proc in processes.values():
            proc.wait(timeout=10)
    print("\n" + "\n".join(summarize(samples)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
