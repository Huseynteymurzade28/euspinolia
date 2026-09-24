---
title: euspinolia
hide:
  - navigation
  - toc
---

<div class="eus-hero" markdown>

![euspinolia logo](assets/logo-black.png#only-light)
![euspinolia logo](assets/logo-white.png#only-dark)

# euspinolia

<p class="eus-tagline">A small CSV/table library for Python with its engine in Zig.
Typed columns, filter, sort, groupby — faster than pandas at most of it,
with no dependencies and a library that links nothing, not even libc.</p>

<div class="eus-install">pip install euspinolia</div>

[Read the API](api.md){ .md-button .md-button--primary }
[How it works](internals.md){ .md-button }
[GitHub](https://github.com/Huseynteymurzade28/euspinolia){ .md-button }

</div>

## In thirty seconds

```pycon
>>> import euspinolia
>>> df = euspinolia.read_csv("people.csv")
>>> df[df["age"] > 30].sort_values("score", ascending=False)[["name", "score"]]
    name  score
0    ada   91.5
1  grace   88.0

[2 rows x 2 columns]
>>> df.groupby("city").agg({"score": "mean"})
       city  score
0    London   91.5
1  New York   88.0
2     Paris  73.25

[3 rows x 2 columns]
```

Or without writing any Python:

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

## What's inside

<div class="grid cards" markdown>

-   :material-table-arrow-right: __Typed columns__

    ---

    Every column is `int`, `float` or `string`, inferred on parse and stored
    as one flat array. Numeric columns are read from Python without a copy.

-   :material-filter-variant: __Filter, select, sort__

    ---

    `df[df["age"] > 30]`, `df[["name", "age"]]`, and a stable
    `sort_values` that radix-sorts numeric keys.

-   :material-sigma: __Group and reduce__

    ---

    `groupby(...).agg({...})` hashes keys into dense ids and folds each
    group in one pass; sums stay exact in 64-bit integers.

-   :material-swap-horizontal: __In and out__

    ---

    CSV, TSV or any single-character delimiter, both ways, round-tripping
    types — plus `from_dict` and `to_dict` for data already in Python.

</div>

## Against pandas

500,000 rows, 5 columns, 18 MB, best of five on one laptop. Shorter is
faster; each pair is scaled to the slower of the two.

<div class="eus-bench">
  <div class="job">read + parse</div>
  <div class="bars"><div class="bar" style="width: 62%">114 ms</div><div class="bar other" style="width: 100%">183 ms</div></div>
  <div class="job">write CSV</div>
  <div class="bars"><div class="bar" style="width: 13%">63 ms</div><div class="bar other" style="width: 100%">478 ms</div></div>
  <div class="job">sort by an int</div>
  <div class="bars"><div class="bar" style="width: 58%">41 ms</div><div class="bar other" style="width: 100%">70 ms</div></div>
  <div class="job">groupby, mean</div>
  <div class="bars"><div class="bar" style="width: 32%">7.5 ms</div><div class="bar other" style="width: 100%">23.6 ms</div></div>
  <div class="job">filter half</div>
  <div class="bars"><div class="bar" style="width: 100%">10.5 ms</div><div class="bar other" style="width: 83%">8.7 ms</div></div>
</div>
<div class="eus-legend"><span>euspinolia</span><span class="other">pandas 3.0</span></div>

Filtering is the one loss: the result copies its strings so it can outlive
its source. The [benchmarks page](benchmarks.md) explains every row.

## Why it exists

It is a teaching project with a fixed scope — one header row, three column
types, the operations above — small enough to read end to end in an
afternoon: about 3,700 lines of Zig with tests, and 1,250 of Python. The
[internals](internals.md) walk through it module by module, from the CSV
scanner to the C ABI.

The name is *Euspinolia*, the genus of the velvet ant known as the
"panda ant".
