# euspinolia

A small, educational Zig-accelerated table/CSV processing library. The core
data structures and operations live in Zig; Python gets a thin `ctypes` layer
on top.

The name comes from *Euspinolia*, the genus of the velvet ant known as the
"panda ant".

## Status

**Phase 1 — CSV parser.** The Zig side parses CSV into a row-major table and
infers a type per column. This is not reachable from Python yet: the FFI
surface is still the Phase 0 smoke-test functions. Columnar storage (Phase 2)
and the DataFrame interface (Phase 3) come next.

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
