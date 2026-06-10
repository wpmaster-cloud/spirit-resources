#!/usr/bin/env bash
# tg_read.sh — read NEW Telegram messages via curl (Bot API getUpdates).
#
# Usage:
#   bash skills/telegram/scripts/tg_read.sh                 # new messages, return now
#   bash skills/telegram/scripts/tg_read.sh --timeout 25    # long-poll up to 25s
#   bash skills/telegram/scripts/tg_read.sh --chat 12345    # only this chat
#   bash skills/telegram/scripts/tg_read.sh --raw           # pretty raw JSON
#   bash skills/telegram/scripts/tg_read.sh --peek          # read WITHOUT consuming
#   bash skills/telegram/scripts/tg_read.sh --reset         # forget offset, re-read backlog
#
# Options:
#   --timeout <sec>  long-poll seconds to wait for a message (default 0 = no wait)
#   --limit <n>      max updates per call (default 100)
#   --chat <id>      only show messages from this chat id
#   --raw            print the full JSON response (still advances the offset)
#   --peek           do NOT advance the offset (look without consuming)
#   --reset          delete the stored offset before reading
#   -h | --help      show this help
#
# Offset memory: the last seen update_id+1 is stored in $TG_STATE_DIR/offset
# (default telegram/offset) and passed as the next getUpdates offset. This filters
# already-seen messages AND tells Telegram to drop them server-side, so each
# message is returned once. Reading therefore CONSUMES — use --peek to look only.
#
# Output: one line per message —
#   <update_id>  [<chat_id>]  <name> @username: <text>   [photo]/[document: …]/…

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

TIMEOUT=0
LIMIT=100
CHAT_FILTER=""
RAW=""
PEEK=""

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2;;
    --limit)   LIMIT="$2"; shift 2;;
    --chat)    CHAT_FILTER="$2"; shift 2;;
    --raw)     RAW="1"; shift;;
    --peek)    PEEK="1"; shift;;
    --reset)   rm -f "$TG_OFFSET_FILE"; shift;;
    -h|--help) usage 0;;
    *)         echo "unknown option: $1" >&2; usage 2;;
  esac
done

OFFSET=0
if [ -f "$TG_OFFSET_FILE" ]; then
  OFFSET="$(cat "$TG_OFFSET_FILE" 2>/dev/null || echo 0)"
fi
[ -n "$OFFSET" ] || OFFSET=0

# curl must outlive the server-side long poll. Consumed by tg_api in the sourced
# _common.sh (via the command-substitution subshell below), which shellcheck
# can't trace across the source — hence the disable.
# shellcheck disable=SC2034
TG_HTTP_TIMEOUT=$((TIMEOUT + 10))
RESP="$(tg_api getUpdates -d offset="$OFFSET" -d timeout="$TIMEOUT" -d limit="$LIMIT")"

if ! have_jq; then
  printf '%s\n' "$RESP"
  echo "(jq not found — raw JSON above. Parse it directly, or install jq for line output.)" >&2
  exit 0
fi

if [ "$(printf '%s' "$RESP" | jq -r '.ok')" != "true" ]; then
  printf '%s' "$RESP" | jq -r '"getUpdates FAILED: \(.error_code) \(.description)"' >&2
  echo "(HTTP 409 means a webhook is set — run tg_setup.sh to clear it.)" >&2
  exit 1
fi

# Advance the offset to highest update_id + 1, unless --peek.
MAXID="$(printf '%s' "$RESP" | jq -r '[.result[].update_id] | max // empty')"
if [ -z "$PEEK" ] && [ -n "$MAXID" ]; then
  echo $((MAXID + 1)) > "$TG_OFFSET_FILE"
fi

if [ -n "$RAW" ]; then
  printf '%s' "$RESP" | jq .
  exit 0
fi

COUNT="$(printf '%s' "$RESP" | jq '[.result[] | (.message // .edited_message // .channel_post) | select(. != null)] | length')"
if [ "${COUNT:-0}" -eq 0 ]; then
  echo "(no new messages)"
  exit 0
fi

printf '%s' "$RESP" | jq -r --arg chat "$CHAT_FILTER" '
  .result[]
  | (.message // .edited_message // .channel_post) as $m
  | select($m != null)
  | select($chat == "" or (($m.chat.id | tostring) == $chat))
  | ((($m.from.first_name // $m.chat.title // "?"))
      + (if $m.from.username then " @" + $m.from.username else "" end)) as $who
  | (($m.text // $m.caption // "") | gsub("\n"; " ⏎ ")) as $body
  | (if   $m.photo    then " [photo]"
     elif $m.document then " [document: " + ($m.document.file_name // "file") + "]"
     elif $m.voice    then " [voice]"
     elif $m.audio    then " [audio]"
     elif $m.video    then " [video]"
     elif $m.sticker  then " [sticker " + ($m.sticker.emoji // "") + "]"
     elif $m.location then " [location]"
     elif $m.contact  then " [contact]"
     else "" end) as $kind
  | "\(.update_id)  [\($m.chat.id)]  \($who): \($body)\($kind)"
'
