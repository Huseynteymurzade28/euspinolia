<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Huseynteymurzade28/euspinolia/main/assets/logo-white.png">
    <img src="https://raw.githubusercontent.com/Huseynteymurzade28/euspinolia/main/assets/logo-black.png" alt="euspinolia logo: a velvet ant forming the letter E" width="180">
  </picture>
</p>

<h1 align="center">euspinolia</h1>

<p align="center">
  <a href="https://github.com/Huseynteymurzade28/euspinolia/actions/workflows/ci.yml"><img src="https://github.com/Huseynteymurzade28/euspinolia/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://pypi.org/project/euspinolia/"><img src="https://img.shields.io/pypi/v/euspinolia?cacheSeconds=3600" alt="PyPI"></a>
  <a href="https://pypi.org/project/euspinolia/"><img src="https://img.shields.io/pypi/pyversions/euspinolia?cacheSeconds=3600" alt="Python"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

A small, educational CSV/table library with its engine in Zig and a thin
`ctypes` layer in Python. It parses a CSV into typed columns, reduces,
filters, sorts and groups them, and writes them back out — faster than
pandas for most of that, with no dependencies and a shared library that
links nothing, not even libc.

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
>>> df.sort_values("score", ascending=False)[["name", "score"]]
        name  score
0        ada   91.5
1      grace   88.0
2  Doe, John  73.25

[3 rows x 2 columns]
>>> df.groupby("city").agg({"score": "mean"})
       city  score
0    London   91.5
1  New York   88.0
2     Paris  73.25

[3 rows x 2 columns]
```

## Install

```sh
pip install euspinolia
```

Wheels are published for Linux (x86_64, aarch64, armv7l), macOS (x86_64,
arm64) and Windows (x64, arm64), for any Python 3.9 or newer. On anything else,
`pip` builds from source; that needs no Zig install either, since the build
pulls it from the `ziglang` package.

Then take a first look at a file without writing any Python:

```console
$ euspinolia stats data.csv
data.csv: 500,000 rows x 5 columns, 18.0 MB, parsed in 108 ms

column  type      min     max        mean  distinct
------  ------  -----  ------  ----------  --------
id      int         0  499999    249999.5   500,000
name    string                              500,000
dept    string                                    5
salary  int     40000  199999  119926.142   152,970
score   float     0.0   100.0      49.973    10,001
```

`euspinolia head data.csv -n 20` prints the first rows, and both take
`--delimiter` (`';'`, `'\t'`). `python -m euspinolia` works too.

To work from a checkout instead, see [docs/development.md](docs/development.md).

## What it does

```python
import euspinolia

df = euspinolia.read_csv("people.csv")                    # parse a file
df = euspinolia.read_csv("people.tsv", delimiter="\t")    # or TSV, or ';'
df = euspinolia.parse_csv(csv_text)                       # parse text already in memory
df = euspinolia.from_dict({"name": ["ada"], "age": [36]})  # or build it from Python

df.shape          # (3, 4) — (rows, columns)
df.columns        # ('name', 'age', 'score', 'city')
df.dtypes         # (string, int, float, string)
df.head(2)        # the first two rows as tuples

column = df["age"]   # by name; df[1] works too
column[0]            # 36 — read straight out of the Zig buffer
column.to_list()     # [36, 45, 29]

column.sum()      # 110 — exact, reduced in Zig
column.mean()     # 36.666666666666664
column.min()      # 29
column.max()      # 45

df[["name", "age"]]                         # a new DataFrame with those columns
df[df["age"] > 30]                          # a new DataFrame with the matching rows
df[(df["age"] > 30) & (df["score"] < 90)]   # conditions chain with &
df.filter("city", "==", "Paris")            # the same thing, as a call
df.sort_values("age", ascending=False)      # rows ordered by one column, stably

df.groupby("city").agg({"score": "mean", "age": "max"})   # one row per city
df.groupby("city").sum()                                  # every numeric column
df.groupby("city").count()                                # rows per group

df.to_csv("out.csv")   # write it back out; reads back as the same frame
df.to_csv()            # or as a string
df.to_dict()           # or as {"name": [...], "age": [...]}

with euspinolia.read_csv("people.csv") as df:
    ...   # Zig-side memory freed on the way out; df.close() does the same
```

Every column has one type — `int`, `float` or `string` — inferred from
its values. Reductions keep that type, so an integer column sums exactly.
A selected, filtered, sorted or grouped frame owns its own memory and
outlives its source.
Errors are ordinary Python exceptions: `FileNotFoundError`, `ParseError`,
`TypeError` for text where a number was needed, `OverflowError` for a sum
that leaves 64 bits.

The full reference is in [docs/api.md](docs/api.md).

## Performance

500,000 rows, 5 columns, 18 MB; best of five on one laptop, against pandas
3.0 and the standard `csv` module:

| | euspinolia | pandas | csv module + Python |
|---|---|---|---|
| read + parse | 114 ms | 183 ms | 335 ms |
| write back out (`to_csv`) | 63 ms | 478 ms | 294 ms |
| sum an int column | 0.2 ms | 0.2 ms | 10.1 ms |
| filter, keeping half the rows | 10.5 ms | 8.7 ms | 13.8 ms |
| sort by an int column | 40.7 ms | 69.8 ms | 110.6 ms |
| groupby (5 groups), mean | 7.5 ms | 23.6 ms | 47.8 ms |

Parsing, writing, sorting and grouping are ahead of pandas — sorting
because numeric keys go through a radix sort. Reductions are a wash, as
native code against native code should be; filtering is the one loss,
because the result copies its strings rather than sharing them. What each
number means, and how to run the benchmark yourself, is in
[docs/benchmarks.md](docs/benchmarks.md).

## How it works

```
[Python]  df = euspinolia.read_csv("data.csv")
              │  ctypes call
              ▼
[Zig]     CSV scanner → type inference → one typed array per column
              │
              ├─▶ sum / mean / min / max   → one value
              ├─▶ select, filter, sort,
              │   groupby                  → a new frame
              └─▶ to_csv                   → bytes
              │  opaque handle + borrowed column pointers
              ▼
[Python]  DataFrame / Column wrap the handle; df["age"][0] reads the
          Zig buffer through ctypes, no copy
```

Columns are struct-of-arrays: `int` and `float` are flat `[]i64` / `[]f64`,
strings are one packed byte buffer plus offsets. A filter or an aggregate
walks one contiguous array; a groupby hashes each key into a dense group id
and folds into a flat accumulator; Python reads numeric columns in place.
Module by module: [docs/internals.md](docs/internals.md).

## Scope

This is a teaching project, and the scope was fixed at the start: one
delimiter per file, one header row, three column types, and the operations
above.
Multi-index, date/time types, NaN semantics, join/merge and pivot tables
are out, on purpose. The goal is not a real table engine but a subset that
genuinely works, is fast for real reasons, and can be read end to end in an
afternoon — about 3,700 lines of Zig, tests included, and 1,250 of
Python.

## Documentation

Everything below is also published as a site:
**[huseynteymurzade28.github.io/euspinolia](https://huseynteymurzade28.github.io/euspinolia/)**.

- [API reference](docs/api.md) — every function, method, argument and exception
- [Internals](docs/internals.md) — the Zig side, module by module, and the ABI
- [Benchmarks](docs/benchmarks.md) — the numbers above, what they measure and why they come out that way
- [Development](docs/development.md) — building, testing, cross-compiling wheels, releasing
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE).
