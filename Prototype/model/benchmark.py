#!/usr/bin/env python3
"""MLX model benchmark (Stage 0, issue #18).

Runs each pinned model on short, typical and long synthetic inputs, each run in its own process, and
records: load time, first token, generation speed, whole-brief time, peak memory footprint of the
process (sampled with macOS's `footprint`), MLX's own peak, swap growth, memory available again 5 s
after the process exits, whether the brief is valid against the contract, and recall of the
must-include items. Synthetic events only; offline (models must already be downloaded).

    Prototype/.venv/bin/python Prototype/model/benchmark.py [--runs 2] [--models 4b,9b]

Results: Prototype/output/model/mlx-results.json and .md (gitignored).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "contracts"))
import briefing  # noqa: E402
import aegis_contracts as contracts  # noqa: E402

OUTPUT = HERE.parent / "output" / "model"
EVENTS = HERE.parent / "contracts" / "examples" / "events.jsonl"
WINDOW = ("2026-10-05T21:00:00Z", "2026-10-06T21:00:00Z")
MODELS = {
    "4b": ("Qwen3.5-4B (4-bit)", "mlx-community/Qwen3.5-4B-MLX-4bit", "32f3e8ecf65426fc3306969496342d504bfa13f3"),
    "9b": ("Qwen3.5-9B (4-bit)", "mlx-community/Qwen3.5-9B-MLX-4bit", "938d8919941c6e7efd3c7150eff7fe9d12afa631"),
}
# In the synthetic corpus, by source record: the invoice must be urgent and Alex's call request a reply.
MUST_INCLUDE = {("email", "<invoice-1043@example.com>"): "urgent", ("imessage", "B6E0F0A1-0000-4000-8000-000000000001"): "reply"}
OFFLINE = {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1"}
GB = 1024**3


def model_path(repo: str, revision: str) -> str:
    from huggingface_hub import snapshot_download

    return snapshot_download(repo, revision=revision, local_files_only=True)


def scaled(events: List[Dict], count: int) -> List[Dict]:
    """`count` invented events: the examples repeated with new ids and earlier times (for input length only)."""
    out = []
    for index in range(count):
        event = dict(events[index % len(events)])
        copy = index // len(events)
        if copy:
            event["source_record_id"] = f"{event['source_record_id']}-copy{copy}"
            event["id"] = contracts.event_id(event["source"], event["source_record_id"])
            hour = int(event["event_time"][11:13])
            event["event_time"] = event["event_time"][:11] + f"{max(0, hour - copy):02d}" + event["event_time"][13:]
        out.append(event)
    return out


def available_bytes() -> int:
    """Free + inactive + speculative + purgeable memory, from vm_stat."""
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+) bytes", out).group(1))
    pages = 0
    for name in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"):
        match = re.search(rf"{name}:\s+(\d+)\.", out)
        pages += int(match.group(1)) if match else 0
    return pages * page


def swap_used_bytes() -> int:
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    match = re.search(r"used = ([\d.]+)M", out)
    return int(float(match.group(1)) * 1024 * 1024) if match else 0


def footprint_bytes(pid: int) -> Optional[int]:
    with tempfile.NamedTemporaryFile(suffix=".json") as out:
        done = subprocess.run(
            ["footprint", "-p", str(pid), "--noCategories", "-f", "bytes", "-j", out.name], capture_output=True, timeout=30
        )
        if done.returncode != 0:
            return None
        try:
            data = json.loads(Path(out.name).read_text() or "{}")
        except json.JSONDecodeError:
            return None
    return next((int(p["footprint"]) for p in data.get("processes", []) if p.get("pid") == pid and "footprint" in p), None)


def run_once(path: str, system: str, user: str) -> Dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as spec:
        json.dump({"system": system, "user": user, "max_tokens": 700}, spec)
    swap_before, available_before = swap_used_bytes(), available_bytes()
    process = subprocess.Popen(
        [sys.executable, str(HERE / "mlx_worker.py"), path, spec.name],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env={**os.environ, **OFFLINE},
    )
    peak = [0]

    def sample() -> None:
        while process.poll() is None:
            try:
                value = footprint_bytes(process.pid)
            except (OSError, ValueError, subprocess.SubprocessError):
                value = None  # the process was exiting; keep sampling until it's gone
            if value:
                peak[0] = max(peak[0], value)
            time.sleep(0.5)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    stdout, _ = process.communicate()
    sampler.join(timeout=5)
    exited = time.perf_counter()
    time.sleep(5)
    result = json.loads(stdout.strip().splitlines()[-1]) if stdout.strip() else {"error": f"exit code {process.returncode}"}
    os.unlink(spec.name)
    result.update(
        peak_footprint_gb=peak[0] / GB,
        swap_growth_mb=(swap_used_bytes() - swap_before) / (1024 * 1024),
        available_before_gb=available_before / GB,
        available_after_exit_gb=available_bytes() / GB,
        seconds_waited_after_exit=round(time.perf_counter() - exited, 1),
    )
    return result


def judge(result: Dict, events: List[Dict], omitted: int, model: str) -> Dict:
    draft = briefing.extract_json(result.get("text", ""))
    if draft is None:
        return {"valid": False, "errors": ["no JSON object in the answer"], "recall": None, "items": []}
    brief = briefing.to_brief(draft, omitted, WINDOW, model)
    errors = contracts.validate_brief(brief, events)
    must = {contracts.event_id(source, rid): priority for (source, rid), priority in MUST_INCLUDE.items()}
    present = {e["id"] for e in events}
    hits, total = briefing.recall(brief, {k: v for k, v in must.items() if k in present})
    return {"valid": not errors, "errors": errors[:5], "recall": f"{hits}/{total}" if total else None, "items": brief["items"]}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--models", default="4b,9b")
    args = parser.parse_args(argv)

    examples = briefing.load_events(EVENTS)
    inputs = {"short": sorted(examples, key=lambda e: e["event_time"])[-5:], "typical": examples, "long": scaled(examples, 40)}
    system = briefing.PROMPT + briefing.JSON_FORMAT
    rows = []
    for key in args.models.split(","):
        name, repo, revision = MODELS[key]
        path = model_path(repo, revision)
        for size, events in inputs.items():
            user, _, omitted = briefing.build_input(events)
            for run in range(1, args.runs + 1):
                result = run_once(path, system, user)
                verdict = judge(result, events, omitted, name)
                row = {"model": name, "input": size, "events": len(events), "run": run, **result, **verdict}
                row["brief_s"] = (result.get("load_s") or 0) + (result.get("generate_s") or 0)
                rows.append(row)
                print(
                    f"{name:20} {size:8} run {run}: load {row.get('load_s', 0):.1f}s, first token {row.get('first_token_s') or 0:.2f}s, "
                    f"brief {row['brief_s']:.1f}s, {row.get('generation_tps') or 0:.1f} tok/s, peak {row['peak_footprint_gb']:.2f} GB, "
                    f"swap +{row['swap_growth_mb']:.0f} MB, valid {row['valid']}, recall {row['recall']}",
                    flush=True,
                )
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "mlx-results.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False))
    lines = [
        "| Model | Input | Run | Load s | First token s | Brief s | Tok/s | Peak GB | Swap +MB | Valid | Recall |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in rows:
        lines.append(
            f"| {r['model']} | {r['input']} ({r['events']}) | {r['run']} | {r.get('load_s', 0):.1f} | {r.get('first_token_s') or 0:.2f} | "
            f"{r['brief_s']:.1f} | {r.get('generation_tps') or 0:.1f} | {r['peak_footprint_gb']:.2f} | {r['swap_growth_mb']:.0f} | "
            f"{'yes' if r['valid'] else 'no'} | {r['recall'] or '-'} |"
        )
    (OUTPUT / "mlx-results.md").write_text("\n".join(lines) + "\n")
    print("\n" + "\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
