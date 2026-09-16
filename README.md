# euspinolia

A small, educational Zig-accelerated table/CSV processing library. The core
data structures and operations live in Zig; Python gets a thin `ctypes` layer
on top.

The name comes from *Euspinolia*, the genus of the velvet ant known as the
"panda ant".

```python
>>> import euspinolia
>>> df = euspinolia.read_csv("people.csv")
>>> df
        name  age  score      city
0        ada   36   91.5    London
1      grace   45   88.0  New York
2  Doe, John   29  73.25     Paris

[3 rows x 4 columns]
>>> df["age"].to_list()
[36, 45, 29]
>>> df[df["age"] > 30]
    name  age  score      city
0    ada   36   91.5    London
1  grace   45   88.0  New York

[2 rows x 4 columns]
>>> df.groupby("city").agg({"score": "mean"})
       city  score
0    London   91.5
1  New York   88.0
2     Paris  73.25

[3 rows x 2 columns]
```

## Status

**Complete, as scoped.** Reading a CSV, inspecting its shape, pulling out
columns, reducing them (`sum`, `mean`, `min`, `max`), filtering rows and
`groupby` with aggregates all work, and `bench/` measures them against pandas.
The scope was fixed at the start and is not growing: multi-index, date/time
types, NaN semantics, join/merge and pivot tables are out. The goal was never a
real table engine but a teachable subset that genuinely works.

## Requirements

- Zig 0.16.0 or newer
- Python 3.9+

## Getting started

```sh
zig build   # produces zig-out/lib/libeuspinolia.so, which the package loads
python3 -c "import euspinolia; euspinolia.self_check()"
```

`zig build` produces a **ReleaseSafe** library rather than Zig's usual Debug
default — Debug parses about 12x slower, which would make the library slower
than the `csv` module it is meant to beat. Pass `-Doptimize=ReleaseFast` to drop
the safety checks, or `-Doptimize=Debug` while working on the Zig side.

## API

```python
import euspinolia

df = euspinolia.read_csv("people.csv")   # parse a file
df = euspinolia.parse_csv(csv_text)      # parse text already in memory

df.shape          # (3, 4) — (rows, columns)
len(df)           # 3 — rows
df.columns        # ('name', 'age', 'score', 'city')
df.dtypes         # (string, int, float, string)
"age" in df       # True
list(df)          # column names, the way pandas iterates

column = df["age"]   # by name; df[1] works too, negatives included
column.name          # 'age'
column.dtype         # ColumnType.INT
column[0]            # 36 — read straight out of the Zig buffer
column[-1]           # 29
column[1:]           # [45, 29]
list(column)         # 36, 45, 29 — lazily, one value at a time
column.to_list()     # [36, 45, 29]

df.row(0)         # ('ada', 36, 91.5, 'London')
df.head(2)        # the first two rows as tuples

column.sum()      # 195 — reduced in Zig, over the contiguous array
column.mean()     # 39.0 — always a float
column.min()      # 29
column.max()      # 54

df.filter("age", ">", 30)               # a new DataFrame with the matching rows
df[df["age"] > 30]                      # the same thing
df[(df["age"] > 30) & (df["score"] < 90)]
df[df["city"] == "Paris"]

df.groupby("city").agg({"score": "mean", "age": "max"})   # one row per city
df.groupby("city").sum()                                  # every numeric column
df.groupby("city").count()                                # rows per group

df.to_csv("out.csv")   # write it back out; reads back as the same frame
df.to_csv()            # or as a string
```

Reductions keep the column's type: an integer column sums to an `int`, exactly,
without rounding through a float. A total that leaves the `i64` range raises
`OverflowError` rather than wrapping, and asking a text column for arithmetic
raises `TypeError`.

Filtering compares one column against a value with `==`, `!=`, `<`, `<=`, `>`
or `>=`, and returns a new frame that owns its own memory — it outlives the
frame it came from, and can be filtered again. Numbers compare across `int`
and `float` columns; strings compare bytewise; comparing text with a number
raises `TypeError` rather than silently matching nothing.

`df["age"] > 30` does not compute anything: it builds a `Condition` that
`df[...]` applies in one Zig call. Conditions combine with `&` (each clause
narrows the previous result) — `|` is not supported, and `and` raises, since
Python would otherwise coerce the left side to a bool.

`groupby(key)` buckets the rows by one column and returns a lazy `GroupBy`;
`.agg({column: function})` then reduces each listed column within every group,
in one Zig call. Functions are `sum`, `mean`, `min`, `max` and `count`. The
result is a new frame with the key as its first column and one row per
distinct key, in order of first appearance — not sorted, unlike pandas.
`sum`, `min` and `max` keep the column's type, `mean` is always float, and
`count` (which may be asked of any column, since it never reads the values)
lands in a column named `count`. `.sum()`, `.mean()`, `.min()`, `.max()` and
`.count()` are shortcuts over every numeric column but the key.

`to_csv` serialises in Zig and hands Python the bytes, which it writes to
`path` or returns as a `str`. The output is what the parser reads: a header,
`\n` line endings, and a field quoted only when it holds a comma, a quote or
a line break. Floats always carry a `.` or an exponent, so a float column
whose values happen to be whole numbers comes back as float, not int.

Errors arrive as ordinary Python exceptions: `FileNotFoundError` for a missing
path, `ParseError` (a `ValueError`) for malformed CSV.

### Memory

A `DataFrame` owns memory on the Zig side. It is released when the frame is
garbage collected, or you can be explicit:

```python
with euspinolia.read_csv("people.csv") as df:
    ...   # freed on the way out; df.close() does the same thing
```

Numeric columns are read through the Zig buffer rather than copied out of it,
so `df["age"][0]` costs an array index and no allocation. A `Column` keeps its
frame alive, so it never outlives the memory it points at — reading either one
after `close()` raises `ValueError` instead of touching freed memory.

## Performance

`bench/bench.py` times the same seven jobs in euspinolia, pandas and the
standard `csv` module plus plain Python, on a generated 18 MB CSV — 500,000
rows, 5 columns (`id`, `name`, `dept`, `salary`, `score`), best of five runs.
The numbers below are from one laptop with pandas 3.0.5 and Python 3.14; run
it yourself, they will differ:

```sh
python3 -m venv .venv && .venv/bin/pip install pandas   # optional
python3 bench/make_big.py                                # writes data/big.csv
.venv/bin/python bench/bench.py
```

| | euspinolia | pandas | csv module + Python |
|---|---|---|---|
| read + parse | 114 ms | 183 ms | 335 ms |
| write back out (`to_csv`) | 63 ms | 478 ms | 294 ms |
| sum an int column | 0.2 ms | 0.2 ms | 10.1 ms |
| mean of a float column | 0.2 ms | 0.5 ms | 10.3 ms |
| filter `salary > 120,000` (keeps half the rows) | 10.5 ms | 8.7 ms | 13.8 ms |
| groupby `dept` (5 groups), mean `score` | 7.5 ms | 23.6 ms | 47.8 ms |
| groupby `dept`, count | 7.1 ms | 23.7 ms | 24.9 ms |

What the table says:

- **Parsing** is the headline: 3x faster than the `csv` module and ahead of
  pandas, and the gap is not scanning alone. The `csv` module pays for a
  Python tuple per row before any conversion; euspinolia hands back typed
  columns Python never has to materialise.
- **Writing** is the widest gap, 7x over pandas. `src/write.zig` walks the
  typed columns and prints straight into one growing buffer; pandas formats
  every cell through a Python object on the way to text.
- **Reductions** are a wash against pandas, as they should be — both walk one
  flat array in native code. The 50x over Python is the point of columnar
  storage: Zig adds a `[]i64`, Python boxes half a million integers.
- **GroupBy** is 3x faster than pandas here because the job is small: five
  short keys, one aggregate. `src/groupby.zig` hashes each key straight into a
  dense group id and folds into a flat accumulator array; pandas builds a
  general `GroupBy` object that would keep winning as the job grew.
- **Filtering is the one loss**, and a narrow one. The mask is one pass;
  the gather that follows is branchless — every row is written, the cursor
  advances only on a kept one — because a `continue` on a mask the CPU
  cannot predict cost more than the copy itself (the numeric columns alone
  went from 10 ms to 3 ms). What remains is the two text columns: euspinolia
  copies every kept string's bytes into a packed buffer, so the result owns
  its memory and outlives the frame it came from, while pandas (without
  pyarrow) keeps a string column as pointers to Python `str` objects and
  copies eight bytes per row. The plain-Python comprehension likewise only
  copies references — it has not built a frame.

Treat all of this as a sanity check that the Zig side is pulling its weight,
not as a published result: one machine, one file, and pandas is doing more
than euspinolia at every row.

## CSV support

The parser implements a deliberate subset of RFC 4180:

- Quoted fields may contain the delimiter, newlines, and `""` escapes.
- Both `\n` and `\r\n` end a record; a trailing newline is optional.
- Blank lines are skipped. Whitespace is never trimmed.
- The first record is the header; every later record must match its field
  count, otherwise parsing fails.

Type inference per column widens `int → float → string`:

- An empty cell makes the column `string`. There is no missing-data semantics,
  so a blank is text rather than an invented null.
- `nan` and `inf` are text, since non-finite values are out of scope.
- `0x10` and `1_000` are text. Zig's number parsers accept those source-literal
  forms, but a spreadsheet would not call them numbers.

## Columnar storage

`csv.Table` is only a staging form. `frame.DataFrame` converts it into one
typed array per column (struct of arrays), which is what everything downstream
reads:

- `int` and `float` columns are flat `[]i64` / `[]f64` arrays.
- `string` columns are a packed byte buffer plus `row_count + 1` offsets into
  it, so value `i` is `data[offsets[i]..offsets[i + 1]]`. An empty string costs
  nothing but a repeated offset.

A filter or an aggregate then walks one contiguous array instead of hopping
between per-row allocations, and Python reads a column as a flat buffer without
copying. A `DataFrame` owns its data in its own arena, so the `Table` it came
from can be freed immediately.

## GroupBy

`src/groupby.zig` is two passes. The first walks the key column once and
hashes every value into a dense group id (`std.AutoHashMap` for numbers,
`std.StringHashMap` for text, keyed by slices into the column's own data
buffer), so afterwards each row knows its group as a `u32` and the map can
be dropped. The second walks each value column once, folding every row into
its group's accumulator — a flat array with one slot per group. There is no
per-group allocation and no sorting; the result rows come out in the order
the keys were first seen.

## Crossing into Python

`src/ffi.zig` is the whole C ABI surface, and it keeps three rules:

- A frame crosses as an opaque pointer, created by `eus_read_csv`,
  `eus_frame_filter_*` or `eus_frame_groupby` and released by
  `eus_frame_free`. Nothing else owns it.
- Zig error sets do not survive the C ABI, so fallible functions return an
  `i32` status and write their result through an out-parameter. The mapping
  from Zig errors to status codes happens once, in one place.
- Column data is handed out as borrowed pointers into the frame's arena. They
  are valid until the frame is freed, and the caller must not write to them.
  The one exception is the CSV text from `eus_frame_to_csv`, which Python
  copies out and then releases with `eus_bytes_free`.

## Tests

```sh
zig build test                              # Zig unit tests
python3 -m unittest discover -s tests -v    # Python-side tests
```

## Layout

```
build.zig               shared library build definition
src/root.zig            module roots and the bridge smoke-test exports
src/csv.zig             CSV scanner and the row-major Table
src/dtype.zig           column type inference
src/frame.zig           columnar DataFrame and the conversion into it
src/agg.zig             reductions over a single column
src/filter.zig          row selection by comparing a column against a value
src/groupby.zig         hash the keys of one column, reduce others per group
src/write.zig           serialise a frame back to CSV
src/ffi.zig             the C ABI; every symbol is prefixed with `eus_`
euspinolia/_ffi.py      library discovery, loading, ctypes signatures
euspinolia/__init__.py  DataFrame, Column, Condition, GroupBy, read_csv
tests/test_ffi.py       bridge tests
tests/test_frame.py     read_csv, indexing, reductions, filtering, groupby,
                        memory ownership
bench/make_big.py       writes the 500,000-row CSV the benchmark reads
bench/bench.py          euspinolia vs pandas vs the csv module, as a table
```

The library is looked up under `zig-out/lib/` by default; set `EUSPINOLIA_LIB`
to override the path.

## Architecture

```
[Python]  df = euspinolia.read_csv("data.csv")
              │  ctypes call, path as bytes
              ▼
[Zig]     csv.zig    scan the file into a row-major Table
              │
              ▼
          dtype.zig  infer a type per column: int → float → string
              │
              ▼
          frame.zig  DataFrame — one typed array per column, in one arena
              │      int/float: flat []i64 / []f64
              │      string:    packed bytes + offsets
              │
              ├─▶ agg.zig      sum / mean / min / max      → one value
              ├─▶ filter.zig   mask a column, gather rows  → a new frame
              ├─▶ groupby.zig  hash keys, fold per group   → a new frame
              └─▶ write.zig    serialise                   → CSV bytes
              │
              │  ffi.zig: opaque frame pointer, i32 status codes,
              │  borrowed column pointers into the arena
              ▼
[Python]  DataFrame / Column / Condition / GroupBy wrap the handle;
          df["salary"][0] reads the Zig buffer through ctypes, no copy
```
