"""Time window and hard character limits on the complete serialized model input."""
import heapq
import json
import re
import sqlite3
import tempfile
import unicodedata
from dataclasses import dataclass
from .merge import timestamp


def one_line(text):
    return "".join(" " if unicodedata.category(c).startswith("C") or c in "\u2028\u2029" else c for c in text)


def body_literal(body):
    """JSON body on one physical line, including Unicode's extra line separators."""
    return json.dumps(body, ensure_ascii=False).replace("\u2028", "\\u2028").replace(
        "\u2029", "\\u2029").replace("\u0085", "\\u0085")


# A message that asks the owner something gets a marker, decided by this rule rather than the model (#46):
# on the fixture day it took the 4B model's recall of needs-reply items from 1 of 5 to 5 of 5.
MESSAGING_APPS = {"com.apple.mobilesms"}  # notifications that carry conversations; the trial (#19) may add more
ASKS_MARKER = " · (asks you something)"


def asks_owner(event):
    """A question from someone else in a conversation: Messages, SMS, email, or a Messages notification."""
    if event.get("sender") == "me" or "?" not in (event.get("body") or ""):
        return False
    return event["source"] in ("imessage", "sms", "email") or (event.get("app_id") or "").lower() in MESSAGING_APPS


# Collected text that gives orders to Aegis or an assistant gets its own marker, also by rule (Checkpoint A, #49):
# it is information at most, never a task and never urgent. It takes the place of the question marker.
ORDERS_MARKER = " · (gives orders to an assistant)"
_ADDRESSED = re.compile(  # "Aegis: unlock…", "assistant, forward…" at the start of a sentence
    r"(?:^|[.!?\n]\s*)(?:(?:hey|hi|dear|ok|okay)\s+)?(?:aegis|assistant|ai assistant|ai model|chatbot|language model)\s*[,:]",
    re.I)
_OVERRIDE = re.compile(  # "ignore your previous instructions", "system prompt"
    r"\b(?:ignore|disregard|forget|override)\s+(?:all\s+|any\s+)?(?:of\s+)?(?:your\s+|the\s+|these\s+|those\s+)?"
    r"(?:previous|prior|above|earlier|original|system)\s+(?:instructions|prompts?|rules)\b|\bsystem prompt\b", re.I)


def gives_orders(event):
    """Collected text addressed to Aegis or an assistant, or trying to override an assistant's instructions."""
    text = "\n".join(part for part in (event.get("title"), event.get("body")) if isinstance(part, str))
    return bool(_ADDRESSED.search(text) or _OVERRIDE.search(text))


def marker(event, answered=False):
    return ORDERS_MARKER if gives_orders(event) else ASKS_MARKER if asks_owner(event) and not answered else ""


def event_line(event, max_body, per_event, answered=False):
    line = f"[{event['id']}] {event['event_time']} · {event['source']}"
    sender = "you" if event.get("sender") == "me" else event.get("sender")  # the owner's own message, unambiguously
    for value in (["from " + one_line(sender)] if sender else []) + (
            [one_line(event["title"])] if event.get("title") and event["title"] != event.get("sender") else []):
        line += " · " + value[:per_event]
    body = event.get("body") or ""
    body = body[:max_body] + ("…" if len(body) > max_body else "")
    prefix, suffix = line + " · ", marker(event, answered)
    line = prefix + (body_literal(body) if body else f"(no text: {event['content']})") + suffix
    # Never cut a JSON literal mid-escape. Too much metadata means omit the event.
    while len(line) > per_event and body:
        body = body[:max(0, len(body) - max(1, len(line) - per_event))]
        line = prefix + body_literal(body) + suffix
    return line if len(line) <= per_event else None


def _window_lines(events, start, end, max_body, per_event):
    """Resolve later owner replies without retaining a thread map or the stream in RAM.

    The private, temporary spool stores only bounded rendered lines. Replies outside
    the window do not count; equal-time messages are not later replies. Cleanup also
    runs on errors and when the consumer closes the iterator.
    """
    with tempfile.TemporaryDirectory(prefix="aegis-input-") as folder:
        db = sqlite3.connect(folder + "/input.sqlite")
        try:
            db.executescript("""
                PRAGMA cache_size=-1024;
                PRAGMA temp_store=FILE;
                CREATE TABLE rows(id TEXT, time REAL, thread TEXT, normal TEXT, answered TEXT);
                CREATE TABLE replies(thread TEXT PRIMARY KEY, time REAL);
            """)
            for event in events:
                moment = timestamp(event["event_time"])
                if not start <= moment <= end:
                    continue
                thread = event.get("thread_id") or None
                if event.get("sender") == "me" and thread:
                    db.execute("INSERT INTO replies VALUES(?,?) ON CONFLICT(thread) DO UPDATE SET time=max(time,excluded.time)",
                               (thread, moment))
                normal = event_line(event, max_body, per_event)
                answered = event_line(event, max_body, per_event, answered=True) if asks_owner(event) else normal
                db.execute("INSERT INTO rows VALUES(?,?,?,?,?)", (event["id"], moment, thread, normal, answered))
            yield from db.execute("""
                SELECT rows.id, rows.time, CASE WHEN replies.time > rows.time THEN rows.answered ELSE rows.normal END
                FROM rows LEFT JOIN replies ON rows.thread=replies.thread
            """)
        finally:
            db.close()


@dataclass(frozen=True)
class BriefInput:
    text: str
    event_ids: list
    omitted_events: int


def build_input(events, window, max_text=12000, per_event=1000, max_events=40, max_body=280, input_order=None):
    """Newest bounded events, rendered oldest first. Omitted counts only events in the window.

    input_order optionally supplies legacy ID-to-position ranks for equal timestamps.
    Input must already be merged. Limits count Unicode characters including metadata, escaping,
    separators and the header. RAM is O(max_events * per_event), independent of stream length.
    """
    start, end = map(timestamp, window)
    if start > end or max_text < 7 or per_event < 1 or max_events < 0 or max_body < 0:
        raise ValueError("invalid input policy")
    heap, count = [], 0
    for eid, moment, line in _window_lines(events, start, end, max_body, per_event):
        count += 1
        if line is not None and max_events:
            rank = -input_order[eid] if input_order is not None else eid
            candidate = (moment, rank, eid, line)
            if len(heap) < max_events:
                heapq.heappush(heap, candidate)
            elif candidate > heap[0]:
                heapq.heapreplace(heap, candidate)
    kept, used = [], len("Events:")
    for row in sorted(heap, reverse=True):
        if used + 1 + len(row[3]) <= max_text:
            kept.append(row)
            used += 1 + len(row[3])
    kept.sort(key=lambda r: (r[0], -r[1] if input_order is not None else r[1]))
    return BriefInput("Events:" + "".join("\n" + r[3] for r in kept), [r[2] for r in kept], count - len(kept))
