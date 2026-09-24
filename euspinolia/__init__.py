"""euspinolia — a small Zig-accelerated table/CSV processing library.

    >>> import euspinolia
    >>> df = euspinolia.read_csv("people.csv")
    >>> df.shape
    (3, 4)
    >>> df["age"].to_list()
    [36, 45, 29]
    >>> df[df["age"] > 30]
        name  age  score
    0    ada   36   91.5
    1  grace   45   88.0

    [2 rows x 3 columns]
    >>> df.groupby("city").agg({"score": "mean"})
           city  score
    0    London   91.5
    1  New York   88.0
    2     Paris  73.25

    [3 rows x 2 columns]
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
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
    "Condition",
    "GroupBy",
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


# Zig's file I/O keeps per-thread state in thread-local storage, which crashes
# inside a ctypes-loaded DLL on Windows/ARM64 with the current toolchain. There
# the file is read here and handed over as bytes; parsing is unaffected.
_READ_FILES_IN_PYTHON = sys.platform == "win32" and platform.machine().upper() in ("ARM64", "AARCH64")


def read_csv(path: str | os.PathLike[str], *, delimiter: str = ",") -> DataFrame:
    """Parse a CSV file into a `DataFrame`.

    The file is read and parsed entirely on the Zig side; Python only ever
    sees the resulting columns. `delimiter` is one ASCII character other than
    a quote or a line break: `";"`, or `"\t"` for TSV.
    """
    separator = _delimiter_byte(delimiter)
    if _READ_FILES_IN_PYTHON:
        with open(path, "rb") as file:
            text = file.read()
        handle = ctypes.c_void_p()
        check(
            lib.eus_parse_csv(text, len(text), separator, ctypes.byref(handle)),
            source=os.fspath(path),
        )
        return DataFrame(handle.value)

    handle = ctypes.c_void_p()
    encoded = os.fsencode(path)
    check(
        lib.eus_read_csv(encoded, len(encoded), separator, ctypes.byref(handle)),
        source=os.fspath(path),
    )
    return DataFrame(handle.value)


def parse_csv(text: str | bytes, *, delimiter: str = ",") -> DataFrame:
    """Parse CSV text already in memory into a `DataFrame`."""
    separator = _delimiter_byte(delimiter)
    encoded = text.encode("utf-8") if isinstance(text, str) else text
    handle = ctypes.c_void_p()
    check(lib.eus_parse_csv(encoded, len(encoded), separator, ctypes.byref(handle)))
    return DataFrame(handle.value)


def _delimiter_byte(delimiter: str) -> int:
    # The scanner splits on one byte, so a multi-byte UTF-8 character can only
    # be refused here; quotes and line breaks are refused on the Zig side.
    if not isinstance(delimiter, str):
        raise TypeError(f"delimiter must be a str, not {type(delimiter).__name__}")
    if len(delimiter) != 1 or not delimiter.isascii():
        raise ValueError(f"delimiter must be a single ASCII character, not {delimiter!r}")
    return ord(delimiter)


# Operator tags as `filter.Op` in src/filter.zig; there is a test pinning them.
_OPERATORS: dict[str, int] = {
    "==": 0,
    "!=": 1,
    "<": 2,
    "<=": 3,
    ">": 4,
    ">=": 5,
}


class Condition:
    """A comparison against one column, waiting to be applied.

    `df["age"] > 30` builds one of these instead of a mask: nothing is
    computed until `df[condition]`, which does the comparison and the row
    gathering in one Zig call. Conditions combine with `&`; each one is then
    applied in turn, which is a conjunction without any mask arithmetic.
    """

    __slots__ = ("_frame", "_clauses")

    def __init__(self, frame: DataFrame, clauses: tuple[tuple[int, str, Any], ...]) -> None:
        self._frame = frame
        self._clauses = clauses

    def __and__(self, other: Condition) -> Condition:
        if not isinstance(other, Condition):
            return NotImplemented
        if other._frame is not self._frame:
            raise ValueError("cannot combine conditions on different DataFrames")
        return Condition(self._frame, self._clauses + other._clauses)

    def __or__(self, other: Condition) -> Condition:
        raise TypeError("`|` between conditions is not supported; filter twice instead")

    def __bool__(self) -> bool:
        raise TypeError(
            "a Condition has no truth value; use df[condition] to apply it, "
            "and `&` rather than `and` to combine"
        )

    def __repr__(self) -> str:
        clauses = " & ".join(
            f"{self._frame.columns[index]} {op} {value!r}" for index, op, value in self._clauses
        )
        return f"Condition({clauses})"


# Aggregate tags as `groupby.Func` in src/groupby.zig; there is a test pinning them.
_AGGREGATES: dict[str, int] = {
    "sum": 0,
    "mean": 1,
    "min": 2,
    "max": 3,
    "count": 4,
}


class GroupBy:
    """`df.groupby(key)`: the rows of a frame, bucketed by one column.

    Nothing is computed until an aggregate is asked for; then Zig hashes
    the keys and reduces the requested columns in one call. The result is a
    new `DataFrame` with one row per distinct key, in order of first
    appearance, whose first column is the key.
    """

    __slots__ = ("_frame", "_key")

    def __init__(self, frame: DataFrame, key: str | int) -> None:
        self._frame = frame
        self._key = frame[key]._index

    @property
    def key(self) -> str:
        """The name of the column the rows are grouped by."""
        return self._frame.columns[self._key]

    def agg(self, specs: dict[str, str]) -> DataFrame:
        """One output column per entry: `{"score": "mean", "age": "max"}`.

        Functions are `sum`, `mean`, `min`, `max` and `count`. Each column
        keeps its name in the result, except `count`, which is named "count"
        and may be asked of any column, since it never reads the values.
        """
        frame = self._frame
        columns: list[int] = []
        funcs: list[int] = []
        for column, func in specs.items():
            try:
                tag = _AGGREGATES[func]
            except KeyError:
                raise ValueError(
                    f"unknown aggregate {func!r}; expected one of {', '.join(_AGGREGATES)}"
                ) from None
            index = frame[column]._index
            if index == self._key and func != "count":
                raise ValueError(
                    f"{frame.columns[index]!r} is the key; it is already the first "
                    "column of the result"
                )
            columns.append(index)
            funcs.append(tag)

        handle = frame._require_open()
        count = len(columns)
        out = ctypes.c_void_p()
        check(
            lib.eus_frame_groupby(
                handle,
                self._key,
                (ctypes.c_size_t * count)(*columns),
                (ctypes.c_uint8 * count)(*funcs),
                count,
                ctypes.byref(out),
            ),
            source=f"groupby({self.key!r}).agg({specs!r})",
        )
        return DataFrame(out.value)

    def sum(self) -> DataFrame:
        """`agg` with `sum` over every numeric column but the key."""
        return self._over_numeric("sum")

    def mean(self) -> DataFrame:
        """`agg` with `mean` over every numeric column but the key."""
        return self._over_numeric("mean")

    def min(self) -> DataFrame:
        """`agg` with `min` over every numeric column but the key."""
        return self._over_numeric("min")

    def max(self) -> DataFrame:
        """`agg` with `max` over every numeric column but the key."""
        return self._over_numeric("max")

    def count(self) -> DataFrame:
        """Rows per group, in a column named "count"."""
        return self.agg({self.key: "count"})

    def _over_numeric(self, func: str) -> DataFrame:
        frame = self._frame
        return self.agg(
            {
                name: func
                for index, (name, dtype) in enumerate(zip(frame.columns, frame.dtypes))
                if index != self._key and dtype is not ColumnType.STRING
            }
        )

    def __repr__(self) -> str:
        return f"GroupBy({self.key!r}, {len(self._frame)} rows)"


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

    def sum(self) -> int | float:
        """The total, computed in Zig. Integer columns stay exact."""
        return self._reduce(lib.eus_column_sum)

    def min(self) -> int | float:
        """The smallest value. Raises `ValueError` on an empty column."""
        return self._reduce(lib.eus_column_min)

    def max(self) -> int | float:
        """The largest value. Raises `ValueError` on an empty column."""
        return self._reduce(lib.eus_column_max)

    def mean(self) -> float:
        """The arithmetic mean, always a float."""
        handle = self._frame._require_open()
        result = ctypes.c_double()
        check(lib.eus_column_mean(handle, self._index, ctypes.byref(result)), source=self._name)
        return result.value

    def __eq__(self, other: object) -> Condition:  # type: ignore[override]
        return self._condition("==", other)

    def __ne__(self, other: object) -> Condition:  # type: ignore[override]
        return self._condition("!=", other)

    def __lt__(self, other: Any) -> Condition:
        return self._condition("<", other)

    def __le__(self, other: Any) -> Condition:
        return self._condition("<=", other)

    def __gt__(self, other: Any) -> Condition:
        return self._condition(">", other)

    def __ge__(self, other: Any) -> Condition:
        return self._condition(">=", other)

    # Comparison operators build Conditions, so two Columns never compare
    # equal as objects; there is no consistent hash to go with that.
    __hash__ = None  # type: ignore[assignment]

    def _condition(self, op: str, value: Any) -> Condition:
        return Condition(self._frame, ((self._index, op, value),))

    def _reduce(self, function: Any) -> int | float:
        """Run a reduction that keeps the column's type.

        Zig writes the answer to whichever out-parameter matches the column,
        so an integer total never rounds through a float on the way back.
        """
        handle = self._frame._require_open()
        as_int, as_float = ctypes.c_int64(), ctypes.c_double()
        check(
            function(handle, self._index, ctypes.byref(as_int), ctypes.byref(as_float)),
            source=self._name,
        )
        return as_int.value if self._dtype is ColumnType.INT else as_float.value

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

    def __getitem__(self, key: str | int | list[str | int] | Condition) -> Any:
        """`df["name"]` / `df[0]` is a `Column`; `df[["a", "b"]]` and
        `df[condition]` are new `DataFrame`s."""
        self._require_open()
        if isinstance(key, Condition):
            if key._frame is not self:
                raise ValueError("this Condition was built from a different DataFrame")
            result = self
            for index, op, value in key._clauses:
                narrowed = result.filter(index, op, value)
                if result is not self:
                    result.close()
                result = narrowed
            return result
        if isinstance(key, list):
            return self.select(key)
        return Column(self, self._column_index(key))

    def select(self, columns: list[str | int]) -> DataFrame:
        """The named columns, in the order given, as a new `DataFrame`.

        Columns are copied in Zig, so the result owns its memory and outlives
        this frame. `df.select(["name", "age"])` is `df[["name", "age"]]`.
        """
        indices = [self._column_index(column) for column in columns]
        if len(set(indices)) != len(indices):
            names = [self._columns[index] for index in indices]
            repeated = sorted({name for name in names if names.count(name) > 1})
            raise ValueError(f"columns selected more than once: {', '.join(map(repr, repeated))}")

        handle = self._require_open()
        count = len(indices)
        out = ctypes.c_void_p()
        check(
            lib.eus_frame_select(
                handle, (ctypes.c_size_t * count)(*indices), count, ctypes.byref(out)
            )
        )
        return DataFrame(out.value)

    def _column_index(self, key: str | int) -> int:
        if isinstance(key, bool):
            raise TypeError("a column is chosen by name or position, not by a bool")
        if isinstance(key, int):
            index = key + len(self._columns) if key < 0 else key
            if not 0 <= index < len(self._columns):
                raise IndexError(f"column {key} out of range for {len(self._columns)} columns")
            return index
        try:
            return self._columns.index(key)
        except ValueError:
            raise KeyError(
                f"no column named {key!r}; have {', '.join(map(repr, self._columns))}"
            ) from None

    def row(self, index: int) -> tuple[Any, ...]:
        """One row as a tuple, in column order."""
        if index < 0:
            index += self._rows
        if not 0 <= index < self._rows:
            raise IndexError(f"row {index} out of range for {self._rows} rows")
        return tuple(self[name][index] for name in self._columns)

    def head(self, n: int = 5) -> list[tuple[Any, ...]]:
        """The first `n` rows as tuples.

        Pandas would return a DataFrame here. This is a peek, not a slice:
        a list of tuples is what you want to print or assert on, and it
        costs no Zig-side allocation.
        """
        columns = [self[name] for name in self._columns]
        return [tuple(column[row] for column in columns) for row in range(min(n, self._rows))]

    def filter(self, column: str | int, op: str, value: int | float | str) -> DataFrame:
        """The rows where `column <op> value` holds, as a new `DataFrame`.

        `op` is one of `==`, `!=`, `<`, `<=`, `>`, `>=`. The comparison and
        the row gathering both happen in Zig; the result owns its own memory
        and outlives this frame. `df.filter("age", ">", 30)` is the same as
        `df[df["age"] > 30]`.
        """
        try:
            tag = _OPERATORS[op]
        except KeyError:
            raise ValueError(
                f"unknown operator {op!r}; expected one of {', '.join(_OPERATORS)}"
            ) from None

        index = self[column]._index
        handle = self._require_open()
        out = ctypes.c_void_p()
        name = self._columns[index]

        if isinstance(value, bool):
            raise TypeError(f"cannot compare column {name!r} with a bool")
        if isinstance(value, int):
            code = lib.eus_frame_filter_int(handle, index, tag, value, ctypes.byref(out))
        elif isinstance(value, float):
            code = lib.eus_frame_filter_float(handle, index, tag, value, ctypes.byref(out))
        elif isinstance(value, str):
            encoded = value.encode("utf-8")
            code = lib.eus_frame_filter_string(
                handle, index, tag, encoded, len(encoded), ctypes.byref(out)
            )
        else:
            raise TypeError(
                f"cannot compare column {name!r} with {type(value).__name__}; "
                "expected int, float or str"
            )

        check(code, source=f"{name} {op} {value!r}")
        return DataFrame(out.value)

    def sort_values(self, by: str | int, *, ascending: bool = True) -> DataFrame:
        """The rows ordered by one column, as a new `DataFrame`.

        The sort runs in Zig and is stable in both directions: rows with
        equal keys keep their order, so sorting by a second key and then by
        the first gives a two-key order. Text sorts bytewise.
        """
        index = self._column_index(by)
        handle = self._require_open()
        out = ctypes.c_void_p()
        check(
            lib.eus_frame_sort(handle, index, 0 if ascending else 1, ctypes.byref(out)),
            source=f"sort_values({self._columns[index]!r})",
        )
        return DataFrame(out.value)

    def groupby(self, key: str | int) -> GroupBy:
        """Bucket the rows by one column; see `GroupBy` for what to do next.

        `df.groupby("city").agg({"score": "mean"})` is the whole shape of it.
        """
        return GroupBy(self, key)

    def to_csv(
        self, path: str | os.PathLike[str] | None = None, *, delimiter: str = ","
    ) -> str | None:
        """Write the frame as CSV to `path`, or return it as a string if no path.

        The whole serialisation happens in Zig; Python only writes the bytes
        out. The output reads back as the same frame, types included, given
        the same `delimiter`: fields are quoted only when they need to be, and
        floats always carry a `.` or an exponent so they are not mistaken for
        integers.
        """
        separator = _delimiter_byte(delimiter)
        handle = self._require_open()
        pointer = ctypes.c_void_p()
        length = ctypes.c_size_t()
        check(
            lib.eus_frame_to_csv(handle, separator, ctypes.byref(pointer), ctypes.byref(length))
        )
        try:
            data = ctypes.string_at(pointer, length.value)
        finally:
            lib.eus_bytes_free(pointer, length)

        if path is None:
            return data.decode("utf-8")
        with open(path, "wb") as out:
            out.write(data)
        return None

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
