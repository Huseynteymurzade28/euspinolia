"""Phase 0 tests: does the FFI bridge actually work?

Run from the repo root:
    zig build && python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Allow importing the package without installing it.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import euspinolia  # noqa: E402


class TestBridge(unittest.TestCase):
    def test_self_check_passes(self):
        euspinolia.self_check()

    def test_ping_returns_magic(self):
        self.assertEqual(euspinolia.ping(), 0xE05)

    def test_version_matches(self):
        self.assertEqual(euspinolia.version(), euspinolia.__version__)


class TestArgumentPassing(unittest.TestCase):
    def test_basic_addition(self):
        self.assertEqual(euspinolia.add(3, 4), 7)

    def test_negative_operands(self):
        self.assertEqual(euspinolia.add(-4, 3), -1)

    def test_i64_range(self):
        """Values beyond 32 bits must survive the round trip.

        This fails if the ctypes signatures are not declared.
        """
        big = 2**40
        self.assertEqual(euspinolia.add(big, big), 2**41)

    def test_wraps_on_overflow(self):
        self.assertEqual(euspinolia.add(2**63 - 1, 1), -(2**63))


if __name__ == "__main__":
    unittest.main()
