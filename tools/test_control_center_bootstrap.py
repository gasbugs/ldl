"""Catch missing Control Center DOM targets before browser JavaScript starts."""

from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROL_CENTER = ROOT / "llm-security-control-plane" / "guided-control-center"
HTML = (CONTROL_CENTER / "index.html").read_text()
JAVASCRIPT_PATH = CONTROL_CENTER / "app.js"
JAVASCRIPT = JAVASCRIPT_PATH.read_text()
HTML_IDS = set(re.findall(r'\bid=["\']([^"\']+)', HTML))


class ControlCenterBootstrapTest(unittest.TestCase):
    def test_complete_javascript_parses(self):
        subprocess.run(["node", "--check", JAVASCRIPT_PATH], check=True)

    def test_literal_event_targets_exist(self):
        targets = set(
            re.findall(r'''byId\(["']([^"']+)["']\)\.addEventListener''', JAVASCRIPT)
        )
        self.assertEqual(set(), targets - HTML_IDS)

    def test_numbered_verify_targets_exist(self):
        match = re.search(
            r"for \(const number of \[([0-9, ]+)\]\) "
            r"byId\(`h\$\{number\}-verify`\)\.addEventListener",
            JAVASCRIPT,
        )
        self.assertIsNotNone(match)
        numbers = [int(value.strip()) for value in match.group(1).split(",")]
        self.assertEqual([], [number for number in numbers if f"h{number}-verify" not in HTML_IDS])
        self.assertNotIn(16, numbers)


if __name__ == "__main__":
    unittest.main()
