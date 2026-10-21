"""Aegis Stage 0 data contracts (issue #9): load the schemas, validate events and briefs.

Python standard library only. The validator covers the JSON Schema keywords the two schemas use
(type, const, enum, required, properties, additionalProperties, items, minItems, uniqueItems,
minLength, pattern, minimum, format: date-time); it is not a general JSON Schema implementation.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List

HERE = Path(__file__).resolve().parent
# Which capture routes can produce each source's own record.
SOURCE_ROUTES = {
    "notification": {"notification_db", "accessibility"},
    "imessage": {"chat_db"},
    "sms": {"chat_db"},
    "email": {"mail_store"},
}
_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def load_schema(name: str) -> Dict[str, Any]:
    """`name` is "event" or "brief"."""
    return json.loads((HERE / f"{name}.schema.json").read_text(encoding="utf-8"))


def event_id(source: str, source_record_id: str) -> str:
    """Stable event ID from the source and its own record ID (never a ROWID alone)."""
    digest = hashlib.sha256(f"{source}\x1f{source_record_id}".encode("utf-8")).hexdigest()
    return "ev_" + digest[:16]


def validate(instance: Any, schema: Dict[str, Any], path: str = "") -> List[str]:
    """Errors as "path: message" strings; an empty list means valid."""
    errors: List[str] = []
    where = path or "/"

    if "type" in schema:
        allowed = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(instance, t) for t in allowed):
            return [f"{where}: expected {' or '.join(allowed)}, got {type(instance).__name__}"]
    if "const" in schema and instance != schema["const"]:
        errors.append(f"{where}: must be {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{where}: {instance!r} is not one of {schema['enum']}")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            errors.append(f"{where}: shorter than {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{where}: does not match {schema['pattern']}")
        if schema.get("format") == "date-time" and not _is_datetime(instance):
            errors.append(f"{where}: not a date-time")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{where}: below {schema['minimum']}")

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{where}: missing {key!r}")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if key in properties:
                errors.extend(validate(value, properties[key], f"{path}/{key}"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{where}: unexpected field {key!r}")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            errors.append(f"{where}: needs at least {schema['minItems']} item(s)")
        if schema.get("uniqueItems"):
            seen = [json.dumps(item, sort_keys=True) for item in instance]
            if len(seen) != len(set(seen)):
                errors.append(f"{where}: items must be unique")
        if "items" in schema:
            for index, item in enumerate(instance):
                errors.extend(validate(item, schema["items"], f"{path}/{index}"))
    return errors


def validate_event(event: Dict[str, Any]) -> List[str]:
    """Schema errors plus two rules: `id` equals event_id(source, source_record_id), and one
    observation is the event's own source record (merged duplicates add the others)."""
    errors = validate(event, load_schema("event"))
    if errors:
        return errors
    if event["id"] != event_id(event["source"], event["source_record_id"]):
        errors.append("/id: does not match event_id(source, source_record_id)")
    routes = SOURCE_ROUTES[event["source"]]
    if not any(
        o["source_record_id"] == event["source_record_id"] and o["route"] in routes for o in event["observations"]
    ):
        errors.append("/observations: none is the event's own source record from a matching route")
    return errors


def validate_brief(brief: Dict[str, Any], events: Iterable[Dict[str, Any]]) -> List[str]:
    """Schema errors plus: every cited event exists, and the window runs forwards."""
    errors = validate(brief, load_schema("brief"))
    if errors:
        return errors
    known = {event["id"] for event in events}
    for index, item in enumerate(brief["items"]):
        for ref in item["event_ids"]:
            if ref not in known:
                errors.append(f"/items/{index}/event_ids: unknown event {ref}")
    if _parse(brief["window_start"]) > _parse(brief["window_end"]):
        errors.append("/window_start: after window_end")
    return errors


def read_jsonl(path: Path) -> List[Dict[str, Any]]:
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def _is_type(value: Any, name: str) -> bool:
    if name in ("integer", "number") and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[name])


def _parse(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def _is_datetime(text: str) -> bool:
    try:
        return _parse(text).tzinfo is not None
    except ValueError:
        return False
