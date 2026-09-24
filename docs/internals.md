# Internals

How the Zig side is put together, module by module, in the order data flows
through it. Every file is under `src/`.

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

## `csv.zig` — the scanner

`Table.parseFile` reads the whole file into an arena, and a `Scanner` walks
the bytes once, yielding one field at a time and flagging the last field of
each record. The output is row-major: a header slice and one
`[]const []const u8` per record, where each field is a slice into the
original bytes — or, for a quoted field that contained `""`, into an
unescaped copy in the arena. Nothing is parsed as a number yet.

The parser accepts the subset of RFC 4180 listed in the
[API reference](api.md#what-counts-as-csv) and rejects the rest with a typed
error (`UnterminatedQuote`, `UnexpectedCharacterAfterQuote`,
`InconsistentFieldCount`, `MissingHeader`) that `ffi.zig` later maps to a
status code. The delimiter arrives in `csv.Options` as a single byte, which
keeps the scanner's inner loop a comparison against two constants; a quote
or a line break is refused up front with `InvalidDelimiter`, since either
would make the grammar ambiguous.

The `Table` is only a staging form. It exists so that type inference can see
a whole column before anything is allocated for it.

## `dtype.zig` — type inference

`infer` looks at every cell of a column and returns the narrowest of
`int`, `float`, `string` that holds all of them. It tries
`std.fmt.parseInt(i64)` first, then `parseFloat(f64)`, and gives up to
`string` on the first cell that fails both. Three cases are text on purpose
even though Zig's parsers would accept them: an empty cell (there is no
null), `nan` / `inf` (non-finite values are out of scope), and the
source-literal forms `0x10` and `1_000`.

## `frame.zig` — columnar storage

`DataFrame.fromTable` turns the row-major table into one typed array per
column (struct of arrays), which is what everything downstream reads:

- `int` and `float` columns are flat `[]i64` / `[]f64`.
- `string` columns are one packed byte buffer plus `row_count + 1` offsets
  into it: value `i` is `data[offsets[i]..offsets[i + 1]]`. An empty string
  costs nothing but a repeated offset.

A filter or an aggregate then walks one contiguous array instead of hopping
between per-row allocations, and Python reads a numeric column as a flat
buffer without copying.

Every frame owns its data in its own `ArenaAllocator`, so the `Table` it
came from is freed immediately after conversion, and freeing a frame is one
`arena.deinit()`. The frames a filter or a groupby produce get their own
arena too, which is why they outlive their source.

`DataFrame.take(mask)` is the gather behind filtering. Both its loops are
branchless: every row is written, and the write cursor advances only when
the mask bit is set —

```zig
for (values, mask) |value, keep| {
    out[at] = value;
    at += @intFromBool(keep);
}
```

— with one slot of slack at the end so the unconditional store stays in
bounds (for strings, the slack is the longest value). A `continue` on a
mask the CPU cannot predict cost more than the copy itself: filtering half
of 500,000 rows went from 10 ms to 3 ms on the numeric columns alone.

## `agg.zig` — reductions

`sum`, `min`, `max` and `mean` over one column. Integer sums use `i64` with
overflow detection (`SumOverflow`) rather than promoting to float, so an
integer column sums exactly. `mean` is always `f64`. Text columns are
rejected with `NotNumeric`, empty ones with `EmptyColumn`.

## `filter.zig` — row selection

Two steps. `compare` fills a `[]bool` mask by comparing every value of one
column against a constant with one of six operators; a numeric column takes
an `int` or `float` constant (an `int` column compared with a float is
compared in `f64`), a text column takes a string and compares bytewise, and
a mismatch is `TypeMismatch`. Then `DataFrame.take` gathers the rows the
mask kept into a new frame.

The Python `Condition` never builds a mask of its own: `df[a & b]` applies
`a` and then `b` to the result, two Zig calls, no mask arithmetic.

## `groupby.zig` — hash the keys, fold per group

Two passes, and no per-group allocation:

1. Walk the key column once and hash every value into a dense group id —
   `std.AutoHashMap` for numbers, `std.StringHashMap` for text, keyed by
   slices into the column's own data buffer so no key is copied. Afterwards
   each row knows its group as a `u32`, and the map is dropped.
2. Walk each requested value column once, folding every row into its
   group's accumulator: a flat array with one slot per group. `sum`, `min`
   and `max` keep the column's type, `mean` accumulates an `f64` and a
   count, `count` only counts.

Nothing is sorted. The result rows come out in the order the keys were
first seen, with the key as the first column and the requested aggregates
after it.

## `write.zig` — serialisation

Walks the typed columns and prints straight into an `std.Io.Writer`, one
record per row. A field is quoted only when it holds a comma, a quote or a
line break. Floats use the shortest round-trip decimal and are forced to
carry a `.` or an exponent, so the output infers back to the same column
types; very large and very small magnitudes go scientific. `toOwnedSlice`
collects the text into one buffer for the ABI.

## `ffi.zig` — the C ABI

The whole surface Python calls, and it keeps three rules:

- A frame crosses as an opaque pointer, created by `eus_read_csv`,
  `eus_parse_csv`, `eus_frame_filter_*` or `eus_frame_groupby` and released
  by `eus_frame_free`. Nothing else owns it.
- Zig error sets do not survive the C ABI, so fallible functions return an
  `i32` status and write their result through an out-parameter. The mapping
  from Zig errors to status codes happens once, in `statusFor`;
  `eus_status_message` turns a code back into text. The codes are part of
  the ABI: appended to, never renumbered.
- Column data is handed out as borrowed pointers into the frame's arena.
  They are valid until the frame is freed, and the caller must not write to
  them. The one exception is the CSV text from `eus_frame_to_csv`, which is
  owned by the caller and released with `eus_bytes_free`.

Every symbol is prefixed `eus_`. Tag numbers — column types, comparison
operators, aggregate functions — are pinned by tests on both sides so the
two cannot drift apart silently. The allocator behind the ABI is
`std.heap.smp_allocator` in release builds and a `DebugAllocator` in Debug,
which catches leaks in the Zig test suite.

`root.zig` re-exports the modules and keeps the original bridge
smoke-tests (`eus_ping`, `eus_add`, `eus_version`), which
`euspinolia.self_check()` still uses to notice a stale library.

## The Python side

`euspinolia/_ffi.py` finds the shared library — `EUSPINOLIA_LIB` if set,
then `zig-out/` in a source checkout, then the copy inside the installed
package — loads it with `ctypes.CDLL`, and declares every function's
argument and return types (without which `ctypes` assumes 32-bit `int`
everywhere and silently truncates). `check()` turns a status code into the
matching Python exception.

`euspinolia/__init__.py` is the object layer. `DataFrame` holds the handle
and caches names and dtypes. `Column` wraps a numeric column as a
`ctypes` array built with `from_address` over the borrowed pointer, so
`column[i]` is an array index; a string column keeps the offsets array and
the byte buffer the same way and decodes one value per access. `Condition`
and `GroupBy` are lazy: they record what was asked and make one Zig call
when applied.
