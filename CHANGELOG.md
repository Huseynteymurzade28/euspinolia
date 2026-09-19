# Changelog

## Unreleased

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
