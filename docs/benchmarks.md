# Benchmarks

`bench/bench.py` times the same eight jobs in euspinolia, pandas and the
standard `csv` module plus plain Python, on a generated 18 MB CSV — 500,000
rows, 5 columns (`id`, `name`, `dept`, `salary`, `score`) — and prints the
best of five runs as a Markdown table.

## Running it

```sh
zig build                                                # or pip install -e .
python3 -m venv .venv && .venv/bin/pip install pandas    # optional
python3 bench/make_big.py                                # writes data/big.csv
.venv/bin/python bench/bench.py
```

`bench/make_big.py` takes an optional row count and output path. Without
pandas installed, the table just has one column fewer.

## Results

One laptop, pandas 3.0.5 (without pyarrow), Python 3.14, Zig 0.16,
ReleaseSafe. Run it yourself; the numbers will differ.

| | euspinolia | pandas | csv module + Python |
|---|---|---|---|
| read + parse | 114 ms | 183 ms | 335 ms |
| write back out (`to_csv`) | 63 ms | 478 ms | 294 ms |
| sum an int column | 0.2 ms | 0.2 ms | 10.1 ms |
| mean of a float column | 0.2 ms | 0.5 ms | 10.3 ms |
| filter `salary > 120,000` (keeps half the rows) | 10.5 ms | 8.7 ms | 13.8 ms |
| sort by `salary` | 40.7 ms | 69.8 ms | 110.6 ms |
| groupby `dept` (5 groups), mean `score` | 7.5 ms | 23.6 ms | 47.8 ms |
| groupby `dept`, count | 7.1 ms | 23.7 ms | 24.9 ms |

## Reading the table

**Parsing** is the headline: 3x faster than the `csv` module and ahead of
pandas, and the gap is not scanning alone. The `csv` module pays for a
Python tuple per row before any conversion; euspinolia hands back typed
columns Python never has to materialise.

**Writing** is the widest gap, 7x over pandas. `src/write.zig` walks the
typed columns and prints straight into one growing buffer; pandas formats
every cell through a Python object on the way to text.

**Reductions** are a wash against pandas, as they should be — both walk one
flat array in native code. The 50x over Python is the point of columnar
storage: Zig adds a `[]i64`, Python boxes half a million integers.

**Sorting** beats pandas' stable sort because numeric keys go through a
radix sort rather than comparisons: a few passes over contiguous
`(key, row)` pairs instead of `n log n` jumps to random rows (see
[internals](internals.md#sortzig--radix-for-numbers-comparisons-for-text)).
Most of what remains is gathering the text columns into the new order.

**GroupBy** is 3x faster than pandas here because the job is small: five
short keys, one aggregate. `src/groupby.zig` hashes each key straight into
a dense group id and folds into a flat accumulator array; pandas builds a
general `GroupBy` object that would keep winning as the job grew.

**Filtering is the one loss**, and a narrow one. The mask is one pass; the
gather that follows is branchless (see [internals](internals.md#framezig--columnar-storage)).
What remains is the two text columns: euspinolia copies every kept
string's bytes into a packed buffer, so the result owns its memory and
outlives the frame it came from, while pandas without pyarrow keeps a
string column as pointers to Python `str` objects and copies eight bytes
per row. The plain-Python comprehension likewise only copies references —
it has not built a frame.

Treat all of this as a sanity check that the Zig side is pulling its
weight, not as a published result: one machine, one file, and pandas is
doing more than euspinolia at every row.

## What is measured

Each cell is the best of five runs of one call, timed with
`time.perf_counter`:

| job | euspinolia | pandas | csv module + Python |
|---|---|---|---|
| read + parse | `read_csv(path)` | `pd.read_csv(path)` | `csv.reader` into a list of tuples, converting each field with `int`/`float` |
| write back out | `df.to_csv(path)` | `pdf.to_csv(path, index=False)` | `csv.writer` over the tuples |
| sum / mean | `df["salary"].sum()` | `pdf["salary"].sum()` | `sum(...)` over the tuples |
| filter | `df[df["salary"] > 120_000]` | `pdf[pdf["salary"] > 120_000]` | a list comprehension over the tuples |
| sort | `df.sort_values("salary")` | `pdf.sort_values("salary", kind="stable")` | `sorted(rows, key=...)` |
| groupby mean | `df.groupby("dept").agg({"score": "mean"})` | `pdf.groupby("dept")["score"].mean()` | two `defaultdict`s |
| groupby count | `df.groupby("dept").count()` | `pdf.groupby("dept").size()` | one `defaultdict` |

The euspinolia rows include freeing the result frame; the pandas rows leave
theirs to the garbage collector.
