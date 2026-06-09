#!/usr/bin/env python3
"""Render a quick chart (PNG) from a CSV/TSV/JSON file with matplotlib.

Zero-config for the common cases; install matplotlib on demand if missing.

Usage:
  chart.py sales.csv --x month --y revenue --type line --out rev.png
  chart.py sales.csv --x region --y sales --type bar --title "Sales by region"
  chart.py points.csv --x age --y income --type scatter
  chart.py values.csv --y score --type hist --bins 20
"""
import argparse
import csv
import json
import os
import sys


def load_columns(path):
    """Return (rows_as_dicts, fieldnames) using stdlib only."""
    ext = os.path.splitext(path)[1].lower()
    if ext in (".json", ".jsonl", ".ndjson"):
        rows = []
        with open(path, encoding="utf-8", errors="replace") as f:
            if ext == ".json":
                data = json.load(f)
                if isinstance(data, dict):
                    for k in ("data", "results", "items", "rows", "records"):
                        if isinstance(data.get(k), list):
                            data = data[k]
                            break
                    else:
                        data = [data]
                rows = [r for r in data if isinstance(r, dict)]
            else:
                for line in f:
                    line = line.strip()
                    if line:
                        obj = json.loads(line)
                        if isinstance(obj, dict):
                            rows.append(obj)
        fields = list(rows[0].keys()) if rows else []
        return rows, fields
    delim = "\t" if ext == ".tsv" else ","
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.DictReader(f, delimiter=delim)
        rows = list(r)
        return rows, list(r.fieldnames or [])


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    p = argparse.ArgumentParser(description="Quick chart to PNG.")
    p.add_argument("path")
    p.add_argument("--x", help="x-axis column (categories or numbers)")
    p.add_argument("--y", action="append", help="y-axis column(s); repeatable")
    p.add_argument("--type", default="line", choices=["line", "bar", "scatter", "hist"])
    p.add_argument("--out", default="chart.png")
    p.add_argument("--title", default="")
    p.add_argument("--bins", type=int, default=20)
    args = p.parse_args()

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("matplotlib not installed:  pip install matplotlib")

    if not os.path.isfile(args.path):
        sys.exit(f"no such file: {args.path}")
    rows, fields = load_columns(args.path)
    if not rows:
        sys.exit("no rows to plot")
    ys = args.y or []
    if not ys and args.type != "hist":
        sys.exit("provide at least one --y column")

    fig, ax = plt.subplots(figsize=(9, 5))

    if args.type == "hist":
        col = (args.y or [args.x])[0]
        vals = [num(r.get(col)) for r in rows]
        vals = [v for v in vals if v is not None]
        ax.hist(vals, bins=args.bins)
        ax.set_xlabel(col)
        ax.set_ylabel("count")
    else:
        xcol = args.x or fields[0]
        xs = [r.get(xcol) for r in rows]
        x_is_num = all(num(v) is not None for v in xs if v not in (None, ""))
        xs_plot = [num(v) for v in xs] if x_is_num else list(range(len(xs)))
        for ycol in ys:
            yv = [num(r.get(ycol)) for r in rows]
            if args.type == "line":
                ax.plot(xs_plot, yv, marker="o", label=ycol)
            elif args.type == "scatter":
                ax.scatter(xs_plot, yv, label=ycol)
            elif args.type == "bar":
                ax.bar([i for i in range(len(xs))], yv, label=ycol)
        if not x_is_num or args.type == "bar":
            ax.set_xticks(range(len(xs)))
            ax.set_xticklabels([str(v) for v in xs], rotation=45, ha="right", fontsize=8)
        ax.set_xlabel(xcol)
        if len(ys) > 1:
            ax.legend()

    if args.title:
        ax.set_title(args.title)
    fig.tight_layout()
    fig.savefig(args.out, dpi=120)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
