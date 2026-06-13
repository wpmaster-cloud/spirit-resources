#!/usr/bin/env bash
# List Google Calendar events. Prints one line per event:
#   <start>  |  <summary>  [@ location]
# Needs a calendar or calendar.readonly scope. Defaults to upcoming events on the
# primary calendar.
#
# Usage:
#   gcal_list.sh                                  # next 10 upcoming on primary
#   gcal_list.sh --max 25 --to 2026-07-01T00:00:00Z
#   gcal_list.sh --query "standup"
#   gcal_list.sh --calendar team@group.calendar.google.com --from 2026-06-01T00:00:00Z
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CAL="primary"; MAX=10; FROM=""; TO=""; Q=""
while [ $# -gt 0 ]; do
  case "$1" in
    --calendar) CAL="$2"; shift 2;;
    --max)      MAX="$2"; shift 2;;
    --from)     FROM="$2"; shift 2;;
    --to)       TO="$2"; shift 2;;
    --query|-q) Q="$2"; shift 2;;
    *) die "unknown flag: $1";;
  esac
done
[ -n "$FROM" ] || FROM=$(date -u +%Y-%m-%dT%H:%M:%SZ)

resp=$(gapi -G "https://www.googleapis.com/calendar/v3/calendars/$CAL/events" \
  -d "maxResults=$MAX" -d "singleEvents=true" -d "orderBy=startTime" \
  --data-urlencode "timeMin=$FROM" \
  ${TO:+--data-urlencode "timeMax=$TO"} \
  ${Q:+--data-urlencode "q=$Q"})

err=$(printf '%s' "$resp" | jq -r '.error.message // empty')
[ -n "$err" ] && die "list failed: $err"

printf '%s' "$resp" | jq -r '.items[]? |
  "\(.start.dateTime // .start.date)  |  \(.summary // "(no title)")\(if .location then "  @ " + .location else "" end)  (\(.id))"'
n=$(printf '%s' "$resp" | jq -r '.items | length')
[ "$n" = 0 ] && echo "(no events)"
