"""Citation-local entity checks for synthetic briefs, without exact-summary matching.

This is a lexical rubric, not semantic entailment: role swaps and novel lower-case names
can need human review. No external name database or network is used.
"""
import re
import unicodedata
from datetime import date
from decimal import Decimal

WEEKDAYS = {day[:3]: day for day in ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")}
MONTHS = {month: n for n, month in enumerate(("january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"), 1)}
# Sentence framing/pronouns, not invented entities. Ordinary lower-case prose is unrestricted.
NAME_FRAMING = set("i you your we our they their today tomorrow yesterday this that the a an it its please reminder request message email notification invoice card payment important no nothing"
                   " multiple several some many".split())  # quantity words that start a sentence (#49)
ACTIONS = {
    "call": "call", "calls": "call", "called": "call", "calling": "call",
    "pay": "pay", "pays": "pay", "paid": "pay", "paying": "pay", "payment": "pay",
    "send": "send", "sends": "send", "sent": "send", "sending": "send",
    "forward": "forward", "forwards": "forward", "forwarded": "forward", "forwarding": "forward",
    "unlock": "unlock", "unlocks": "unlock", "unlocked": "unlock", "unlocking": "unlock",
    "delete": "delete", "deletes": "delete", "deleted": "delete", "deleting": "delete",
    "buy": "buy", "buys": "buy", "bought": "buy", "purchase": "buy", "purchased": "buy",
    "mark": "mark", "marks": "mark", "marked": "mark", "marking": "mark",
    "ignore": "ignore", "ignores": "ignore", "ignored": "ignore", "ignoring": "ignore",
    "bring": "bring", "brings": "bring", "bringing": "bring", "brought": "bring",
}
NUMBER_WORDS = {w: str(n) for n, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve".split())}
WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)?", re.UNICODE)
EMAIL = re.compile(r"[\w.+-]+@[\w.-]+\.[\w-]+", re.UNICODE)
AMOUNT = re.compile(r"(?:[$€£]|\b(?:USD|AUD|EUR|GBP)\s*)\s*\d[\d,]*(?:\.\d+)?", re.I)
NUMBER = re.compile(r"(?<!\w)\d+(?:,\d{3})*(?:\.\d+)?(?!\w)")
PHONE = re.compile(r"(?<!\w)(?:\+\d[\d ()-]{5,}\d|\d{8,})(?!\w)")
DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}(?=$|T|\W)|\b\d{1,2}/\d{1,2}/\d{4}\b|\b(?:" + "|".join(MONTHS) + r")\s+\d{1,2},?\s+\d{4}\b|\b\d{1,2}\s+(?:" + "|".join(MONTHS) + r")\s+\d{4}\b", re.I)


def normalized(text):
    return unicodedata.normalize("NFC", text).casefold()


def date_value(text):
    parts = re.findall(r"\d+|[a-z]+", text.lower())
    try:
        if "-" in text:
            year, month, day = map(int, parts)
        elif "/" in text:
            day, month, year = map(int, parts)  # documented day-first for synthetic fixtures
        elif parts[0] in MONTHS:
            month, day, year = MONTHS[parts[0]], int(parts[1]), int(parts[2])
        else:
            day, month, year = int(parts[0]), MONTHS[parts[1]], int(parts[2])
        return date(year, month, day).isoformat()
    except (ValueError, KeyError):
        return normalized(text)


def entities(text):
    """Typed tokens; handles/dates/amounts stay whole so partial matches cannot ground them."""
    facts = {kind: set() for kind in ("names", "handles", "amounts", "numbers", "weekdays", "dates", "actions")}
    remaining = unicodedata.normalize("NFC", text)
    for regex, kind, convert in (
        (DATE, "dates", date_value), (EMAIL, "handles", normalized),
        (AMOUNT, "amounts", lambda s: (re.sub(r"[\d,.\s]", "", s).casefold(), str(Decimal(re.search(r"\d[\d,.]*", s)[0].replace(",", "")).normalize()))),
        (PHONE, "handles", lambda s: "".join(c for c in s if c.isdigit())),
        (NUMBER, "numbers", lambda s: str(Decimal(s.replace(",", "")).normalize())),
    ):
        for match in regex.finditer(remaining):
            facts[kind].add(convert(match[0]))
        remaining = regex.sub(" ", remaining)
    for match in WORD.finditer(remaining):
        word = match[0].removesuffix("'s").removesuffix("’s")
        lower = normalized(word)
        if lower in NUMBER_WORDS:
            facts["numbers"].add(NUMBER_WORDS[lower])
        elif lower[:3] in WEEKDAYS and lower in (lower[:3], WEEKDAYS[lower[:3]]):
            facts["weekdays"].add(WEEKDAYS[lower[:3]])
        elif lower in MONTHS:
            facts["dates"].add(lower)
        elif word[0].isupper() and lower not in NAME_FRAMING:
            facts["names"].add(lower)
        if lower in ACTIONS:
            facts["actions"].add(ACTIONS[lower])
    return facts


def unsupported_facts(text, events):
    """Counts by entity category; grounding uses only this item's cited events."""
    wanted = entities(text)
    available = {kind: set() for kind in wanted}
    for event in events:
        # Source content and event time are evidence; labels' summaries are never evidence.
        for field in ("sender", "title", "body", "event_time"):
            facts = entities(event.get(field) or "")
            for kind in available:
                available[kind].update(facts[kind])
        if event["source"] in ("email", "imessage", "sms"):
            available["actions"].add("send")  # source record is evidence that a message was sent
        # Name matching permits ordinary capitalization, e.g. a source's lower-case 'hello'.
        available["names"].update(normalized(m[0]) for field in ("sender", "title", "body")
                                  for m in WORD.finditer(event.get(field) or ""))
    return {kind: len(values - available[kind]) for kind, values in wanted.items()}
