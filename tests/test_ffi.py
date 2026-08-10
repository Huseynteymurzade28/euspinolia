"""Faz 0 testleri: FFI köprüsü gerçekten çalışıyor mu?

Çalıştırmak için repo kökünden:
    zig build && python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Repo kökünü import yoluna ekle ki paket kurulmadan da test edilebilsin.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import euspinolia  # noqa: E402


class TestBridge(unittest.TestCase):
    def test_self_check_gecer(self):
        euspinolia.self_check()

    def test_ping_magic_doner(self):
        self.assertEqual(euspinolia.ping(), 0xE05)

    def test_version_eslesir(self):
        self.assertEqual(euspinolia.version(), euspinolia.__version__)


class TestArgumanGecisi(unittest.TestCase):
    def test_basit_toplama(self):
        self.assertEqual(euspinolia.add(3, 4), 7)

    def test_negatif(self):
        self.assertEqual(euspinolia.add(-4, 3), -1)

    def test_i64_araligi(self):
        """32-bit'e sığmayan değerler bozulmadan gidip gelmeli.

        ctypes imzası bildirilmeseydi bu test patlardı — asıl amacı bu.
        """
        big = 2**40
        self.assertEqual(euspinolia.add(big, big), 2**41)

    def test_tasmada_sarmalar(self):
        i64_max = 2**63 - 1
        i64_min = -(2**63)
        self.assertEqual(euspinolia.add(i64_max, 1), i64_min)


if __name__ == "__main__":
    unittest.main()
