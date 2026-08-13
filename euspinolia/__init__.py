"""euspinolia — a small Zig-accelerated table/CSV processing library.

    >>> import euspinolia
    >>> df = euspinolia.read_csv("people.csv")
    >>> df.shape
    (3, 4)
    >>> df["age"].to_list()
    [36, 45, 29]
"""

from __future__ import annotations

import ctypes
import os
from typing import Any, Iterator

from ._ffi import (
    EXPECTED_MAGIC,
    EXPECTED_VERSION,
    ColumnType,
    LibraryNotFoundError,
    ParseError,
    check,
    lib,
)

__all__ = [
    "read_csv",
    "parse_csv",
    "DataFrame",
    "Column",
    "ColumnType",
    "ParseError",
    "LibraryNotFoundError",
    "ping",
    "add",
    "version",
    "self_check",
    "__version__",
]

__version__ = EXPECTED_VERSION


def read_csv(path: str | os.PathLike[str]) -> DataFrame:
    """Parse a CSV file into a `DataFrame`.

    The file is read and parsed entirely on the Zig side; Python only ever
    sees the resulting columns.
    """
    handle = ctypes.c_void_p()
    encoded = os.fsencode(path)
    check(lib.eus_read_csv(encoded, len(encoded), ctypes.byref(handle)), source=os.fspath(path))
    return DataFrame(handle.value)


def parse_csv(text: str | bytes) -> DataFrame:
    """Parse CSV text already in memory into a `DataFrame`."""
    encoded = text.encode("utf-8") if isinstance(text, str) else text
    handle = ctypes.c_void_p()
    check(lib.eus_parse_csv(encoded, len(encoded), ctypes.byref(handle)))
    return DataFrame(handle.value)


class Column:
    """One column of a `DataFrame`, read straight out of the Zig buffers.

    Numeric columns are a view: indexing reads the Zig-side array in place,
    with no copy. Strings are decoded on access from the packed byte buffer.

    A column keeps its frame alive, so it stays valid even if you drop every
    other reference to the `DataFrame` — but not past an explicit `close()`.
    """

    __slots__ = ("_frame", "_index", "_name", "_dtype", "_values", "_offsets", "_data")

    def __init__(self, frame: DataFrame, index: int) -> None:
        self._frame = frame
        self._index = index
        self._name = frame.columns[index]
        self._dtype = frame.dtypes[index]

        handle = frame._require_open()
        rows = len(frame)

        self._values: Any = None
        self._offsets: Any = None
        self._data: Any = None

        if self._dtype is ColumnType.STRING:
            offsets = lib.eus_frame_string_offsets(handle, index)
            length = ctypes.c_size_t()
            data = lib.eus_frame_string_data(handle, index, ctypes.byref(length))
            self._offsets = (ctypes.c_size_t * (rows + 1)).from_address(offsets)
            # An all-empty column may hand back a null pointer with length 0.
            self._data = (
                (ctypes.c_char * length.value).from_address(data) if length.value else b""
            )
        elif self._dtype is ColumnType.INT:
            self._values = (ctypes.c_int64 * rows).from_address(lib.eus_frame_ints(handle, index))
        else:
            self._values = (ctypes.c_double * rows).from_address(
                lib.eus_frame_floats(handle, index)
            )

    @property
    def name(self) -> str:
        return self._name

    @property
    def dtype(self) -> ColumnType:
        return self._dtype

    def __len__(self) -> int:
        return len(self._frame)

    def __getitem__(self, index: int | slice) -> Any:
        if isinstance(index, slice):
            return [self._value(i) for i in range(*index.indices(len(self)))]

        rows = len(self)
        if index < 0:
            index += rows
        if not 0 <= index < rows:
            raise IndexError(f"row {index} out of range for {rows} rows")
        return self._value(index)

    def __iter__(self) -> Iterator[Any]:
        return (self._value(i) for i in range(len(self)))

    def to_list(self) -> list[Any]:
        """Copy the column into a plain Python list."""
        if self._dtype is ColumnType.STRING:
            return [self._value(i) for i in range(len(self))]
        return list(self._values)

    def _value(self, row: int) -> Any:
        # `self._frame` guarantees the buffers outlive us, so this stays a
        # bounds-checked read rather than a use-after-free.
        self._frame._require_open()
        if self._dtype is ColumnType.STRING:
            start, stop = self._offsets[row], self._offsets[row + 1]
            return bytes(self._data[start:stop]).decode("utf-8")
        return self._values[row]

    def __repr__(self) -> str:
        preview = [_format(value) for value in self[:5]]
        if len(self) > 5:
            preview.append("...")
        return f"Column({self._name!r}, {self._dtype}, [{', '.join(preview)}], {len(self)} rows)"


class DataFrame:
    """A parsed CSV table, stored column by column on the Zig side.

    The Zig memory is released when the frame is garbage collected, or at the
    end of a `with` block. Reading from a closed frame raises `ValueError`.
    """

    __slots__ = ("_handle", "_columns", "_dtypes", "_rows", "__weakref__")

    def __init__(self, handle: int | None) -> None:
        if not handle:
            raise ValueError("cannot build a DataFrame from a null handle")

        self._handle: int | None = handle
        self._rows = lib.eus_frame_rows(handle)

        names: list[str] = []
        dtypes: list[ColumnType] = []
        length = ctypes.c_size_t()
        for index in range(lib.eus_frame_columns(handle)):
            pointer = lib.eus_frame_column_name(handle, index, ctypes.byref(length))
            names.append(ctypes.string_at(pointer, length.value).decode("utf-8"))
            dtypes.append(ColumnType(lib.eus_frame_column_type(handle, index)))

        self._columns = tuple(names)
        self._dtypes = tuple(dtypes)

    @property
    def columns(self) -> tuple[str, ...]:
        """The column names, in file order."""
        return self._columns

    @property
    def dtypes(self) -> tuple[ColumnType, ...]:
        """The inferred type of each column, in file order."""
        return self._dtypes

    @property
    def shape(self) -> tuple[int, int]:
        """`(rows, columns)`."""
        return (self._rows, len(self._columns))

    def __len__(self) -> int:
        return self._rows

    def __iter__(self) -> Iterator[str]:
        """Iterate over column names, the way pandas does."""
        return iter(self._columns)

    def __contains__(self, name: object) -> bool:
        return name in self._columns

    def __getitem__(self, key: str | int) -> Column:
        self._require_open()
        if isinstance(key, int):
            index = key + len(self._columns) if key < 0 else key
            if not 0 <= index < len(self._columns):
                raise IndexError(f"column {key} out of range for {len(self._columns)} columns")
        else:
            try:
                index = self._columns.index(key)
            except ValueError:
                raise KeyError(
                    f"no column named {key!r}; have {', '.join(map(repr, self._columns))}"
                ) from None
        return Column(self, index)

    def row(self, index: int) -> tuple[Any, ...]:
        """One row as a tuple, in column order."""
        if index < 0:
            index += self._rows
        if not 0 <= index < self._rows:
            raise IndexError(f"row {index} out of range for {self._rows} rows")
        return tuple(self[name][index] for name in self._columns)

    def head(self, n: int = 5) -> list[tuple[Any, ...]]:
        """The first `n` rows as tuples.

        Pandas would return a DataFrame here. Slicing a frame means building a
        new one on the Zig side, which is Phase 4 work; until then this stays
        an honest list of rows.
        """
        columns = [self[name] for name in self._columns]
        return [tuple(column[row] for column in columns) for row in range(min(n, self._rows))]

    def close(self) -> None:
        """Release the Zig-side memory. Idempotent."""
        handle, self._handle = self._handle, None
        if handle:
            lib.eus_frame_free(handle)

    def __enter__(self) -> DataFrame:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def __del__(self) -> None:
        # Interpreter shutdown may have torn the library down already.
        try:
            self.close()
        except Exception:  # pragma: no cover - only reachable during shutdown
            pass

    def _require_open(self) -> int:
        if self._handle is None:
            raise ValueError("this DataFrame is closed")
        return self._handle

    def __repr__(self) -> str:
        if self._handle is None:
            return "<DataFrame (closed)>"

        rows, columns = self.shape
        if columns == 0:
            return f"<DataFrame: {rows} rows x 0 columns>"

        shown = min(rows, 10)
        cells = [[_format(self[name][row]) for name in self._columns] for row in range(shown)]

        gutter = len(str(shown - 1)) if shown else 1
        widths = [
            max(len(name), *(len(cell[i]) for cell in cells)) if cells else len(name)
            for i, name in enumerate(self._columns)
        ]

        lines = [
            " " * gutter + "  " + "  ".join(name.rjust(w) for name, w in zip(self._columns, widths))
        ]
        lines += [
            str(i).rjust(gutter) + "  " + "  ".join(c.rjust(w) for c, w in zip(cell, widths))
            for i, cell in enumerate(cells)
        ]
        if rows > shown:
            lines.append(f"... ({rows - shown} more rows)")
        lines.append(f"\n[{rows} rows x {columns} columns]")
        return "\n".join(lines)


def _format(value: Any) -> str:
    """Render one cell for display.

    A quoted CSV field may hold newlines and tabs, which would tear the table
    apart, so they are shown escaped. This is for reading only — indexing the
    column still gives the exact text.
    """
    if not isinstance(value, str):
        return repr(value)
    return value.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


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
