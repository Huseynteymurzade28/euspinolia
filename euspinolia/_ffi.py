"""Locates and loads the Zig shared library, and declares its C signatures."""

from __future__ import annotations

import ctypes
import enum
import os
import sys
from pathlib import Path

# Must stay in sync with src/root.zig.
EXPECTED_VERSION = "0.1.1"
EXPECTED_MAGIC = 0xE05


class LibraryNotFoundError(RuntimeError):
    """The shared library was not found in any search path."""


class ParseError(ValueError):
    """The input is not CSV this library can read."""


class ColumnType(enum.IntEnum):
    """Element type of a column.

    The values are the `dtype.ColumnType` tag numbers and are part of the ABI;
    src/ffi.zig has a test pinning them.
    """

    INT = 0
    FLOAT = 1
    STRING = 2

    def __str__(self) -> str:
        return self.name.lower()


class Status(enum.IntEnum):
    """Status codes returned by the fallible C functions. See src/ffi.zig."""

    OK = 0
    OUT_OF_MEMORY = 1
    FILE_NOT_FOUND = 2
    ACCESS_DENIED = 3
    IS_A_DIRECTORY = 4
    IO_FAILED = 5
    FILE_TOO_LARGE = 6
    UNTERMINATED_QUOTE = 7
    UNEXPECTED_CHARACTER_AFTER_QUOTE = 8
    INCONSISTENT_FIELD_COUNT = 9
    MISSING_HEADER = 10
    INVALID_NUMBER = 11
    COLUMN_OUT_OF_RANGE = 12
    NOT_NUMERIC = 13
    EMPTY_COLUMN = 14
    SUM_OVERFLOW = 15
    TYPE_MISMATCH = 16
    INVALID_OPERATOR = 17
    INVALID_AGGREGATE = 18
    UNKNOWN = 99


# Which Python exception each status deserves. Anything absent is a ParseError:
# the remaining codes all describe malformed input.
_STATUS_EXCEPTIONS: dict[int, type[Exception]] = {
    Status.OUT_OF_MEMORY: MemoryError,
    Status.FILE_NOT_FOUND: FileNotFoundError,
    Status.ACCESS_DENIED: PermissionError,
    Status.IS_A_DIRECTORY: IsADirectoryError,
    Status.IO_FAILED: OSError,
    Status.FILE_TOO_LARGE: OSError,
    Status.COLUMN_OUT_OF_RANGE: IndexError,
    Status.NOT_NUMERIC: TypeError,
    Status.EMPTY_COLUMN: ValueError,
    Status.SUM_OVERFLOW: OverflowError,
    Status.TYPE_MISMATCH: TypeError,
    Status.INVALID_OPERATOR: ValueError,
    Status.INVALID_AGGREGATE: ValueError,
}


def check(code: int, source: str | None = None) -> None:
    """Raise the Python exception matching a status code. `Status.OK` is a no-op."""
    if code == Status.OK:
        return

    message = lib.eus_status_message(code).decode("utf-8")
    if source is not None:
        message = f"{message}: {source}"

    raise _STATUS_EXCEPTIONS.get(code, ParseError)(message)


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

    # A repo checkout after `zig build` (Windows puts DLLs under bin/), then
    # the copy an installed wheel ships inside the package.
    zig_out = package_dir.parent / "zig-out"
    candidates.append(zig_out / "lib" / filename)
    if sys.platform == "win32":
        candidates.append(zig_out / "bin" / filename)
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

    lib.eus_status_message.argtypes = [ctypes.c_int32]
    lib.eus_status_message.restype = ctypes.c_char_p

    # Frames cross as opaque pointers; the result comes back through an
    # out-parameter so the return value can stay a status code.
    lib.eus_read_csv.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p)]
    lib.eus_read_csv.restype = ctypes.c_int32

    lib.eus_parse_csv.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p)]
    lib.eus_parse_csv.restype = ctypes.c_int32

    lib.eus_frame_free.argtypes = [ctypes.c_void_p]
    lib.eus_frame_free.restype = None

    lib.eus_frame_rows.argtypes = [ctypes.c_void_p]
    lib.eus_frame_rows.restype = ctypes.c_size_t

    lib.eus_frame_columns.argtypes = [ctypes.c_void_p]
    lib.eus_frame_columns.restype = ctypes.c_size_t

    lib.eus_frame_column_type.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.eus_frame_column_type.restype = ctypes.c_int32

    lib.eus_frame_column_name.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.eus_frame_column_name.restype = ctypes.c_void_p

    lib.eus_frame_column_index.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.eus_frame_column_index.restype = ctypes.c_ssize_t

    # Borrowed pointers into the frame's arena. Declared as void* so the
    # address arrives as a plain int, which is what ctypes array views want.
    for name in ("eus_frame_ints", "eus_frame_floats", "eus_frame_string_offsets"):
        function = getattr(lib, name)
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_void_p

    lib.eus_frame_string_data.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.eus_frame_string_data.restype = ctypes.c_void_p

    # Reductions keep the column's type, so they write through whichever
    # out-parameter matches it — the caller knows which one to read.
    for name in ("eus_column_sum", "eus_column_min", "eus_column_max"):
        function = getattr(lib, name)
        function.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_int64),
            ctypes.POINTER(ctypes.c_double),
        ]
        function.restype = ctypes.c_int32

    lib.eus_column_mean.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_double),
    ]
    lib.eus_column_mean.restype = ctypes.c_int32

    # Filters produce a new frame, delivered the same way parsing does. One
    # entry point per value type, so no argument has to be a union.
    frame_out = ctypes.POINTER(ctypes.c_void_p)
    lib.eus_frame_filter_int.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint8,
        ctypes.c_int64,
        frame_out,
    ]
    lib.eus_frame_filter_int.restype = ctypes.c_int32

    lib.eus_frame_filter_float.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint8,
        ctypes.c_double,
        frame_out,
    ]
    lib.eus_frame_filter_float.restype = ctypes.c_int32

    lib.eus_frame_filter_string.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint8,
        ctypes.c_char_p,
        ctypes.c_size_t,
        frame_out,
    ]
    lib.eus_frame_filter_string.restype = ctypes.c_int32

    # One output column per (column, function) pair, passed as two parallel
    # arrays so the call count stays at one whatever the number of specs.
    lib.eus_frame_groupby.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        frame_out,
    ]
    lib.eus_frame_groupby.restype = ctypes.c_int32

    lib.eus_frame_to_csv.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.eus_frame_to_csv.restype = ctypes.c_int32

    lib.eus_bytes_free.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.eus_bytes_free.restype = None


lib = _load()
_declare_signatures(lib)
