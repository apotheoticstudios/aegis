"""Tests for the synthetic fixture generator (issue #14). Everything is generated into temp folders."""

import base64
import email
import email.policy
import hashlib
import json
import os
import plistlib
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from collections import Counter
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import generate  # noqa: E402
import typedstream  # noqa: E402
from common import INJECTIONS, iso, aegis_contracts  # noqa: E402


def columns(db: Path, table: str):
    conn = sqlite3.connect(str(db))
    try:
        return [row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')]
    finally:
        conn.close()


def read_jsonl(path: Path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "a"
        cls.manifest = generate.generate(cls.out, seed=7)
        cls.expected = {name: read_jsonl(cls.out / "expected" / f"{name}.jsonl") for name in ("notifications", "messages", "mail")}
        cls.problems = json.loads((cls.out / "expected" / "problems.json").read_text())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    # Determinism -------------------------------------------------------------------------------

    def test_same_seed_gives_byte_identical_stores(self):
        other = Path(self.tmp.name) / "b"
        generate.generate(other, seed=7)
        files = sorted(p.relative_to(self.out) for p in self.out.rglob("*") if p.is_file() and not p.name.endswith(("-wal", "-shm")))
        self.assertTrue(files)
        for relative in files:
            self.assertEqual((self.out / relative).read_bytes(), (other / relative).read_bytes(), str(relative))

    def test_a_different_seed_changes_ids(self):
        other = Path(self.tmp.name) / "c"
        generate.generate(other, seed=8)
        ids = {e["source_record_id"] for e in read_jsonl(other / "expected" / "notifications.jsonl")}
        self.assertFalse(ids & {e["source_record_id"] for e in self.expected["notifications"]})

    # Layouts -----------------------------------------------------------------------------------

    def test_notification_layout_and_wal_mode(self):
        db = self.out / "notifications" / "db"
        self.assertEqual(columns(db, "app")[:2], ["app_id", "identifier"])
        self.assertEqual(
            columns(db, "record"),
            ["rec_id", "app_id", "uuid", "data", "request_date", "request_last_date", "delivered_date", "presented", "style", "snooze_fire_date"],
        )
        self.assertEqual(columns(db, "dbinfo"), ["key", "value"])
        header = db.read_bytes()[:20]
        self.assertEqual((header[18], header[19]), (2, 2), "WAL mode is recorded in the file header")

    def test_messages_layout(self):
        db = self.out / "messages" / "chat.db"
        for table, needed in {
            "message": {"guid", "text", "attributedBody", "date", "is_from_me", "handle_id", "service", "associated_message_type",
                        "associated_message_guid", "date_edited"},
            "handle": {"id", "service"},
            "chat": {"guid", "chat_identifier", "display_name"},
            "chat_message_join": {"chat_id", "message_id"},
            "chat_handle_join": {"chat_id", "handle_id"},
            "attachment": {"filename", "mime_type", "transfer_name", "total_bytes"},
            "message_attachment_join": {"message_id", "attachment_id"},
        }.items():
            self.assertTrue(needed <= set(columns(db, table)), table)

    def test_mail_layout_and_drift_profile(self):
        db = self.out / "mail" / "V10" / "MailData" / "Envelope Index"
        self.assertIn("conversation_id", columns(db, "messages"))
        for table in ("addresses", "subjects", "mailboxes", "recipients", "attachments"):
            self.assertTrue(columns(db, table), table)
        drift = Path(self.tmp.name) / "drift"
        generate.generate(drift, seed=7, profile="drift")
        self.assertNotIn("conversation_id", columns(drift / "mail" / "V10" / "MailData" / "Envelope Index", "messages"))
        self.assertTrue(all(e["thread_id"] is None for e in read_jsonl(drift / "expected" / "mail.jsonl")))

    def test_empty_profile_has_tables_but_no_events(self):
        empty = Path(self.tmp.name) / "empty"
        manifest = generate.generate(empty, seed=7, profile="empty")
        self.assertEqual(manifest["counts"], {"notifications": 0, "messages": 0, "mail": 0, "problems": 0, "duplicates": 0})
        self.assertIn("rec_id", columns(empty / "notifications" / "db", "record"))

    # Expected output ---------------------------------------------------------------------------

    def test_expected_events_follow_the_contract_and_ids_are_unique(self):
        for name, events in self.expected.items():
            for item in events:
                self.assertEqual(aegis_contracts.validate_event(item), [], f"{name}: {item['source_record_id']}")
            ids = [e["id"] for e in events]
            self.assertEqual(len(ids), len(set(ids)), name)

    def test_injections_are_plain_data_in_every_route(self):
        bodies = [e["body"] for events in self.expected.values() for e in events]
        for text in INJECTIONS:
            self.assertIn(text, bodies)

    def test_problem_codes_come_from_the_edge_case_list(self):
        known = {"bplist_parse_error", "missing_timestamp", "timestamp_out_of_range", "attributed_body_parse_error",
                 "reaction_skipped", "chat_missing", "missing_handle", "missing_guid", "emlx_framing_error",
                 "body_file_missing", "duplicate_message_id"}
        self.assertTrue({p["code"] for p in self.problems} <= known)
        self.assertEqual(len(self.problems), self.manifest["counts"]["problems"])

    def test_duplicates_point_at_expected_events(self):
        duplicates = json.loads((self.out / "expected" / "duplicates.json").read_text())
        notes = {e["id"] for e in self.expected["notifications"]}
        msgs = {e["id"] for e in self.expected["messages"]}
        self.assertEqual(len(duplicates), 2)
        for pair in duplicates:
            self.assertIn(pair["notification_event"], notes)
            self.assertIn(pair["message_event"], msgs)

    # Payloads ----------------------------------------------------------------------------------

    def test_notification_payloads_decode_except_the_corrupt_one(self):
        conn = sqlite3.connect(str(self.out / "notifications" / "db"))
        blobs = [row[0] for row in conn.execute("SELECT data FROM record")]
        conn.close()
        failures = 0
        for blob in blobs:
            try:
                value = plistlib.loads(blob)
                self.assertIn("req", value)
            except Exception:
                failures += 1
        self.assertEqual(failures, 1)

    def test_typedstream_round_trip(self):
        self.assertEqual(typedstream.extract_text(typedstream.attributed_body("hello 👋")), "hello 👋")
        long_text = "x" * 300
        self.assertEqual(typedstream.extract_text(typedstream.attributed_body(long_text)), long_text)
        self.assertIn("�", typedstream.extract_text(typedstream.attributed_body_from_bytes(b"ok \xed\xa0\x80", 4)))
        with self.assertRaises(ValueError):
            typedstream.extract_text(typedstream.corrupt())

    def test_message_bodies_match_what_a_typedstream_reader_recovers(self):
        conn = sqlite3.connect(str(self.out / "messages" / "chat.db"))
        rows = {guid: (text, blob) for guid, text, blob in conn.execute("SELECT guid, text, attributedBody FROM message")}
        conn.close()
        for item in self.expected["messages"]:
            text, blob = rows[item["source_record_id"]]
            if item["content"] == "complete":
                recovered = text if text is not None else typedstream.extract_text(blob)
                self.assertEqual(recovered, item["body"], item["source_record_id"])

    # Mail: the expected answers must be what a standard decoder recovers -------------------------

    def _emlx_files(self):
        return {p.name: p for p in (self.out / "mail").rglob("*.emlx")}

    @staticmethod
    def _decode(raw_emlx: bytes):
        count, rest = raw_emlx.split(b"\n", 1)
        message = email.message_from_bytes(rest[: int(count)], policy=email.policy.default)
        part = message.get_body(preferencelist=("plain", "html"))
        body = ""
        if part is not None and part.get_content_maintype() == "text":
            payload = part.get_payload()
            if part["Content-Transfer-Encoding"] == "base64" and isinstance(payload, str):
                raw = base64.b64decode(payload + "=" * (-len(payload.strip()) % 4))  # tolerate missing padding (edge case 6)
                body = raw.decode(part.get_content_charset() or "utf-8")
            else:
                body = part.get_content()
            if part.get_content_subtype() == "html":
                body = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", body)).strip()
        return message, body.rstrip("\n")

    def test_mail_expected_bodies_subjects_senders_and_times_decode_from_the_files(self):
        by_id = {}
        for path in self._emlx_files().values():
            raw = path.read_bytes()
            first = raw.split(b"\n", 1)[0]
            if not first.isdigit() or int(first) > len(raw):
                continue  # framing-error fixtures are problems, not events
            message, body = self._decode(raw)
            by_id[message["Message-ID"]] = (message, body)
        for item in self.expected["mail"]:
            message, body = by_id[item["source_record_id"]]
            self.assertEqual(str(message["Subject"]), item["title"], item["source_record_id"])
            self.assertEqual(str(message["From"]), item["sender"], item["source_record_id"])
            if item["content"] in ("complete", "preview"):
                self.assertEqual(body, item["body"], item["source_record_id"])
            stamp = message["Date"] or str(message["Received"]).rsplit(";", 1)[1]
            moment = parsedate_to_datetime(str(stamp))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=timezone.utc)  # "-0000": UTC, zone unknown
            self.assertEqual(iso(moment), item["event_time"], item["source_record_id"])

    def test_emlx_framing_fixtures(self):
        files = self._emlx_files()
        framing = [p for p in files.values() if not p.read_bytes().split(b"\n", 1)[0].isdigit()]
        truncated = [p for p in files.values() if p.read_bytes().split(b"\n", 1)[0].isdigit()
                     and int(p.read_bytes().split(b"\n", 1)[0]) > len(p.read_bytes())]
        self.assertEqual((len(framing), len(truncated)), (1, 1))
        self.assertEqual(len([p for p in files if p.endswith(".partial.emlx")]), 1)

    @unittest.skipUnless(os.environ.get("AEGIS_FIXTURES_HUGE"), "set AEGIS_FIXTURES_HUGE=1 to build the large profile")
    def test_huge_profile(self):
        huge = Path(self.tmp.name) / "huge"
        generate.generate(huge, seed=7, huge=True)
        conn = sqlite3.connect(str(huge / "messages" / "chat.db"))
        self.assertGreater(conn.execute("SELECT count(*) FROM message").fetchone()[0], 200_000)
        conn.close()
        self.assertGreater(max(p.stat().st_size for p in (huge / "mail").rglob("*.emlx")), 20 * 1024 * 1024)



class Stage1Tests(unittest.TestCase):
    @staticmethod
    def snapshot(root, semantic_sqlite=False):
        result = {}
        for p in root.rglob("*"):
            if not p.is_file() or p.name.endswith(("-wal", "-shm")):
                continue
            data = p.read_bytes()
            if semantic_sqlite and data.startswith(b"SQLite format 3\0"):
                # SQLite writes its library version into file headers; pin schema/rows across platforms.
                with sqlite3.connect(p) as conn:
                    data = "\n".join(conn.iterdump()).encode()
            result[str(p.relative_to(root))] = hashlib.sha256(data).hexdigest()
        return result

    def test_legacy_profiles_unchanged_for_both_seeds(self):
        # Pre-stage1 profiles, refreshed for the Aegis branding; schema/rows keep SQLite portable.
        baseline = {
            "42/drift": "d88bdbfbb97f82d7f6e91f98b784b04e27f2e9f4ff9dc3e21c787731849ff3a8",
            "42/empty": "c85aebc57086f90db1958b333c2d969e082c0f52e183237a42dfe598f906a458",
            "42/full": "446d9d3ef9af1e8d0cdde217dd0b7f99a3a97f346af83c8f94f2bd8d13264c0d",
            "7/drift": "32c312615e14892b3b409f534ca35bdb195bd075a73baf9959285ea2dc432ef9",
            "7/empty": "52b47e868f666c74dc6935f993be2884eadfc895bcc770837f83c23cbc93e13c",
            "7/full": "067e0e013d062fef5ec5bb5c35b84a971f4f1c9edebdb0e628df20ef71ee8828",
        }
        for key, digest in baseline.items():
            seed, profile = key.split("/")
            with self.subTest(key=key), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                generate.generate(root, int(seed), profile)
                actual = hashlib.sha256(json.dumps(self.snapshot(root, semantic_sqlite=True), sort_keys=True).encode()).hexdigest()
                self.assertEqual(actual, digest)

    def test_stage1_determinism_for_both_seeds(self):
        snapshots = []
        for seed in (7, 42):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as d:
                a, b = Path(d) / "a", Path(d) / "b"
                generate.generate(a, seed, "stage1")
                generate.generate(b, seed, "stage1")
                self.assertEqual(self.snapshot(a), self.snapshot(b))
                snapshots.append(self.snapshot(a))
        self.assertNotEqual(snapshots[0], snapshots[1])

    def test_stage1_records_cases_labels_and_reader_parity(self):
        # This checks label integrity only; it never runs a model or scores a candidate brief.
        sealed = json.loads((HERE.parent / "labels/stage1-heldout.json").read_text())
        for seed in (7, 42):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                manifest = generate.generate(root, seed, "stage1")
                expected = root / "expected"
                index = json.loads((expected / "stage1-index.json").read_text())
                labels = sealed["labels"]
                self.assertEqual(Counter(r["fixture_id"] for r in index), Counter(r["fixture_id"] for r in labels))
                self.assertTrue(all(n == 1 for n in Counter(r["fixture_id"] for r in labels).values()))
                # max_items 7 → 10: the owner's decision of 2026-10-10 (one item per request); the labels are unchanged.
                self.assertEqual(sealed["brief_budget"], {"max_items": 10, "max_urgent": 3, "high_priority_noise_count": 0})
                self.assertEqual(sum(r["important"] and "duplicate_of" not in r for r in labels), 8)
                for label in labels:
                    self.assertEqual(label["important"], label["priority"] in ("urgent", "reply"))
                    self.assertIsInstance(label["planted_instruction"], bool)
                    self.assertIsInstance(label["expected_speaker"], str)
                    self.assertIn(label["question_answered"], (True, False, None))
                    if label["planted_instruction"]:
                        self.assertFalse(label["important"])
                self.assertEqual(sum(r["planted_instruction"] for r in labels), 4)
                communication = {name: read_jsonl(expected / (name + ".jsonl")) for name in ("notifications", "messages", "mail")}
                all_events = [e for rows in communication.values() for e in rows]
                self.assertGreaterEqual(len(all_events), 150)
                self.assertEqual(Counter(e["id"] for e in all_events), Counter(r["event_id"] for r in index if r["source"] in communication))
                in_day = [e for e in all_events if manifest["window"]["start"] <= e["event_time"] < manifest["window"]["end"]]
                self.assertGreaterEqual(len({e["event_time"][:13] for e in in_day}), 20)
                self.assertEqual(sum(e["body"] == "Your code is 000000" for e in all_events), 30)
                for e in all_events:
                    self.assertEqual(aegis_contracts.validate_event(e), [])
                case_map = json.loads((expected / "stage1-cases.json").read_text())
                self.assertEqual(set(case_map), {str(i) for i in range(1, 39)})
                for number, coverage in case_map.items():
                    if int(number) >= 31:
                        self.assertTrue(coverage["not_expressible_in_stores"])
                        self.assertTrue(coverage["covered_in"])
                    else:
                        self.assertTrue(coverage["records"])
                        for ref in coverage["records"]:
                            locator = ref["locator"]
                            self.assertTrue((root / locator.split(":")[0]).is_file())
                contacts = json.loads((root / "contacts.json").read_text())
                phones = Counter()
                for c in contacts:
                    self.assertEqual(set(c), {"id", "displayName", "phones", "emails"})
                    self.assertTrue(c["id"] and c["displayName"].startswith("Example "))
                    for phone in c["phones"]:
                        self.assertRegex(phone, r"^\+61 400 000 \d{3}$")
                        phones[phone] += 1
                    self.assertTrue(all(re.fullmatch(r"[a-z]+@example\.com", e) for e in c["emails"]))
                self.assertEqual(phones["+61 400 000 112"], 2)
                # Independent existing readers prove the raw stores support the expected record map.
                sys.path.insert(0, str(HERE.parents[1] / "Prototype/readers"))
                from messages_reader import read_messages
                from notification_reader import read_notifications
                from mail_reader import read_mail
                now = datetime.fromisoformat(manifest["capture_time_in_expected_events"].replace("Z", "+00:00"))
                problems = json.loads((expected / "problems.json").read_text())
                for name, reader, path, sources in (
                        ("messages", read_messages, "messages/chat.db", {"sms"}),
                        ("notifications", read_notifications, "notifications/db", {"notification"}),
                        ("mail", read_mail, "mail", {"email"})):
                    result = reader(root / path, now=now)
                    self.assertTrue(result.status.ok)
                    self.assertEqual(result.events, communication[name])
                    self.assertEqual(result.problems, [p for p in problems if p["source"] in sources])
                # Invented contact handles and email domains in every source record.
                for e in all_events:
                    for phone in re.findall(r"\+\d[\d ]+", e["sender"] or ""):
                        self.assertRegex(phone.strip(), r"^\+61 400 000 \d{3}$")
                    for address in re.findall(r"[\w.-]+@[\w.-]+", json.dumps(e)):
                        self.assertTrue(address.endswith("@example.com"))
                self.check_schedule(root, index)

    def check_schedule(self, root, index):
        import stage1
        calendar = json.loads((root / "calendar.json").read_text())
        reminders = read_jsonl(root / "reminders.jsonl")
        self.assertEqual({r["id"] for r in calendar + reminders}, {r["event_id"] for r in index if r["source"] in ("calendar", "reminders")})
        for c in calendar:
            self.assertEqual(set(c), {"schema_version", "id", "item_id", "occurrence_date", "calendar_title", "title",
                                      "start", "end", "is_all_day", "time_zone", "location", "status", "capture_time"})
            self.assertEqual(c["schema_version"], "0.2")
            self.assertRegex(c["id"], r"^cal_[0-9a-f]{16}$")
            self.assertEqual(c["id"], stage1.schedule_id("cal_", c["item_id"], c["occurrence_date"]))
            # "Z" needs Python 3.11's fromisoformat; the Mac's system Python is 3.9.
            self.assertLessEqual(datetime.fromisoformat(c["start"].replace("Z", "+00:00")),
                                 datetime.fromisoformat(c["end"].replace("Z", "+00:00")))
            self.assertIsInstance(c["is_all_day"], bool)
            self.assertIn(c["status"], ("none", "confirmed", "tentative", "cancelled"))
            ZoneInfo(c["time_zone"])
        self.assertEqual(len({c["id"] for c in calendar}), len(calendar))
        dst = [datetime.fromisoformat(c["start"].replace("Z", "+00:00")).astimezone(ZoneInfo("Australia/Sydney"))
               for c in calendar if c["item_id"] == "Example-dst-series"]
        self.assertEqual([(d.month, d.day, d.hour, d.minute) for d in dst], [(4, 5, 2, 30), (10, 4, 3, 30)])
        for r in reminders:
            self.assertEqual(set(r), {"schema_version", "id", "item_id", "list_title", "title", "due", "is_completed", "completed_at", "priority", "capture_time"})
            self.assertEqual(r["schema_version"], "0.2")
            self.assertRegex(r["id"], r"^rem_[0-9a-f]{16}$")
            self.assertEqual(r["id"], stage1.schedule_id("rem_", r["item_id"]))
            self.assertEqual(set(r["due"]), {"date", "has_time", "time_zone"})
            self.assertIsInstance(r["due"]["has_time"], bool)
            self.assertIsInstance(r["is_completed"], bool)
            self.assertIn(r["priority"], range(10))
            due = datetime.fromisoformat(r["due"]["date"].replace("Z", "+00:00")).astimezone(ZoneInfo(r["due"]["time_zone"]))
            self.assertEqual((due.hour, due.minute), (0, 0))
            today = datetime.fromisoformat(r["capture_time"].replace("Z", "+00:00")).astimezone(ZoneInfo("Australia/Brisbane")).date()
            self.assertEqual(due.date(), today - timedelta(days=3) if r["item_id"] == "Example-overdue" else today)
            self.assertEqual(r["completed_at"] is None, not r["is_completed"])
        history = json.loads((root / "expected/stage1-history.json").read_text())
        old = history["standup-moved"]["previous"]
        current = next(c for c in calendar if c["id"] == history["standup-moved"]["current_id"])
        self.assertEqual(old["id"], current["id"], "a moved occurrence keeps its ID")
        self.assertNotEqual(old["start"], current["start"])
        self.assertEqual(current["occurrence_date"], old["start"])
        self.assertTrue(history["uncompleted"]["previous"]["is_completed"])
        self.assertFalse(next(r for r in reminders if r["item_id"] == "Example-uncompleted")["is_completed"])

if __name__ == "__main__":
    unittest.main()
