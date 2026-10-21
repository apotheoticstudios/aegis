"""Model-independent brief logic (Stage 0, issue #18): the model input, reading the model's answer,
and turning it into a contract brief. Python standard library only; mirrors apple-brief's
AppleBriefCore so every model gets the same input."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE.parents[1]) not in sys.path:
    sys.path.insert(0, str(HERE.parents[1]))
from Prototype.pipeline.merge import merge_events
from Prototype.pipeline.input_policy import build_input as bounded_input

PROMPT = (HERE / "prompt.md").read_text(encoding="utf-8")

# Apple's model gets the brief's shape through guided generation; text models get it spelled out.
JSON_FORMAT = """
Answer with JSON only, no other text, in exactly this shape:
{"items": [{"text": "one short sentence", "priority": "urgent", "event_ids": ["ev_0123456789abcdef"]}]}
"priority" is one of "urgent", "reply", "fyi".
"""


def load_events(path: Path) -> List[Dict]:
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def one_line(text: str) -> str:
    """Line breaks and other control characters become spaces."""
    return "".join(" " if unicodedata.category(c) == "Cc" else c for c in text)


def build_input(events: List[Dict], max_events: int = 40, max_body: int = 280) -> Tuple[str, List[str], int]:
    """Compatibility wrapper over the pipeline; legacy callers use their full event span."""
    window = (min(e["event_time"] for e in events), max(e["event_time"] for e in events)) if events else (
        "2001-01-01T00:00:00Z", "2001-01-01T00:00:00Z")
    order = {}
    for index, event in enumerate(events):
        order.setdefault(event["id"], index)
    result = bounded_input(merge_events(events), window, max_events=max_events, max_body=max_body, input_order=order)
    return result.text, result.event_ids, result.omitted_events


def extract_json(text: str) -> Optional[Dict]:
    """The first JSON object in a model's answer, ignoring thinking blocks and code fences."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"```(?:json)?", "", text)
    start = text.find("{")
    while start != -1:
        depth = 0
        for end in range(start, len(text)):
            if text[end] == "{":
                depth += 1
            elif text[end] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        value = json.loads(text[start : end + 1])
                        return value if isinstance(value, dict) else None
                    except json.JSONDecodeError:
                        break
        start = text.find("{", start + 1)
    return None


def to_brief(draft: Dict, omitted: int, window: Tuple[str, str], model: str) -> Dict:
    """A contract brief from the model's draft. Fields the draft gets wrong are kept as given, so
    validation (not this function) decides what passes."""
    items = []
    for item in draft.get("items", []) if isinstance(draft.get("items"), list) else []:
        if isinstance(item, dict):
            items.append(
                {"text": item.get("text", ""), "priority": item.get("priority", ""), "event_ids": item.get("event_ids", [])}
            )
    return {
        "schema_version": "0.1",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window_start": window[0],
        "window_end": window[1],
        "model": model,
        "items": items,
        "omitted_events": omitted,
    }


def recall(brief: Dict, must_include: Dict[str, str]) -> Tuple[int, int]:
    """How many must-include events (id -> expected priority) a brief cites with that priority."""
    cited = {}
    for item in brief.get("items", []):
        for ref in item.get("event_ids", []):
            cited.setdefault(ref, set()).add(item.get("priority"))
    hits = sum(1 for ref, priority in must_include.items() if priority in cited.get(ref, set()))
    return hits, len(must_include)
