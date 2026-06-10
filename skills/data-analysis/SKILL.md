---
name: data-analysis
requires: python3
description: >
  Explore and analyze tabular data — CSV, TSV, Excel (.xlsx), Parquet, and JSON —
  with DuckDB (SQL over files, no server) and pandas, plus a zero-dependency data
  profiler. Use whenever the user wants to analyze, summarize, aggregate, join,
  filter, clean, or chart a dataset; understand what's in a CSV/spreadsheet/Parquet
  file; compute stats or group-bys; detect nulls/dupes/outliers; or build a quick
  data pipeline. Complements the document skill (which writes .xlsx) by reading and
  crunching data. Trigger phrases: "analyze this CSV", "what's in this dataset",
  "summarize the data", "group by", "join these files", "profile this data",
  "plot a chart of", "clean this spreadsheet", "query the parquet file".
---

# Data analysis (DuckDB + pandas)

Analyze data files with **no database server**. Reach for the lightest tool that
fits:

| Need | Use |
|------|-----|
| Understand an unfamiliar file fast (schema, nulls, ranges, samples) | **`profile.py`** (bundled, stdlib) |
| SQL over CSV/Parquet/JSON files (filter, group, join, aggregate) | **DuckDB** (`dsql.sh`) |
| Row-wise transforms, reshaping, ML-prep, fine control | **pandas** (Python) |
| A quick chart (line/bar/scatter/hist) | **`chart.py`** (bundled, matplotlib) |

```
skills/data-analysis/
├── SKILL.md
├── scripts/
│   ├── profile.py      # dataset profiler — stdlib for CSV/TSV/JSON/JSONL/XLSX
│   ├── dsql.sh         # DuckDB SQL-over-files wrapper
│   └── chart.py        # quick PNG charts (matplotlib)
└── references/
    ├── duckdb-recipes.md
    └── pandas-recipes.md
```

`run_command` runs from the **workspace root**, so call e.g.
`python3 skills/data-analysis/scripts/profile.py <file>`.

## Start here: profile the file

Before analyzing anything, profile it — this is the highest-leverage first move:

```bash
python3 skills/data-analysis/scripts/profile.py data.csv
python3 skills/data-analysis/scripts/profile.py data.parquet --json
```
It prints rows × columns, and per column: inferred type, null count/%, distinct
count, min/max (and mean for numerics), and sample values. CSV/TSV/JSON/JSONL work
with **no dependencies** (it streams, so big CSVs are fine); XLSX needs `openpyxl`,
and Parquet uses DuckDB or pandas — the script says exactly what to install when a
format's dependency is missing.

## SQL over files with DuckDB (no server)

DuckDB queries files directly and is the workhorse for filter/group/join/aggregate.

```bash
skills/data-analysis/scripts/dsql.sh "SELECT * FROM 'sales.csv' LIMIT 5"
skills/data-analysis/scripts/dsql.sh \
  "SELECT region, sum(amount) AS total FROM 'sales.parquet' GROUP BY 1 ORDER BY 2 DESC" \
  --format markdown
skills/data-analysis/scripts/dsql.sh \
  "SELECT * FROM 'orders.csv' o JOIN 'customers.csv' c USING(customer_id)" --format csv
```
Quote the path inside the SQL (`FROM 'file.csv'`), or use `read_csv_auto(...)`,
`read_parquet(...)`, `read_json_auto(...)` for options. DuckDB also reads remote
files (S3/HTTP) via its `httpfs` extension. If DuckDB isn't installed, `dsql.sh`
prints the one-line install command. Full patterns: `references/duckdb-recipes.md`.

## pandas for transforms

When you need row-wise logic, reshaping (pivot/melt), datetime handling, or
ML-prep, use pandas in a `python3 - <<'PY' … PY` heredoc. DuckDB and pandas
interoperate (`duckdb.sql(...).df()` ⇄ `duckdb.sql("FROM df")`). Common recipes:
`references/pandas-recipes.md`.

## Charts

```bash
python3 skills/data-analysis/scripts/chart.py sales.csv --x month --y revenue --type line --out rev.png
python3 skills/data-analysis/scripts/chart.py sales.csv --x region --y sales --type bar
python3 skills/data-analysis/scripts/chart.py values.csv --y score --type hist --bins 30
```
Writes a PNG (default `chart.png`). Needs matplotlib (`pip install matplotlib`); the
script tells you if it's missing.

## Installing the optional tools

The profiler needs nothing. For the rest:
```bash
curl https://install.duckdb.org | sh     # DuckDB CLI (or: brew install duckdb)
pip install duckdb pandas pyarrow matplotlib openpyxl
```
`openpyxl` lets the profiler read `.xlsx`; `pyarrow` lets pandas/DuckDB read
Parquet. No `python3`/`pip` on the machine at all? Get one with the
**install-runtimes** skill (`uv`-managed Python works on Alpine too).

## Tips & gotchas

- **Always profile first** — it catches the surprises (wrong delimiter, stray
  header rows, a "number" column stored as text, unexpected nulls) before you write
  queries against bad assumptions.
- **DuckDB > pandas for big files** — it's columnar and out-of-core; pandas loads
  everything into RAM. Use DuckDB to filter/aggregate down, then pandas for the rest.
- **Excel quirks** — `.xlsx` analysis reads the active sheet; for a specific sheet,
  convert to CSV first or use pandas `read_excel(sheet_name=...)`.
- **Big output** — `run_command` truncates very large output. Use `LIMIT`, write
  results to a file (`… --format csv > out.csv`), and summarize.
- **To *create* polished .xlsx/.csv reports**, hand off to the
  `create-pdf-pptx-xlsx-docx` skill; this skill is for reading and crunching.
