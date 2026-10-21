"""Tests for the WhatsApp structure probe, on an invented store only."""

import contextlib
import io
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import whatsapp_probe  # noqa: E402

SECRET_TEXT = "Invented secret message 7731"
SECRET_JID = "61400000999@s.whatsapp.net"


def make_store(folder: Path) -> None:
    connection = sqlite3.connect(folder / "ChatStorage.sqlite")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTEXT TEXT, ZFROMJID TEXT, "
                       "ZTOJID TEXT, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZSTANZAID TEXT)")
    connection.execute("CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT)")
    rows = [
        (SECRET_TEXT, SECRET_JID, None, 0, 800000000.0, "STANZA-1"),
        ("Invented group text", "123456789@g.us", None, 0, 800086400.0, "STANZA-2"),
        ("Invented reply", None, "999@lid", 1, 800172800.0, "STANZA-3"),
    ]
    connection.executemany("INSERT INTO ZWAMESSAGE (ZTEXT, ZFROMJID, ZTOJID, ZISFROMME, ZMESSAGEDATE, ZSTANZAID) "
                           "VALUES (?, ?, ?, ?, ?, ?)", rows)
    connection.execute("INSERT INTO ZWACHATSESSION (ZCONTACTJID, ZPARTNERNAME) VALUES (?, ?)", (SECRET_JID, "Example Alex"))
    connection.commit()
    connection.close()


class WhatsAppProbeTests(unittest.TestCase):
    def run_probe(self, container: Path) -> str:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(whatsapp_probe.main(["--container", str(container)]), 0)
        return output.getvalue()

    def test_structure_counts_and_no_content(self):
        with tempfile.TemporaryDirectory() as folder:
            make_store(Path(folder))
            output = self.run_probe(Path(folder))
        self.assertIn("ChatStorage.sqlite: sqlite", output)
        self.assertIn("ZWAMESSAGE: 3 rows", output)
        self.assertIn("ZTEXT", output)  # column names are structure
        self.assertIn("'@s.whatsapp.net': 1", output)
        self.assertIn("'@lid': 1", output)
        self.assertIn("ZMESSAGEDATE: ['2026-05-09', '2026-05-11']", output)
        for secret in (SECRET_TEXT, SECRET_JID, "61400000999", "Example Alex", "STANZA-1", "Invented"):
            self.assertNotIn(secret, output)

    def test_encrypted_store_is_reported_not_read(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / "ChatStorage.sqlite").write_bytes(b"\x8a\x13 not a database" * 64)
            output = self.run_probe(Path(folder))
        self.assertIn("not plain SQLite", output)

    def test_missing_container(self):
        output = self.run_probe(Path("/nonexistent/aegis-probe-test"))
        self.assertIn("wasn't found", output)

    def test_live_files_are_not_modified(self):
        with tempfile.TemporaryDirectory() as folder:
            make_store(Path(folder))
            store = Path(folder) / "ChatStorage.sqlite"
            before = {p.name: p.read_bytes() for p in Path(folder).iterdir()}
            self.run_probe(Path(folder))
            after = {p.name: p.read_bytes() for p in Path(folder).iterdir()}
        self.assertEqual(before, after)
        self.assertTrue(store.name in before)


if __name__ == "__main__":
    unittest.main()
