# Changelog

## 0.2.0 — 2026-09-24

- `read_csv`, `parse_csv` and `to_csv` take a keyword-only `delimiter`:
  `";"`, `"\t"` for TSV, or any other single ASCII character but a quote or
  a line break.
- `df[["name", "age"]]` and `df.select([...])` pick columns into a new frame.
- `df.sort_values(by, ascending=True)`: a stable sort by one column, radix
  for numbers, faster than pandas' stable sort on the benchmark.
- `from_dict({...})` builds a frame from Python data, typing each column by
  its values; `df.to_dict()` is the inverse.
- An `euspinolia` command: `stats` for types, ranges and distinct counts per
  column, `head` for the first rows. Also `python -m euspinolia`.
- Fixed: in a one-column frame, `to_csv` wrote an empty string as a blank
  line, which the parser skips, so the row was lost on reading it back.
- Column lookup no longer accepts a `bool` as a position.
- The C ABI changed (`eus_read_csv`, `eus_parse_csv` and `eus_frame_to_csv`
  take a delimiter); the library and its Python layer ship together, and
  `self_check` catches a mismatched pair.

## 0.1.1 — 2026-09-19

- Wheels for 32-bit ARM Linux (`armv7l`), so Raspberry Pi OS installs do
  not fall back to a source build; Zig 0.16.0 cannot build on a 32-bit host.

## 0.1.0 — 2026-09-16

First release.

- `read_csv` / `parse_csv`: a subset of RFC 4180 parsed in Zig into typed
  columns (`int`, `float`, `string`), with per-column type inference.
- `DataFrame` and `Column`: shape, names, dtypes, indexing, slicing,
  iteration, `head`, `row`; numeric columns are read through the Zig buffer
  without copying.
- Reductions: `sum`, `mean`, `min`, `max`, keeping the column's type.
- Filtering: `df.filter(column, op, value)` and `df[df["age"] > 30]`, with
  `&` to chain conditions.
- `groupby(key).agg({...})` with `sum`, `mean`, `min`, `max`, `count`, plus
  the `.sum()` / `.mean()` / `.min()` / `.max()` / `.count()` shortcuts.
- `to_csv`: serialise a frame back out, round-tripping types.
- Wheels for Linux (x86_64, aarch64), macOS (x86_64, arm64) and Windows
  (x64, arm64), all cross-compiled from one machine since the library links
  nothing, not even libc. The sdist builds anywhere with `pip`, pulling Zig
  from the `ziglang` package.
