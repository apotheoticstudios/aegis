"""Tests for the trial runner (issue #42). Fake data only; the model step is stubbed, so CI needs no MLX."""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "Fixtures" / "generate"))
import generate  # noqa: E402
import run_day  # noqa: E402
from run_day import aegis_contracts  # noqa: E402

FAKE_NUMBERS = {"load_s": 1.5, "first_token_s": 4.0, "generate_s": 30.0, "generation_tps": 20.0, "prompt_tokens": 900,
                "peak_footprint_gb": 3.8, "swap_growth_mb": 0.0, "available_before_gb": 6.0, "available_after_exit_gb": 6.1,
                "seconds_waited_after_exit": 5.0}
SUMMARY = "Invoice 1043 ($1,250.00) is due Friday."


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="aegis-trial-test-")
        self.addCleanup(self.tmp.cleanup)
        self.fixtures = Path(self.tmp.name) / "fixtures"
        generate.generate(self.fixtures, seed=7)
        self.out = Path(self.tmp.name) / "out"
        self.invoice = aegis_contracts.event_id("email", "<invoice-1043@example.com>")

    def run_trial(self, answer: str):
        printed = io.StringIO()
        with mock.patch.object(run_day.benchmark, "model_path", return_value="/models/fake"), \
                mock.patch.object(run_day.benchmark, "run_once", return_value=dict(FAKE_NUMBERS, text=answer)) as run_once, \
                redirect_stdout(printed):
            code = run_day.main(["--fixtures", str(self.fixtures), "--out", str(self.out)])
        return code, printed.getvalue(), run_once

    def expected_texts(self):
        rows = []
        for name in ("notifications.jsonl", "messages.jsonl", "mail.jsonl"):
            rows += [json.loads(line) for line in (self.fixtures / "expected" / name).read_text(encoding="utf-8").splitlines()]
        # "Aegis" is a fixture notification's title and also the product's name in the runner's own output.
        return {text for e in rows for text in (e["body"], e["title"], e["sender"]) if text and len(text) > 3} - {"Aegis"}

    def test_a_day_runs_end_to_end_with_numbers_only_on_screen(self):
        answer = json.dumps({"items": [{"text": SUMMARY, "priority": "urgent", "event_ids": [self.invoice]}]})
        code, printed, run_once = self.run_trial(answer)
        self.assertEqual(code, 0, printed)
        model_input = run_once.call_args[0][2]
        self.assertIn(f"[{self.invoice}]", model_input)  # the invoice reached the model
        self.assertRegex(printed, r"notifications\s+ok\s+events \d+")
        self.assertRegex(printed, r"mail\s+ok\s+events \d+")
        self.assertIn("merged 2 duplicates", printed)  # the fixture's two notification/Messages twins
        self.assertIn("brief valid", printed)
        leaked = [text for text in self.expected_texts() | {SUMMARY} if text in printed]
        self.assertEqual(leaked, [], "the terminal must never show message text")

        folder = next(self.out.iterdir())
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        for name in ("brief.md", "brief.json", "input.txt", "run.json"):
            self.assertEqual((folder / name).stat().st_mode & 0o777, 0o600, name)
        brief = json.loads((folder / "brief.json").read_text(encoding="utf-8"))
        self.assertEqual(brief["items"][0]["event_ids"], [self.invoice])
        page = (folder / "brief.md").read_text(encoding="utf-8")
        self.assertIn(SUMMARY, page)
        self.assertIn("invoice 1043", page.lower())  # the cited email, for checking facts
        self.assertIn("## Your score", page)
        numbers = json.loads((folder / "run.json").read_text(encoding="utf-8"))
        self.assertNotIn("text", numbers["model"])
        self.assertEqual((numbers["duplicates_merged"], numbers["brief_valid"]), (2, True))
        self.assertFalse([text for text in self.expected_texts() | {SUMMARY} if text in json.dumps(numbers, ensure_ascii=False)])

    def test_unusable_answer_fails_cleanly(self):
        code, printed, _ = self.run_trial("Sorry, I can't do that.")
        self.assertEqual(code, 1)
        self.assertIn("brief invalid", printed)
        folder = next(self.out.iterdir())
        self.assertFalse((folder / "brief.md").exists())
        self.assertTrue((folder / "run.json").exists())

    def test_a_citation_outside_the_input_is_invalid(self):
        answer = json.dumps({"items": [{"text": "Something", "priority": "fyi", "event_ids": ["ev_0000000000000000"]}]})
        code, printed, _ = self.run_trial(answer)
        self.assertEqual(code, 1)
        self.assertIn("brief invalid", printed)


if __name__ == "__main__":
    unittest.main()
