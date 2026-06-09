# DuckDB recipes (SQL over files, no server)

DuckDB is a single binary / Python module that runs SQL directly against CSV,
Parquet, JSON, and Excel files — columnar and out-of-core, so it scales far past
pandas. Use the bundled `dsql.sh` wrapper, the `duckdb` CLI directly, or the Python
module.

## Reading files

```sql
-- auto-detect (delimiter, header, types)
SELECT * FROM 'data.csv' LIMIT 10;
SELECT * FROM 'data.parquet';
SELECT * FROM read_json_auto('events.jsonl');

-- explicit options
SELECT * FROM read_csv('data.csv', header=true, delim=';', sample_size=-1);
SELECT * FROM read_csv_auto('data.tsv', ignore_errors=true);

-- many files at once (glob); filename adds a virtual column
SELECT * FROM read_parquet('logs/*.parquet', filename=true);
SELECT * FROM 'data/2026-*.csv';
```

Excel needs the `spatial`/`excel` extension:
```sql
INSTALL excel; LOAD excel;
SELECT * FROM read_xlsx('book.xlsx', sheet='Sheet1');
```

## The essentials

```sql
-- aggregate
SELECT region, count(*) n, sum(amount) total, avg(amount) avg
FROM 'sales.csv' GROUP BY region ORDER BY total DESC;

-- filter + derived columns
SELECT *, amount * 1.17 AS with_tax FROM 'sales.csv' WHERE amount > 100;

-- join
SELECT o.*, c.name
FROM 'orders.csv' o JOIN 'customers.csv' c USING (customer_id);

-- dedupe / distinct
SELECT DISTINCT * FROM 'data.csv';
SELECT customer_id, count(*) FROM 'orders.csv' GROUP BY 1 HAVING count(*) > 1;

-- window functions
SELECT *, row_number() OVER (PARTITION BY region ORDER BY amount DESC) AS rnk
FROM 'sales.csv' QUALIFY rnk <= 3;        -- top 3 per region
```

## Instant profiling

```sql
DESCRIBE SELECT * FROM 'data.csv';        -- column names + types
SUMMARIZE SELECT * FROM 'data.csv';       -- count, null%, min/max/avg/std, approx distinct, quantiles
SELECT count(*) FROM 'data.csv';
```
`SUMMARIZE` is the fastest way to understand a dataset once DuckDB is installed.

## Export / convert

```sql
COPY (SELECT * FROM 'data.csv' WHERE amount > 0) TO 'clean.parquet' (FORMAT parquet);
COPY (SELECT region, sum(amount) t FROM 'sales.csv' GROUP BY 1) TO 'out.csv' (HEADER);
COPY (SELECT * FROM 'data.csv') TO 'out.json' (FORMAT json, ARRAY true);
```
CSV → Parquet is a great first step for big data: smaller and ~10× faster to query.

## Remote files (S3 / HTTP)

```sql
INSTALL httpfs; LOAD httpfs;
SELECT * FROM 'https://example.com/data.parquet';
-- S3:
SET s3_region='us-east-1'; SET s3_access_key_id='…'; SET s3_secret_access_key='…';
SELECT count(*) FROM 's3://bucket/path/*.parquet';
```

## pandas interop (Python module)

```python
import duckdb, pandas as pd
df = duckdb.sql("SELECT region, sum(amount) t FROM 'sales.csv' GROUP BY 1").df()  # → DataFrame
big = pd.read_csv("sales.csv")
duckdb.sql("SELECT region, count(*) FROM big GROUP BY 1").show()                   # query a DataFrame by name
```

## CLI output modes

```bash
duckdb -c "SELECT 1"               # duckbox table (default)
duckdb -csv -c "…"                 # CSV
duckdb -json -c "…"                # JSON
duckdb -markdown -c "…"            # Markdown table
duckdb -c ".read query.sql"        # run a .sql file
```
The bundled `dsql.sh` maps `--format csv|json|markdown|table` onto these.
