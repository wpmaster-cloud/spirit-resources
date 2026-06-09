# pandas recipes (row-wise transforms & reshaping)

Use pandas when you need row-wise logic, reshaping, datetime handling, or ML-prep —
the things SQL is awkward at. Run inside a heredoc:

```bash
python3 - <<'PY'
import pandas as pd
df = pd.read_csv("data.csv")
# ... work ...
df.to_csv("out.csv", index=False)
PY
```

## Load / inspect

```python
df = pd.read_csv("data.csv")          # parse_dates=["date"], dtype={...}, sep=";"
df = pd.read_excel("book.xlsx", sheet_name="Sheet1")   # needs openpyxl
df = pd.read_parquet("data.parquet")  # needs pyarrow
df = pd.read_json("data.json")        # lines=True for JSONL

df.head(); df.shape; df.dtypes
df.info(); df.describe(include="all")
df.isna().sum()                       # nulls per column
df["col"].value_counts(dropna=False)  # category frequencies
```

## Clean

```python
df = df.drop_duplicates()
df = df.dropna(subset=["important"])               # drop rows missing a key field
df["amount"] = pd.to_numeric(df["amount"], errors="coerce")   # text→number, bad→NaN
df["date"]   = pd.to_datetime(df["date"], errors="coerce")
df["name"]   = df["name"].str.strip().str.title()
df = df.fillna({"amount": 0, "region": "unknown"})
df = df.rename(columns={"amt": "amount"})
df.columns = df.columns.str.strip().str.lower().str.replace(" ", "_")
```

## Filter / derive

```python
big = df[df["amount"] > 100]
recent = df[df["date"] >= "2026-01-01"]
df["with_tax"] = df["amount"] * 1.17
df["bucket"] = pd.cut(df["amount"], bins=[0, 50, 200, 1e9], labels=["S", "M", "L"])
df = df.assign(margin=lambda d: (d.revenue - d.cost) / d.revenue)
```

## Group / aggregate

```python
g = df.groupby("region")["amount"].agg(["count", "sum", "mean"])
g = df.groupby(["region", "month"]).agg(total=("amount", "sum"),
                                        orders=("id", "nunique")).reset_index()
top = df.sort_values("amount", ascending=False).groupby("region").head(3)   # top 3 per region
df["region_total"] = df.groupby("region")["amount"].transform("sum")        # broadcast back
```

## Reshape & join

```python
wide = df.pivot_table(index="month", columns="region", values="amount", aggfunc="sum")
long = wide.reset_index().melt(id_vars="month", var_name="region", value_name="amount")
merged = orders.merge(customers, on="customer_id", how="left")
stacked = pd.concat([jan, feb], ignore_index=True)
ts = df.set_index("date").resample("W")["amount"].sum()   # weekly time series
```

## Export

```python
df.to_csv("out.csv", index=False)
df.to_parquet("out.parquet")          # compact + fast to re-read
df.to_excel("out.xlsx", index=False)  # for polished reports, prefer the document skill
print(df.to_markdown(index=False))    # paste-able table in the transcript
```

## Tips

- For files that don't fit in RAM, filter/aggregate in **DuckDB** first, then pull
  the small result into pandas (`duckdb.sql(...).df()`).
- `errors="coerce"` on `to_numeric`/`to_datetime` turns bad values into NaN/NaT
  instead of throwing — then `isna()` shows you how many were bad.
- Chain with `.pipe()` / `.assign()` to keep transforms readable and side-effect-free.
