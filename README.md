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
```

## Status

**Phase 4, half done.** Reading a CSV, inspecting its shape, pulling out
columns and reducing them (`sum`, `mean`, `min`, `max`) all work. Filtering is
the other half of Phase 4; `groupby` is Phase 5. See `roadmap.md`.

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
```

Reductions keep the column's type: an integer column sums to an `int`, exactly,
without rounding through a float. A total that leaves the `i64` range raises
`OverflowError` rather than wrapping, and asking a text column for arithmetic
raises `TypeError`.

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

Reading an 18 MB CSV — 500,000 rows, 5 columns — on one machine, best of five
runs, against Python's standard `csv` module:

| | time | |
|---|---|---|
| `euspinolia.read_csv` | 0.20s | parses, infers types, builds columns |
| `csv.reader` → list of rows | 0.59s | strings only, no types | 
| `csv.reader` + `int`/`float` per field | 0.61s | the same work | 

So roughly **3x** for the same job, and the gap is not the parsing alone: the
`csv` module already pays for a Python tuple per row before any conversion,
while euspinolia hands back typed columns Python never has to materialise.

Reductions are where the columnar layout really pays. Summing a 500,000-row
integer column:

| | time |
|---|---|
| `column.sum()` | 0.5 ms |
| `sum(column)` — Python looping over the same buffer | 50 ms |
| `sum(column.to_list())` — copy out first | 37 ms |

About **96x**, because Zig walks one flat `[]i64` while Python boxes half a
million integers to add them up.

A proper benchmark against pandas is Phase 6; treat these as a sanity check
that the Zig side is pulling its weight, not as a published result.

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

## Crossing into Python

`src/ffi.zig` is the whole C ABI surface, and it keeps three rules:

- A frame crosses as an opaque pointer, created by `eus_read_csv` and released
  by `eus_frame_free`. Nothing else owns it.
- Zig error sets do not survive the C ABI, so fallible functions return an
  `i32` status and write their result through an out-parameter. The mapping
  from Zig errors to status codes happens once, in one place.
- Column data is handed out as borrowed pointers into the frame's arena. They
  are valid until the frame is freed, and the caller must not write to them.

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
src/ffi.zig             the C ABI; every symbol is prefixed with `eus_`
euspinolia/_ffi.py      library discovery, loading, ctypes signatures
euspinolia/__init__.py  DataFrame, Column, read_csv
tests/test_ffi.py       bridge tests
tests/test_frame.py     read_csv, indexing, reductions, memory ownership
```

The library is looked up under `zig-out/lib/` by default; set `EUSPINOLIA_LIB`
to override the path.

## Architecture

```
[Python]  df = euspinolia.read_csv("data.csv")
              │  ctypes call
              ▼
[Zig]     CSV parser → columnar buffer (one typed array per column)
              │
              ▼
          aggregate → a value;  filter / groupby → a frame     (filter: not yet)
              │  borrowed pointer + shape info
              ▼
[Python]  df["column"], df.head(), df.shape
```

Every step but the marked one works today; filtering and aggregation are the
next phases.

The scope is deliberately narrow: multi-index, date/time types, NaN semantics,
join/merge and pivot tables are out. The goal is not a real table engine but a
teachable subset that genuinely works.
