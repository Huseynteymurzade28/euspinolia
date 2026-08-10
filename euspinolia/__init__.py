"""euspinolia — Zig hızlandırmalı mini tablo/CSV işleme kütüphanesi.

Faz 0: sadece FFI köprüsünün doğrulaması. Gerçek API (read_csv, DataFrame)
sonraki fazlarda gelecek.
"""

from __future__ import annotations

from ._ffi import EXPECTED_MAGIC, EXPECTED_VERSION, LibraryNotFoundError, lib

__all__ = ["ping", "add", "version", "self_check", "LibraryNotFoundError", "__version__"]

__version__ = EXPECTED_VERSION


def ping() -> int:
    """Zig tarafındaki sabit imza değerini döner (`EXPECTED_MAGIC`)."""
    return lib.eus_ping()


def add(a: int, b: int) -> int:
    """İki tam sayıyı Zig tarafında toplar. i64 aralığında sarmalar."""
    return lib.eus_add(a, b)


def version() -> str:
    """Yüklenmiş Zig kütüphanesinin bildirdiği sürüm."""
    return lib.eus_version().decode("utf-8")


def self_check() -> None:
    """Köprünün sağlığını doğrula; bir şey tutmazsa `RuntimeError` fırlat.

    Yanlış ya da eski bir .so yüklenmişse bunu erken yakalamak için.
    """
    magic = ping()
    if magic != EXPECTED_MAGIC:
        raise RuntimeError(
            f"eus_ping beklenmeyen değer döndü: {magic:#x} "
            f"(beklenen {EXPECTED_MAGIC:#x}). Eski bir kütüphane yüklenmiş olabilir."
        )

    lib_version = version()
    if lib_version != EXPECTED_VERSION:
        raise RuntimeError(
            f"Sürüm uyuşmazlığı: kütüphane {lib_version!r}, "
            f"Python katmanı {EXPECTED_VERSION!r} bekliyor. `zig build` çalıştırın."
        )
