#!/usr/bin/env bash
# Create a Google Calendar event. Needs a calendar or calendar.events scope.
#
# Usage:
#   gcal_add.sh --summary "Standup" --start 2026-06-15T09:30:00 --end 2026-06-15T10:00:00
#   gcal_add.sh --summary "Trip" --start 2026-07-01 --end 2026-07-05 --all-day
#   gcal_add.sh --summary "Sync" --start 2026-06-15T14:00:00 --end 2026-06-15T15:00:00 \
#       --timezone Asia/Jerusalem --location "Room 1" --description "agenda" \
#       --attendee a@x.com --attendee b@x.com
# Timed events use --timezone (or $TZ, default UTC); --all-day takes plain YYYY-MM-DD
# dates and the end date is EXCLUSIVE (Google convention).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SUMMARY=""; START=""; END=""; DESC=""; LOC=""; CAL="primary"; ZONE="${TZ:-UTC}"; ALLDAY=0; ATT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --summary)     SUMMARY="$2"; shift 2;;
    --start)       START="$2"; shift 2;;
    --end)         END="$2"; shift 2;;
    --description) DESC="$2"; shift 2;;
    --location)    LOC="$2"; shift 2;;
    --calendar)    CAL="$2"; shift 2;;
    --timezone)    ZONE="$2"; shift 2;;
    --attendee)    ATT+=("$2"); shift 2;;
    --all-day)     ALLDAY=1; shift;;
    *) die "unknown flag: $1";;
  esac
done
[ -n "$SUMMARY" ] || die "need --summary"
[ -n "$START" ] && [ -n "$END" ] || die "need --start and --end"

if [ "$ALLDAY" = 1 ]; then
  start_json=$(jq -nc --arg d "$START" '{date:$d}')
  end_json=$(jq -nc --arg d "$END" '{date:$d}')
else
  start_json=$(jq -nc --arg dt "$START" --arg tz "$ZONE" '{dateTime:$dt, timeZone:$tz}')
  end_json=$(jq -nc --arg dt "$END" --arg tz "$ZONE" '{dateTime:$dt, timeZone:$tz}')
fi

att_json='[]'
[ ${#ATT[@]} -gt 0 ] && att_json=$(printf '%s\n' "${ATT[@]}" | jq -R '{email:.}' | jq -sc '.')

body=$(jq -nc --arg s "$SUMMARY" --arg d "$DESC" --arg l "$LOC" \
  --argjson start "$start_json" --argjson end "$end_json" --argjson att "$att_json" \
  '{summary:$s, start:$start, end:$end}
   + (if $d != "" then {description:$d} else {} end)
   + (if $l != "" then {location:$l} else {} end)
   + (if ($att|length) > 0 then {attendees:$att} else {} end)')

resp=$(gapi -X POST "https://www.googleapis.com/calendar/v3/calendars/$CAL/events" \
  -H "Content-Type: application/json" --data-binary "$body")

id=$(printf '%s' "$resp" | jq -r '.id // empty')
[ -n "$id" ] || die "create failed: $(printf '%s' "$resp" | jq -r '.error.message // .')"
echo "created: id=$id  $(printf '%s' "$resp" | jq -r '.htmlLink // ""')"
