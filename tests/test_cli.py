"""The `euspinolia` command line.

Run from the repo root:
    zig build && python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import euspinolia  # noqa: E402
from euspinolia.__main__ import main  # noqa: E402

SAMPLE = 'name,age,score\nada,36,91.5\ngrace,45,88.0\n"Doe, John",29,73.25\nada,50,60.0\n'


def run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = main(list(argv))
        except SystemExit as exit:
            code = exit.code if isinstance(exit.code, int) else 1
    return code, out.getvalue(), err.getvalue()


class TestCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "people.csv"
        self.path.write_text(SAMPLE, encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_stats(self):
        code, out, _ = run("stats", str(self.path))
        self.assertEqual(code, 0)
        self.assertIn("4 rows x 3 columns", out)
        lines = {line.split()[0]: line.split() for line in out.splitlines()[3:]}
        self.assertEqual(lines["name"], ["name", "string", "3"])
        self.assertEqual(lines["age"], ["age", "int", "29", "50", "40.0", "4"])
        self.assertEqual(lines["score"], ["score", "float", "60.0", "91.5", "78.188", "4"])

    def test_stats_on_a_header_only_file(self):
        self.path.write_text("a,b\n", encoding="utf-8")
        code, out, _ = run("stats", str(self.path))
        self.assertEqual(code, 0)
        self.assertIn("0 rows x 2 columns", out)

    def test_head(self):
        code, out, _ = run("head", str(self.path), "-n", "2")
        self.assertEqual(code, 0)
        self.assertIn("grace", out)
        self.assertNotIn("Doe, John", out)
        self.assertIn("... (2 more rows)", out)

    def test_delimiter(self):
        self.path.write_text("a\tb\n1\tx,y\n", encoding="utf-8")
        for spelling in ("\t", "\\t", "tab"):
            code, out, _ = run("head", str(self.path), "--delimiter", spelling)
            self.assertEqual(code, 0)
            self.assertIn("x,y", out)

    def test_errors_go_to_stderr(self):
        code, out, err = run("stats", str(Path(self.tmp.name) / "missing.csv"))
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        # Windows/ARM64 reads the file in Python, so the wording is Python's there.
        self.assertIn("no such file", err.lower())
        self.assertIn("missing.csv", err)

        self.path.write_text("a,b\n1,2,3\n", encoding="utf-8")
        code, _, err = run("head", str(self.path))
        self.assertEqual(code, 1)
        self.assertIn("field count", err)

    def test_version(self):
        code, out, _ = run("--version")
        self.assertEqual(code, 0)
        self.assertIn(euspinolia.__version__, out)

    def test_a_command_is_required(self):
        code, _, err = run()
        self.assertEqual(code, 2)
        self.assertIn("usage", err)


if __name__ == "__main__":
    unittest.main()
