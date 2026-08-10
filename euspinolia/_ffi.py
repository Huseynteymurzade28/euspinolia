"""Zig paylaşımlı kütüphanesini bulup ctypes ile yükleyen katman.

Bu modül tek sorumluluğu olan bir yer: kütüphaneyi bul, yükle, fonksiyon
imzalarını (argtypes/restype) tanımla. Üst katman (`euspinolia/__init__.py`)
buradaki `lib` nesnesini kullanır, dosya arama derdiyle uğraşmaz.
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path

# Zig tarafındaki `version_string` ile aynı olmalı.
EXPECTED_VERSION = "0.0.1"

# Zig tarafındaki `magic` sabiti ile aynı olmalı.
EXPECTED_MAGIC = 0xE05


class LibraryNotFoundError(RuntimeError):
    """Paylaşımlı kütüphane hiçbir arama yolunda bulunamadı."""


def _library_filename() -> str:
    """Platforma göre paylaşımlı kütüphane dosya adı."""
    if sys.platform == "win32":
        return "euspinolia.dll"
    if sys.platform == "darwin":
        return "libeuspinolia.dylib"
    return "libeuspinolia.so"


def _candidate_paths() -> list[Path]:
    """Kütüphanenin aranacağı yollar, öncelik sırasıyla."""
    filename = _library_filename()
    candidates: list[Path] = []

    # 1. Açık override — geliştirme sırasında ve testlerde en kullanışlısı.
    override = os.environ.get("EUSPINOLIA_LIB")
    if override:
        candidates.append(Path(override))

    package_dir = Path(__file__).resolve().parent
    repo_root = package_dir.parent

    # 2. `zig build` çıktısı (repo içinden çalıştırıldığında normal durum).
    candidates.append(repo_root / "zig-out" / "lib" / filename)

    # 3. Paketin yanına kopyalanmış hali (ileride paketleme yapıldığında).
    candidates.append(package_dir / filename)

    return candidates


def _load() -> ctypes.CDLL:
    tried: list[str] = []
    for path in _candidate_paths():
        if path.is_file():
            return ctypes.CDLL(str(path))
        tried.append(str(path))

    raise LibraryNotFoundError(
        "euspinolia paylaşımlı kütüphanesi bulunamadı.\n"
        "Repo kökünde `zig build` çalıştırın ya da EUSPINOLIA_LIB "
        "ortam değişkeniyle yolu verin.\n"
        "Denenen yollar:\n  " + "\n  ".join(tried)
    )


def _declare_signatures(lib: ctypes.CDLL) -> None:
    """C imzalarını ctypes'a bildir.

    Bu adım opsiyonel değil: imza bildirilmezse ctypes tüm argümanları
    ve dönüş değerini `int` (C int, 32-bit) varsayar; i64 değerler ve
    pointer dönüşleri sessizce bozulur.
    """
    lib.eus_ping.argtypes = []
    lib.eus_ping.restype = ctypes.c_int32

    lib.eus_add.argtypes = [ctypes.c_int64, ctypes.c_int64]
    lib.eus_add.restype = ctypes.c_int64

    lib.eus_version.argtypes = []
    lib.eus_version.restype = ctypes.c_char_p


lib = _load()
_declare_signatures(lib)
