#!/usr/bin/env bash
# List / read Gmail messages (users.me.messages). Prints one line per message:
#   <id>  | <date> | <From> | <Subject>
# Needs a gmail.readonly (or broader gmail) scope. Reading does NOT mark as read
# unless you pass --mark-read.
#
# Usage:
#   gmail_read.sh                          # 10 most recent in the inbox
#   gmail_read.sh --query "is:unread"      # any Gmail search query
#   gmail_read.sh --query "from:boss@x.com newer_than:2d" --max 20
#   gmail_read.sh --id 18f.. --full        # one message, with its text body
#   gmail_read.sh --query "is:unread" --mark-read
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

QUERY=""; MAX=10; FULL=0; ONE=""; MARK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --query|-q) QUERY="$2"; shift 2;;
    --max)      MAX="$2"; shift 2;;
    --id)       ONE="$2"; shift 2;;
    --full)     FULL=1; shift;;
    --mark-read) MARK=1; shift;;
    *) die "unknown flag: $1";;
  esac
done

hdr() { printf '%s' "$1" | jq -r --arg n "$2" '.payload.headers[]? | select(.name|ascii_downcase==($n|ascii_downcase)) | .value' | head -1; }

# Extract the text/plain (fallback text/html) body from a full message JSON.
body_text() {
  local m="$1" data
  data=$(printf '%s' "$m" | jq -r '
    def walk: ., (.parts[]? | walk);
    [ .payload | walk | select(.mimeType=="text/plain") | .body.data ] | map(select(.!=null)) | .[0] // ""')
  [ -z "$data" ] && data=$(printf '%s' "$m" | jq -r '
    def walk: ., (.parts[]? | walk);
    [ .payload | walk | select(.mimeType=="text/html") | .body.data ] | map(select(.!=null)) | .[0] // ""')
  [ -n "$data" ] && printf '%s' "$data" | b64url_decode
}

show_one() {
  local id="$1" fmt="metadata"; [ "$FULL" = 1 ] && fmt="full"
  local m; m=$(gapi -G "https://gmail.googleapis.com/gmail/v1/users/me/messages/$id" \
    -d "format=$fmt" -d "metadataHeaders=From" -d "metadataHeaders=Subject" -d "metadataHeaders=Date")
  printf '%s  | %s | %s | %s\n' "$id" "$(hdr "$m" Date)" "$(hdr "$m" From)" "$(hdr "$m" Subject)"
  if [ "$FULL" = 1 ]; then echo "----"; body_text "$m"; echo; echo "===="; fi
  if [ "$MARK" = 1 ]; then
    gapi -X POST "https://gmail.googleapis.com/gmail/v1/users/me/messages/$id/modify" \
      -H "Content-Type: application/json" --data-binary '{"removeLabelIds":["UNREAD"]}' >/dev/null
  fi
}

if [ -n "$ONE" ]; then show_one "$ONE"; exit 0; fi

list=$(gapi -G "https://gmail.googleapis.com/gmail/v1/users/me/messages" \
  -d "maxResults=$MAX" ${QUERY:+--data-urlencode "q=$QUERY"})
ids=$(printf '%s' "$list" | jq -r '.messages[]?.id')
[ -z "$ids" ] && { echo "(no messages)"; exit 0; }
while IFS= read -r id; do [ -n "$id" ] && show_one "$id"; done <<< "$ids"
