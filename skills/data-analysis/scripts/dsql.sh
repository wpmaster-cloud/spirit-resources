#!/usr/bin/env bash
# dsql.sh — run a DuckDB SQL query over local/remote data files, zero server.
#
# Usage:
#   dsql.sh "SELECT * FROM 'sales.csv' LIMIT 5"
#   dsql.sh "SELECT region, sum(amount) FROM 'sales.parquet' GROUP BY 1" --format markdown
#   dsql.sh "SELECT count(*) FROM read_json_auto('events.jsonl')" --format json
#
# DuckDB reads CSV/Parquet/JSON directly — quote the path inside the SQL, e.g.
# FROM 'file.csv'  (or read_csv_auto / read_parquet / read_json_auto for options).
#
# Options:
#   --format csv|json|markdown|table   output mode (default: table)
#   -h | --help
set -euo pipefail

usage() { sed -n '2,17p' "$0"; exit "${1:-0}"; }

FORMAT=""        # empty = DuckDB default (duckbox table)
SQL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format)
      case "$2" in
        csv) FORMAT="csv";;
        json) FORMAT="json";;
        markdown|md) FORMAT="markdown";;
        table|duckbox) FORMAT="";;
        *) echo "unknown format: $2" >&2; exit 2;;
      esac
      shift 2;;
    -h|--help) usage 0;;
    *) SQL="$1"; shift;;
  esac
done

[ -n "$SQL" ] || usage 2

if ! command -v duckdb >/dev/null 2>&1; then
  echo "duckdb is not installed. Install one of:" >&2
  echo "  curl https://install.duckdb.org | sh    # standalone CLI (recommended)" >&2
  echo "  brew install duckdb                      # macOS" >&2
  echo "  pip install duckdb                       # Python module (use via python3)" >&2
  exit 127
fi

if [ -n "$FORMAT" ]; then
  exec duckdb "-$FORMAT" -c "$SQL"
else
  exec duckdb -c "$SQL"
fi
