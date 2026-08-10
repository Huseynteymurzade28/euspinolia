# euspinolia

A small, educational Zig-accelerated table/CSV processing library. The core
data structures and operations live in Zig; Python gets a thin `ctypes` layer
on top.

The name comes from *Euspinolia*, the genus of the velvet ant known as the
"panda ant".

## Status

**Phase 0 — FFI bridge.** No table processing yet. What works today is the
verified path from Python into the Zig library across the C ABI. The CSV
parser, columnar storage and DataFrame interface come in later phases.

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

## Tests

```sh
zig build test                              # Zig unit tests
python3 -m unittest discover -s tests -v    # Python-side FFI tests
```

## Layout

```
build.zig               shared library build definition
src/root.zig            Zig core; exported symbols are prefixed with `eus_`
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
