"""Locates and loads the Zig shared library, and declares its C signatures."""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path

# Must stay in sync with src/root.zig.
EXPECTED_VERSION = "0.0.1"
EXPECTED_MAGIC = 0xE05


class LibraryNotFoundError(RuntimeError):
    """The shared library was not found in any search path."""


def _library_filename() -> str:
    if sys.platform == "win32":
        return "euspinolia.dll"
    if sys.platform == "darwin":
        return "libeuspinolia.dylib"
    return "libeuspinolia.so"


def _candidate_paths() -> list[Path]:
    filename = _library_filename()
    package_dir = Path(__file__).resolve().parent
    candidates: list[Path] = []

    override = os.environ.get("EUSPINOLIA_LIB")
    if override:
        candidates.append(Path(override))

    candidates.append(package_dir.parent / "zig-out" / "lib" / filename)
    candidates.append(package_dir / filename)
    return candidates


def _load() -> ctypes.CDLL:
    tried: list[str] = []
    for path in _candidate_paths():
        if path.is_file():
            return ctypes.CDLL(str(path))
        tried.append(str(path))

    raise LibraryNotFoundError(
        "euspinolia shared library not found.\n"
        "Run `zig build` in the repo root, or point EUSPINOLIA_LIB at it.\n"
        "Tried:\n  " + "\n  ".join(tried)
    )


def _declare_signatures(lib: ctypes.CDLL) -> None:
    # Without these, ctypes assumes C int (32-bit) everywhere and silently
    # truncates i64 values and pointer returns.
    lib.eus_ping.argtypes = []
    lib.eus_ping.restype = ctypes.c_int32

    lib.eus_add.argtypes = [ctypes.c_int64, ctypes.c_int64]
    lib.eus_add.restype = ctypes.c_int64

    lib.eus_version.argtypes = []
    lib.eus_version.restype = ctypes.c_char_p


lib = _load()
_declare_signatures(lib)
