# API reference

Everything public lives in the `euspinolia` package. There are no
dependencies: the package is two Python modules and one shared library.

```python
import euspinolia
```

## Reading

### `read_csv(path, *, delimiter=",") -> DataFrame`

Parses a CSV file. `path` is a `str` or any `os.PathLike`. The file is read
and parsed entirely on the Zig side; Python only ever sees the resulting
columns.

`delimiter` is one ASCII character other than `"`, `\r` or `\n`:

```python
euspinolia.read_csv("prices.csv", delimiter=";")   # the European spreadsheet export
euspinolia.read_csv("people.tsv", delimiter="\t")  # TSV
```

A reserved or multi-byte character raises `ValueError`; anything but a `str`
raises `TypeError`.

Raises `FileNotFoundError`, `PermissionError`, `IsADirectoryError` or
`OSError` for the usual file problems, and `ParseError` for malformed CSV.

### `parse_csv(text, *, delimiter=",") -> DataFrame`

Parses CSV that is already in memory, as `str` (encoded as UTF-8) or `bytes`.
The bytes are copied into the frame's own memory, so the source may be
discarded as soon as this returns.

### `from_dict(data) -> DataFrame`

Builds a frame from data already in Python: a mapping of column names to
any iterable of values. Every column must have the same length.

```python
df = euspinolia.from_dict({"name": ["ada", "grace"], "age": [36, 45], "score": [91.5, 88]})
df.dtypes   # (string, int, float)
```

Each column's type follows from its **values**, not from their text:

| values | column |
|---|---|
| only `int` | `int` |
| `int` and `float` | `float` |
| only `str` | `string` — `"01234"` stays text, unlike in a parsed file |
| none at all | `string`, as for a header-only file |

What the library cannot store is refused rather than converted: `None` and
`bool` (`TypeError`), text mixed with numbers (`TypeError`), `nan` and `inf`
(`ValueError`), an integer outside 64 bits (`OverflowError`), columns of
different lengths (`ValueError`), and a non-`str` column name or a bare
string as a column's values (`TypeError`).

Everything is copied into the frame's memory in one Zig call.

### What counts as CSV

A deliberate subset of RFC 4180:

- The first record is the header. Every later record must have the same
  number of fields, otherwise parsing fails with `ParseError`.
- Quoted fields may contain the delimiter, line breaks, and `""` as an escaped
  quote. A quote inside an unquoted field is taken literally.
- Records end with `\n` or `\r\n`; a trailing newline is optional.
- Blank lines are skipped. Whitespace is never trimmed.
- One delimiter for the whole input, `,` unless `delimiter` says otherwise.
  Under any other delimiter a comma is ordinary text.

Every column gets one type, inferred from its values and widening in the
order `int → float → string`:

| cell | inferred as |
|---|---|
| `42`, `-7` | `int` (64-bit; a value that does not fit makes the column `float`) |
| `3.5`, `1e-3`, `-0.0` | `float` |
| anything else | `string` |
| an empty cell | `string` — there is no missing-data semantics, so a blank is text, not a null |
| `nan`, `inf` | `string` — non-finite values are out of scope |
| `0x10`, `1_000` | `string` — Zig's number parsers accept these, but a spreadsheet would not |

A header-only input gives a frame with zero rows and every column typed
`string`.

## `DataFrame`

The result of `read_csv`, `parse_csv`, `from_dict`, or of a selection, a
filter, a sort or a groupby on another frame.
It owns memory on the Zig side; see [Memory](#memory) for when that is
released.

### Shape and metadata

| | |
|---|---|
| `df.shape` | `(rows, columns)` |
| `len(df)` | number of rows |
| `df.columns` | column names, as a tuple of `str` |
| `df.dtypes` | one `ColumnType` per column, as a tuple |
| `name in df` | whether a column with that name exists |
| `iter(df)` | iterates over column names, the way pandas does |
| `repr(df)` | the first ten rows as an aligned table, then `[rows x columns]` |

### Selecting a column

```python
df["age"]     # by name; KeyError if missing
df[1]         # by position; negatives count from the end; IndexError if out of range
```

Both return a `Column`. A `bool` is refused with `TypeError` rather than
read as position `0` or `1`.

### Selecting columns

```python
df[["name", "age"]]          # a new DataFrame with those columns, in that order
df.select(["name", "age"])   # the same thing, as a call
df[[-1, "name"]]             # names and positions mix
```

The columns are copied in Zig, so the result owns its memory and outlives
its source, like a filtered frame. Asking for the same column twice raises
`ValueError`; an unknown name `KeyError`; a position out of range
`IndexError`. An empty list gives a frame with the same rows and no columns.

### Selecting rows

```python
df.row(0)      # one row as a tuple, in column order; negatives allowed
df.head(2)     # the first n rows (default 5) as a list of tuples
```

### `df.to_dict() -> dict[str, list]`

Every column as a plain list, keyed by name, in column order.
`from_dict(df.to_dict())` gives back the same frame, types included.

### `df.filter(column, op, value) -> DataFrame`

The rows where `column <op> value` holds, as a new frame. `column` is a
name or a position. `op` is one of `"=="`, `"!="`, `"<"`, `"<="`, `">"`,
`">="`. `value` is an `int`, `float` or `str`.

- Numbers compare across `int` and `float` columns: `df.filter("age", ">", 30.5)`
  is fine on an `int` column.
- Strings compare bytewise, so `"<"` on a text column is a plain byte order.
- Comparing a text column with a number, or a numeric column with a string,
  raises `TypeError` rather than matching nothing.
- `bool` is rejected with `TypeError`, since Python would otherwise let
  `True` through as `1`.
- An unknown operator raises `ValueError`.

The result owns its own memory: it outlives the frame it came from, and can
be filtered again. Column types are preserved even when no rows survive.

### `df[condition] -> DataFrame`

The same thing, written with operators:

```python
df[df["age"] > 30]
df[(df["age"] > 30) & (df["score"] < 90)]
df[df["city"] == "Paris"]
```

`df["age"] > 30` computes nothing: it builds a `Condition` that `df[...]`
applies in one Zig call. See [`Condition`](#condition).

### `df.sort_values(by, *, ascending=True) -> DataFrame`

The rows ordered by one column, named or by position, as a new frame that
owns its memory.

```python
df.sort_values("age")                     # youngest first
df.sort_values("score", ascending=False)  # highest first
```

- The sort is **stable** in both directions: rows with equal keys keep the
  order they had. Sorting by a second key and then by the first therefore
  gives a two-key order:

  ```python
  df.sort_values("age").sort_values("city")   # by city, then by age within a city
  ```

- Numbers sort numerically, `-0.0` and `0.0` as equals. Text sorts bytewise,
  so `"B"` comes before `"a"`.
- There is no index to keep: the result's rows are simply renumbered.

### `df.groupby(key) -> GroupBy`

Buckets the rows by one column, named or by position. Nothing is computed
until you ask the `GroupBy` for an aggregate. See [`GroupBy`](#groupby).

### `df.to_csv(path=None, *, delimiter=",") -> str | None`

Serialises the frame as CSV. With a `path`, writes the file and returns
`None`; without one, returns the text as a `str`. `delimiter` follows the
same rules as for `read_csv`.

The whole serialisation happens in Zig, and the output is exactly what the
parser reads: a header, `\n` line endings, and a field quoted only when it
holds the delimiter, a quote or a line break (with `"` doubled inside).
Reading the output back with the same delimiter gives the same frame, types
included:

- Integers print as-is.
- Floats print as the shortest decimal that reads back to the same value,
  always with a `.` or an exponent (`88.0`, not `88`), so a float column
  whose values happen to be whole numbers is still inferred as float.
  Magnitudes of `1e16` and above, or below `1e-4`, print in scientific
  notation (`1e300`, `1e-5`) rather than as hundreds of digits.
- `-0.0` survives as `-0.0`.

### Memory

A `DataFrame` owns its columns in one arena on the Zig side. The arena is
released when the frame is garbage collected, or explicitly:

```python
df.close()                       # idempotent

with euspinolia.read_csv("people.csv") as df:
    ...                          # closed on the way out
```

After `close()`, every operation on the frame — and on any `Column` taken
from it — raises `ValueError` instead of touching freed memory. A `Column`
holds a reference to its frame, so dropping the frame while keeping a column
is safe.

Filtered and grouped frames are independent of their source: closing one
never affects the other.

## `Column`

One column of a frame, returned by `df["name"]` or `df[i]`.

| | |
|---|---|
| `column.name` | the column's name |
| `column.dtype` | its `ColumnType` |
| `len(column)` | number of rows |
| `column[i]` | one value; negatives count from the end; `IndexError` if out of range |
| `column[a:b]` | a `list` of values, with ordinary slice semantics |
| `iter(column)` | yields values one at a time, lazily |
| `column.to_list()` | every value as a `list` |
| `repr(column)` | `Column('age', int, [36, 45, 29], 3 rows)` |

Values come back as `int`, `float` or `str`. Numeric columns are a view: an
index reads the Zig-side array in place through `ctypes`, with no copy and no
allocation. Strings are decoded from the packed byte buffer on each access.

### Reductions

| | |
|---|---|
| `column.sum()` | `int` for an `int` column, exact; `float` otherwise |
| `column.min()`, `column.max()` | keep the column's type |
| `column.mean()` | always a `float` |

All four run in Zig over the contiguous array. On a text column they raise
`TypeError`; on an empty column `ValueError`; an integer sum that leaves the
64-bit range raises `OverflowError` rather than wrapping.

### Comparisons

`==`, `!=`, `<`, `<=`, `>`, `>=` against an `int`, `float` or `str` return a
`Condition` rather than a boolean or a mask. Because `==` is overloaded,
columns are not hashable and should not be compared for identity with `==`.

## `Condition`

What `df["age"] > 30` evaluates to: one comparison, waiting to be applied.

- `df[condition]` applies it, returning a new `DataFrame`.
- `a & b` combines two conditions on the same frame. Each clause is applied
  in turn, so `&` is a conjunction without any mask arithmetic. Combining
  conditions built from different frames raises `ValueError`.
- `a | b` raises `TypeError`: there is no disjunction. Filter twice instead.
- `bool(condition)` raises `TypeError`, so a slip like `a and b` fails
  loudly rather than silently keeping only `b`.
- `repr` shows the clauses: `Condition(age > 30 & score < 90)`.

## `GroupBy`

What `df.groupby(key)` returns. `groupby.key` is the key column's name.

### `groupby.agg(specs) -> DataFrame`

`specs` maps column names to aggregate functions:

```python
df.groupby("city").agg({"score": "mean", "age": "max"})
```

The functions are `"sum"`, `"mean"`, `"min"`, `"max"` and `"count"`. The
result is a new frame whose first column is the key, with one row per
distinct key **in order of first appearance** — not sorted, unlike pandas.
Then one column per entry in `specs`, in the order given:

- `sum`, `min` and `max` keep the column's type; `mean` is always `float`.
- `count` never reads the values, so it may be asked of any column, including
  the key or a text column. Its output column is named `count`.
- Any other aggregate on a text column raises `TypeError`.
- Naming the key itself with anything but `count` raises `ValueError`; it is
  already the first column of the result.
- An unknown function raises `ValueError`.

Keys are compared exactly: for a `float` key, `1.0` and `1.5` are different
groups, and for a `string` key, comparison is bytewise.

### Shortcuts

| | |
|---|---|
| `groupby.sum()`, `.mean()`, `.min()`, `.max()` | that aggregate over every numeric column except the key |
| `groupby.count()` | one column, `count`, with the rows per group |

## `ColumnType`

An `IntEnum` with `INT = 0`, `FLOAT = 1`, `STRING = 2`. `str(ColumnType.INT)`
is `"int"`. The values are the tag numbers the Zig side uses and are part of
the ABI.

## Exceptions

Errors cross the Zig boundary as status codes and surface as ordinary Python
exceptions:

| raised | when |
|---|---|
| `ParseError` (subclass of `ValueError`) | malformed CSV: a ragged row, an unterminated quote, a stray character after a closing quote, no header |
| `FileNotFoundError`, `PermissionError`, `IsADirectoryError`, `OSError` | `read_csv` could not read the file |
| `KeyError`, `IndexError` | no such column, or a row/column position out of range |
| `TypeError` | arithmetic on a text column, comparing text with a number, aggregating a text column, `bool(condition)`, `a \| b`, a `from_dict` value that is not `int`, `float` or `str` |
| `ValueError` | a closed frame, an empty column reduced, an unknown operator or aggregate, mixing frames in a condition, a delimiter that is reserved or not one ASCII character, `from_dict` columns of different lengths or holding `nan`/`inf` |
| `OverflowError` | an integer sum that leaves the 64-bit range, a `from_dict` integer outside 64 bits |
| `MemoryError` | the Zig side ran out of memory |
| `LibraryNotFoundError` (subclass of `RuntimeError`) | the shared library could not be located at import time |

## Diagnostics

| | |
|---|---|
| `euspinolia.__version__` | the package version |
| `euspinolia.version()` | the version the loaded library reports |
| `euspinolia.self_check()` | raises `RuntimeError` if the loaded library is stale or mismatched |
| `EUSPINOLIA_LIB` (environment variable) | path to a shared library to load instead of the bundled one |

`ping()` and `add(a, b)` are the original bridge smoke-tests and are kept
for `self_check`.
