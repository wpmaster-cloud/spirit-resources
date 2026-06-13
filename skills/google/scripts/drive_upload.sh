#!/usr/bin/env bash
# Upload a local file to Google Drive (multipart/related: metadata + media in one
# request; media is base64-encoded so binaries are safe). Needs a drive or
# drive.file scope. Prints the new file id and a shareable webViewLink.
#
# Usage:
#   drive_upload.sh report.pdf
#   drive_upload.sh out/report.pdf --name "Q2 Report.pdf" --folder <FOLDER_ID>
#   drive_upload.sh report.pdf --anyone-reader        # make it link-readable
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FILE=""; NAME=""; FOLDER=""; SHARE=0; MIME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)          NAME="$2"; shift 2;;
    --folder)        FOLDER="$2"; shift 2;;
    --mime)          MIME="$2"; shift 2;;
    --anyone-reader) SHARE=1; shift;;
    -*) die "unknown flag: $1";;
    *)  FILE="$1"; shift;;
  esac
done
[ -n "$FILE" ] && [ -f "$FILE" ] || die "give a path to an existing file"
[ -n "$NAME" ] || NAME="$(basename "$FILE")"
[ -n "$MIME" ] || MIME="application/octet-stream"

meta=$(jq -nc --arg n "$NAME" --arg f "$FOLDER" \
  '{name:$n} + (if $f=="" then {} else {parents:[$f]} end)')

b="rel_$(date +%s)_$$"
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
{
  printf -- '--%s\r\n' "$b"
  printf 'Content-Type: application/json; charset=UTF-8\r\n\r\n'
  printf '%s\r\n' "$meta"
  printf -- '--%s\r\n' "$b"
  printf 'Content-Type: %s\r\n' "$MIME"
  printf 'Content-Transfer-Encoding: base64\r\n\r\n'
  base64 < "$FILE"; printf '\r\n'
  printf -- '--%s--\r\n' "$b"
} > "$body"

resp=$(gapi -X POST \
  "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink" \
  -H "Content-Type: multipart/related; boundary=$b" \
  --data-binary @"$body")

id=$(printf '%s' "$resp" | jq -r '.id // empty')
[ -n "$id" ] || die "upload failed: $(printf '%s' "$resp" | jq -r '.error.message // .')"
echo "uploaded ok: id=$id name=$(printf '%s' "$resp" | jq -r '.name')"

if [ "$SHARE" = 1 ]; then
  gapi -X POST "https://www.googleapis.com/drive/v3/files/$id/permissions" \
    -H "Content-Type: application/json" \
    --data-binary '{"role":"reader","type":"anyone"}' >/dev/null
  echo "shared: anyone with the link can view"
fi
echo "link: $(printf '%s' "$resp" | jq -r '.webViewLink // "(open Drive)"')"
