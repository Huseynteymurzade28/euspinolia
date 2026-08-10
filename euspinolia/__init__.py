"""euspinolia — a small Zig-accelerated table/CSV processing library.

Phase 0 only verifies the FFI bridge; the real API (read_csv, DataFrame)
arrives in later phases.
"""

from __future__ import annotations

from ._ffi import EXPECTED_MAGIC, EXPECTED_VERSION, LibraryNotFoundError, lib

__all__ = ["ping", "add", "version", "self_check", "LibraryNotFoundError", "__version__"]

__version__ = EXPECTED_VERSION


def ping() -> int:
    """Return the constant signature value from the Zig side."""
    return lib.eus_ping()


def add(a: int, b: int) -> int:
    """Add two integers in Zig. Wraps within the i64 range."""
    return lib.eus_add(a, b)


def version() -> str:
    """Return the version reported by the loaded Zig library."""
    return lib.eus_version().decode("utf-8")


def self_check() -> None:
    """Raise RuntimeError if the loaded library is stale or mismatched."""
    magic = ping()
    if magic != EXPECTED_MAGIC:
        raise RuntimeError(
            f"eus_ping returned {magic:#x}, expected {EXPECTED_MAGIC:#x}. "
            "A stale library may be loaded."
        )

    lib_version = version()
    if lib_version != EXPECTED_VERSION:
        raise RuntimeError(
            f"Version mismatch: library reports {lib_version!r}, "
            f"Python layer expects {EXPECTED_VERSION!r}. Run `zig build`."
        )
