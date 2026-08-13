# euspinolia

A small, educational Zig-accelerated table/CSV processing library. The core
data structures and operations live in Zig; Python gets a thin `ctypes` layer
on top.

The name comes from *Euspinolia*, the genus of the velvet ant known as the
"panda ant".

## Status

**Phase 2 — columnar storage.** The Zig side parses CSV, infers a type per
column, and stores the result column by column in a `DataFrame`. None of this
is reachable from Python yet: the FFI surface is still the Phase 0 smoke-test
functions, and exposing the DataFrame across it is Phase 3.

## Requirements

- Zig 0.16.0 or newer
- Python 3.9+

## Getting started

```sh
zig build                    # produces zig-out/lib/libeuspinolia.so
python3 -c "import euspinolia; euspinolia.self_check(); print(euspinolia.version())"
```

Current API:

```python
import euspinolia

euspinolia.ping()        # 3589 — constant signature from the Zig side
euspinolia.add(3, 4)     # 7 — argument passing check
euspinolia.version()     # "0.0.1"
euspinolia.self_check()  # raises RuntimeError on signature/version mismatch
```

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
between per-row allocations, and Phase 3 can hand Python a column as a flat
buffer without copying. A `DataFrame` owns its data in its own arena, so the
`Table` it came from can be freed immediately.

## Tests

```sh
zig build test                              # Zig unit tests
python3 -m unittest discover -s tests -v    # Python-side FFI tests
```

## Layout

```
build.zig               shared library build definition
src/root.zig            exported C ABI surface; symbols are prefixed with `eus_`
src/csv.zig             CSV scanner and the row-major Table
src/dtype.zig           column type inference
src/frame.zig           columnar DataFrame and the conversion into it
euspinolia/_ffi.py      library discovery, loading, ctypes signatures
euspinolia/__init__.py  Pythonic wrapper layer
tests/test_ffi.py       bridge tests
```

The library is looked up under `zig-out/lib/` by default; set `EUSPINOLIA_LIB`
to override the path.

## Target architecture

```
[Python]  df = euspinolia.read_csv("data.csv")
              │  ctypes call
              ▼
[Zig]     CSV parser → columnar buffer (one typed array per column)
              │
              ▼
          filter / groupby / aggregate → columnar buffer again
              │  pointer + shape info
              ▼
[Python]  df.head(), df["column"], df.to_list()
```

The scope is deliberately narrow: multi-index, date/time types, NaN semantics,
join/merge and pivot tables are out. The goal is not a real table engine but a
teachable subset that genuinely works.
