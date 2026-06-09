#!/usr/bin/env bash
# Convert file(s) to Markdown with MarkItDown. Installs it first if needed.
#
# Usage:
#   to_md.sh INPUT [OUTPUT.md]      Convert one file (default OUTPUT: <input>.md)
#   to_md.sh -r DIR [OUTDIR]        Recurse a directory (default OUTDIR: <dir>-md)
#   to_md.sh -h                     Show this help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,7p' "$0"; exit "${1:-0}"; }

ensure_markitdown() {
  if ! command -v markitdown >/dev/null 2>&1; then
    "$HERE/setup.sh"
    # setup.sh may have created a ~/.local/bin shim not yet on PATH this shell.
    export PATH="$HOME/.local/bin:$PATH"
  fi
  command -v markitdown >/dev/null 2>&1 \
    || { echo "to_md.sh: markitdown is not on PATH after setup (see setup.sh output)" >&2; exit 1; }
}

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help) usage 0 ;; esac

ensure_markitdown

if [ "$1" = "-r" ] || [ "$1" = "--recursive" ]; then
  shift
  src="${1:?need a directory}"; src="${src%/}"
  out="${2:-${src}-md}"
  [ -d "$src" ] || { echo "to_md.sh: not a directory: $src" >&2; exit 1; }
  mkdir -p "$out"
  ok=0; fail=0
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    dst="$out/${rel%.*}.md"
    mkdir -p "$(dirname "$dst")"
    if markitdown "$f" -o "$dst" 2>/dev/null; then
      echo "ok:   $f -> $dst"; ok=$((ok+1))
    else
      echo "fail: $f" >&2; fail=$((fail+1))
    fi
  done < <(find "$src" -type f ! -name '*.md' -print0)
  echo "done: $ok converted, $fail failed -> $out" >&2
else
  in="$1"
  [ -f "$in" ] || { echo "to_md.sh: not a file: $in" >&2; exit 1; }
  out="${2:-${in%.*}.md}"
  markitdown "$in" -o "$out"
  echo "ok: $in -> $out"
fi
