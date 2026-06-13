#!/usr/bin/env bash
# Download a Google Drive file by id. Binary/uploaded files come down with
# alt=media. Native Google Docs/Sheets/Slides aren't downloadable directly —
# pass --export <mime> to export them (e.g. application/pdf). Needs a drive or
# drive.readonly scope.
#
# Usage:
#   drive_download.sh <FILE_ID> -o local.pdf
#   drive_download.sh <DOC_ID>  --export application/pdf -o doc.pdf
# Common export MIMEs: application/pdf, text/plain,
#   application/vnd.openxmlformats-officedocument.wordprocessingml.document (.docx),
#   application/vnd.openxmlformats-officedocument.spreadsheetml.sheet (.xlsx)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ID=""; OUT=""; EXPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)  OUT="$2"; shift 2;;
    --export)  EXPORT="$2"; shift 2;;
    -*) die "unknown flag: $1";;
    *)  ID="$1"; shift;;
  esac
done
[ -n "$ID" ]  || die "give a Drive file id"
[ -n "$OUT" ] || die "give an output path with -o"

if [ -n "$EXPORT" ]; then
  url="https://www.googleapis.com/drive/v3/files/$ID/export"
  gapi -G "$url" --data-urlencode "mimeType=$EXPORT" -o "$OUT"
else
  gapi "https://www.googleapis.com/drive/v3/files/$ID?alt=media" -o "$OUT"
fi

# A failed download writes a small JSON error blob instead of the file — detect it.
if head -c1 "$OUT" | grep -q '{' && jq -e '.error' "$OUT" >/dev/null 2>&1; then
  msg=$(jq -r '.error.message // "unknown"' "$OUT"); rm -f "$OUT"
  die "download failed: $msg (native Google file? try --export application/pdf)"
fi
echo "saved: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
