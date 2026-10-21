"""Synthetic guard regressions: python3 -m unittest discover -s scripts/tests -v."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PrivacyGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.env = dict(os.environ)
        self.env.pop("BASE_REF", None)
        self.git("init", "-q")
        self.git("config", "user.email", "synthetic@example.invalid")
        self.git("config", "user.name", "Synthetic Guard Test")
        (self.repo / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/privacy-guard.sh", self.repo / "scripts/privacy-guard.sh")
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic baseline")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, env=self.env,
                       check=True, capture_output=True, text=True)

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def guard(self, expected, *args):
        result = subprocess.run(["bash", "scripts/privacy-guard.sh", *args],
                                cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("grep:", result.stderr)
        return result.stdout

    def test_database_and_mail_files(self):
        for suffix in (".db", ".sqlite", ".sqlite3", ".emlx", "-wal", "-shm"):
            with self.subTest(suffix=suffix):
                name = "Fixtures/fake" + suffix
                self.write(name, "synthetic data only\n")
                self.guard(1)  # Untracked local files.
                self.git("add", "-f", name)
                self.guard(1, "--staged")
                self.git("commit", "-qm", "Synthetic forbidden file")
                self.assertIn(name, self.guard(1, "--all"))
                self.git("rm", "-q", name)
                self.git("commit", "-qm", "Remove synthetic file")

    def test_python_network_imports(self):
        imports = [
            "import requests", "from requests import get", "import urllib.request",
            "from urllib import request", "import http.client", "from http.client import HTTPConnection",
            "from http import client", "import httpx", "import socket", "import aiohttp",
            "import os, requests as client", "    import requests", "import os; import socket",
        ]
        for code in imports:
            with self.subTest(code=code):
                self.write("Prototype/nested/probe.py", code + "\n")
                self.assertIn("Prototype/nested/probe.py", self.guard(1))
                self.write("Prototype/nested/probe.py", code + "  # privacy-guard: allow-network synthetic test\n")
                self.guard(0)

    def test_javascript_network_apis(self):
        for code in ("fetch('synthetic')", "fetch ('synthetic')", "new XMLHttpRequest()",
                     "require('http')", 'require("https")', "require ( 'net' )", "axios.get('synthetic')"):
            with self.subTest(code=code):
                self.write("Prototype/nested/probe.js", code + "\n")
                self.guard(1)
                self.write("Prototype/nested/probe.js", code + " // privacy-guard: allow-network synthetic test\n")
                self.guard(0)

    def test_python_fetch_and_prototype_real_paths_are_allowed(self):
        self.write("Prototype/probe.py", 'def fetch():\n    return "Library/Messages"\nfetch()\nimport requests_cache\n')  # privacy-guard: allow-real-path synthetic guard input only
        self.write("Prototype/probe.js", 'const path = "Library/Messages";\n')  # privacy-guard: allow-real-path synthetic guard input only
        self.guard(0)

    def test_swift_network_and_real_path_checks_remain(self):
        self.write("Apps/probe.swift", "let session = URLSession.shared\n")
        self.guard(1)
        self.write("Apps/probe.swift", "let session = URLSession.shared // privacy-guard: allow-network synthetic test\n")
        self.guard(0)
        self.write("Apps/probe.swift", 'let path = "Library/Messages"\n')  # privacy-guard: allow-real-path synthetic guard input only
        self.guard(1)

    def test_current_repository_passes(self):
        result = subprocess.run(["bash", "scripts/privacy-guard.sh", "--all"], cwd=ROOT,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
