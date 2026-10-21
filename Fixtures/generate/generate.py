#!/usr/bin/env python3
"""Builds the synthetic Stage 0 stores and what a correct reader should get from them (issue #14).

    python3 Fixtures/generate/generate.py OUT_DIR [--seed 7] [--profile full|empty|drift|stage1] [--huge]

OUT_DIR gets:
    notifications/db                 Notification Center database (WAL mode)
    messages/chat.db                 Messages database
    mail/V10/...                     Mail's Envelope Index and .emlx files
    expected/notifications.jsonl     contract events a correct notification reader emits
    expected/messages.jsonl          ... a Messages reader
    expected/mail.jsonl              ... a Mail reader
    expected/problems.json           errors and skips a correct reader reports (codes from #6)
    expected/duplicates.json         cross-route twins the pipeline (#17) should merge
    manifest.json                    seed, profile, and whether each store's layout is verified

Everything is invented and deterministic for a seed. Never commit the output: generate it at test time
(the privacy guard rejects database and .emlx files).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mail  # noqa: E402
import messages  # noqa: E402
import notifications  # noqa: E402
from common import CAPTURE_TIME, Rng, aegis_contracts  # noqa: E402

GENERATOR_VERSION = "0.2"  # 0.2: unknown titles and threads are null (Codex review of #30)
# Flip to "verified" once the owner's runs confirm a layout (#4 for notifications, #19 for the rest).
LAYOUTS = {"notifications": "hypothetical", "messages": "hypothetical", "mail": "hypothetical"}


def _write_jsonl(path: Path, rows: List[Dict]) -> None:
    path.write_text("".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


def generate(out: Path, seed: int = 7, profile: str = "full", huge: bool = False) -> Dict:
    if profile == "stage1":
        import stage1
        return stage1.generate(Path(out), seed, huge)
    if profile not in ("full", "empty", "drift"):
        raise ValueError(f"unknown profile {profile!r}")
    out = Path(out)
    rng = Rng(seed)
    empty = profile == "empty"
    note_events, note_problems, hints = notifications.build(out / "notifications", rng, empty=empty)
    msg_events, msg_problems, anchors = messages.build(out / "messages", rng, empty=empty, extra_rows=200_000 if huge else 0)
    mail_events, mail_problems = mail.build(out / "mail", rng, empty=empty, drift=profile == "drift", huge=huge)

    by_key = {anchor["key"]: anchor["message"] for anchor in anchors}
    duplicates = [
        {
            "notification_event": aegis_contracts.event_id("notification", hint["notification"]),
            "message_event": aegis_contracts.event_id("imessage", by_key[hint["matches"]]),
            "rule": hint["rule"],
        }
        for hint in hints
        if hint["matches"] in by_key
    ]

    expected = out / "expected"
    expected.mkdir(parents=True, exist_ok=True)
    _write_jsonl(expected / "notifications.jsonl", note_events)
    _write_jsonl(expected / "messages.jsonl", msg_events)
    _write_jsonl(expected / "mail.jsonl", mail_events)
    (expected / "problems.json").write_text(json.dumps(note_problems + msg_problems + mail_problems, indent=2, ensure_ascii=False) + "\n")
    (expected / "duplicates.json").write_text(json.dumps(duplicates, indent=2) + "\n")

    manifest = {
        "generator_version": GENERATOR_VERSION,
        "seed": seed,
        "profile": profile,
        "huge": huge,
        "capture_time_in_expected_events": CAPTURE_TIME,
        "layouts": LAYOUTS,
        "stores": {
            "notifications": "notifications/db",
            "messages": "messages/chat.db",
            "mail": "mail/V10/MailData/Envelope Index",
        },
        "counts": {
            "notifications": len(note_events),
            "messages": len(msg_events),
            "mail": len(mail_events),
            "problems": len(note_problems) + len(msg_problems) + len(mail_problems),
            "duplicates": len(duplicates),
        },
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Build synthetic Stage 0/1 stores and their expected reader output.")
    parser.add_argument("out", type=Path)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--profile", choices=["full", "empty", "drift", "stage1"], default="full")
    parser.add_argument("--huge", action="store_true", help="add 200,000 bulk messages and a ~24 MB email (not in expected events)")
    args = parser.parse_args(argv)
    manifest = generate(args.out, args.seed, args.profile, args.huge)
    print(json.dumps(manifest["counts"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
