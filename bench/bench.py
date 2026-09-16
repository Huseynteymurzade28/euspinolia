"""Benchmark euspinolia against pandas and the standard csv module.

    zig build
    python3 bench/make_big.py          # once, writes data/big.csv
    python3 bench/bench.py [path]

Each case is timed as the best of several runs and printed as a Markdown
table. pandas is optional: without it, only the csv-module rows are shown.
"""

from __future__ import annotations

import csv
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import euspinolia  # noqa: E402

try:
    import pandas as pd
except ImportError:  # pragma: no cover - the table just gets shorter
    pd = None

RUNS = 5
SALARY_CUTOFF = 120_000


def best_of(fn, runs=RUNS):
    times = []
    for _ in range(runs):
        start = time.perf_counter()
        fn()
        times.append(time.perf_counter() - start)
    return min(times)


def fmt(seconds):
    if seconds >= 1:
        return f"{seconds:.2f} s"
    return f"{seconds * 1e3:.1f} ms"


def csv_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        next(reader)
        return [(int(i), n, d, int(s), float(sc)) for i, n, d, s, sc in reader]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "data/big.csv"
    if not Path(path).exists():
        sys.exit(f"{path} not found; run bench/make_big.py first")

    df = euspinolia.read_csv(path)
    rows = csv_rows(path)
    pdf = pd.read_csv(path) if pd else None
    size_mb = Path(path).stat().st_size / 1e6
    print(f"{path}: {len(df):,} rows x {df.shape[1]} columns, {size_mb:.1f} MB")
    print(f"best of {RUNS} runs\n")

    # Each case: (label, euspinolia, pandas, csv module). None hides a cell.
    cases = [
        (
            "read + parse",
            lambda: euspinolia.read_csv(path).close(),
            (lambda: pd.read_csv(path)) if pd else None,
            lambda: csv_rows(path),
        ),
        (
            "sum an int column",
            lambda: df["salary"].sum(),
            (lambda: pdf["salary"].sum()) if pd else None,
            lambda: sum(r[3] for r in rows),
        ),
        (
            "mean of a float column",
            lambda: df["score"].mean(),
            (lambda: pdf["score"].mean()) if pd else None,
            lambda: sum(r[4] for r in rows) / len(rows),
        ),
        (
            f"filter salary > {SALARY_CUTOFF:,}",
            lambda: df[df["salary"] > SALARY_CUTOFF].close(),
            (lambda: pdf[pdf["salary"] > SALARY_CUTOFF]) if pd else None,
            lambda: [r for r in rows if r[3] > SALARY_CUTOFF],
        ),
        (
            "groupby dept, mean score",
            lambda: df.groupby("dept").agg({"score": "mean"}).close(),
            (lambda: pdf.groupby("dept")["score"].mean()) if pd else None,
            lambda: _py_groupby_mean(rows),
        ),
        (
            "groupby dept, count",
            lambda: df.groupby("dept").count().close(),
            (lambda: pdf.groupby("dept").size()) if pd else None,
            lambda: _py_groupby_count(rows),
        ),
    ]

    header = ["", "euspinolia"] + (["pandas"] if pd else []) + ["csv module + Python"]
    table = [header, ["---"] * len(header)]
    for label, eus, pandas_fn, py in cases:
        t_eus = best_of(eus)
        cells = [label, fmt(t_eus)]
        if pd:
            cells.append(fmt(best_of(pandas_fn)))
        t_py = best_of(py)
        cells.append(f"{fmt(t_py)} ({t_py / t_eus:.0f}x)")
        table.append(cells)

    widths = [max(len(row[i]) for row in table) for i in range(len(header))]
    for row in table:
        print("| " + " | ".join(c.ljust(w) for c, w in zip(row, widths)) + " |")

    if pd:
        print(f"\npandas {pd.__version__}", end="")
    print(f", euspinolia {euspinolia.__version__}, Python {sys.version.split()[0]}")


def _py_groupby_mean(rows):
    totals = defaultdict(float)
    counts = defaultdict(int)
    for r in rows:
        totals[r[2]] += r[4]
        counts[r[2]] += 1
    return {k: totals[k] / counts[k] for k in totals}


def _py_groupby_count(rows):
    counts = defaultdict(int)
    for r in rows:
        counts[r[2]] += 1
    return counts


if __name__ == "__main__":
    main()
