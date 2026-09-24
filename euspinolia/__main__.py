"""Command line: a quick look at a CSV file without writing any Python.

    euspinolia stats data.csv
    euspinolia head data.csv -n 20
    python -m euspinolia stats data.tsv --delimiter '\\t'
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import Any, Sequence

import euspinolia
from euspinolia import ColumnType, DataFrame


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="euspinolia",
        description="Inspect CSV files with euspinolia's Zig engine.",
    )
    parser.add_argument("--version", action="version", version=f"euspinolia {euspinolia.__version__}")
    commands = parser.add_subparsers(dest="command", required=True, metavar="command")

    stats = commands.add_parser("stats", help="types, ranges and distinct counts per column")
    head = commands.add_parser("head", help="the first rows as a table")
    head.add_argument("-n", "--rows", type=int, default=10, help="how many rows (default 10)")
    for command in (stats, head):
        command.add_argument("path", help="the CSV file")
        command.add_argument(
            "-d",
            "--delimiter",
            default=",",
            type=_unescape,
            help="field delimiter, e.g. ';' or '\\t' (default ',')",
        )

    args = parser.parse_args(argv)
    try:
        started = time.perf_counter()
        df = euspinolia.read_csv(args.path, delimiter=args.delimiter)
        elapsed = time.perf_counter() - started
    except (OSError, ValueError) as error:
        print(f"euspinolia: {error}", file=sys.stderr)
        return 1

    with df:
        if args.command == "stats":
            print(_stats(df, args.path, elapsed))
        else:
            print(df._render(max(args.rows, 0)))
    return 0


def _unescape(text: str) -> str:
    # A shell hands over `'\t'` as a backslash and a `t`.
    return {"\\t": "\t", "tab": "\t"}.get(text, text)


def _stats(df: DataFrame, path: str, elapsed: float) -> str:
    rows, columns = df.shape
    size = os.path.getsize(path)
    lines = [
        f"{path}: {rows:,} rows x {columns} columns, {_size(size)}, parsed in {elapsed * 1000:.0f} ms",
        "",
    ]

    table = [["column", "type", "min", "max", "mean", "distinct"]]
    for name, dtype in zip(df.columns, df.dtypes):
        column = df[name]
        with df.groupby(name).count() as groups:
            distinct = f"{len(groups):,}"
        if dtype is ColumnType.STRING or rows == 0:
            table.append([name, str(dtype), "", "", "", distinct])
        else:
            table.append(
                [
                    name,
                    str(dtype),
                    _number(column.min()),
                    _number(column.max()),
                    _number(column.mean()),
                    distinct,
                ]
            )

    widths = [max(len(row[i]) for row in table) for i in range(len(table[0]))]
    for i, row in enumerate(table):
        # Names and types read left to right; numbers line up on the right.
        cells = [cell.ljust(w) if j < 2 else cell.rjust(w) for j, (cell, w) in enumerate(zip(row, widths))]
        lines.append("  ".join(cells).rstrip())
        if i == 0:
            lines.append("  ".join("-" * w for w in widths))
    return "\n".join(lines)


def _number(value: Any) -> str:
    # Rounded for reading, but still a float: `100.0`, not `100`.
    return repr(round(value, 3)) if isinstance(value, float) else str(value)


def _size(size: int) -> str:
    if size < 1000:
        return f"{size} B"
    scaled = float(size)
    for unit in ("KB", "MB", "GB"):
        scaled /= 1000
        if scaled < 1000:
            break
    return f"{scaled:.1f} {unit}"


if __name__ == "__main__":
    sys.exit(main())
