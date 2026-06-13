#!/usr/bin/env bash
# List / search Google Drive files. Prints one line per file:
#   <id>  <mimeType>  <size>  <modifiedTime>  <name>
# Needs a drive, drive.file, or drive.metadata.readonly scope.
#
# Usage:
#   drive_list.sh                                  # 20 most recent
#   drive_list.sh --query "name contains 'report'"
#   drive_list.sh --query "'<FOLDER_ID>' in parents and trashed=false" --max 100
# See references/google-api.md for the Drive query syntax.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

QUERY="trashed=false"; MAX=20
while [ $# -gt 0 ]; do
  case "$1" in
    --query|-q) QUERY="$2"; shift 2;;
    --max)      MAX="$2"; shift 2;;
    *) die "unknown flag: $1";;
  esac
done

resp=$(gapi -G "https://www.googleapis.com/drive/v3/files" \
  --data-urlencode "q=$QUERY" \
  -d "pageSize=$MAX" \
  -d "orderBy=modifiedTime desc" \
  -d "fields=files(id,name,mimeType,size,modifiedTime)")

err=$(printf '%s' "$resp" | jq -r '.error.message // empty')
[ -n "$err" ] && die "list failed: $err"

printf '%s' "$resp" | jq -r '.files[]? |
  "\(.id)  \(.mimeType)  \(.size // "-")  \(.modifiedTime)  \(.name)"'
n=$(printf '%s' "$resp" | jq -r '.files | length')
[ "$n" = 0 ] && echo "(no files)"
