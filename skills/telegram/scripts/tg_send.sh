#!/usr/bin/env bash
# tg_send.sh — send a Telegram message via curl (Bot API sendMessage).
#
# Usage:
#   bash skills/telegram/scripts/tg_send.sh "Hello from the agent"
#   bash skills/telegram/scripts/tg_send.sh --chat 12345 --reply-to 678 "ack"
#   bash skills/telegram/scripts/tg_send.sh --parse HTML "<b>done</b>"
#   echo "long body" | bash skills/telegram/scripts/tg_send.sh --stdin
#
# Options:
#   --chat <id>      target chat id            (default: $TELEGRAM_CHAT_ID)
#   --parse <mode>   parse_mode: MarkdownV2|HTML (default: none = plain text)
#   --reply-to <id>  reply to a specific message_id
#   --silent         deliver without a notification sound
#   --stdin          read the message body from stdin instead of arguments
#   -h | --help      show this help
#
# Plain text is the safe default. With --parse you MUST escape special characters
# per Telegram's rules (see references/bot-api.md) or the API returns HTTP 400.
# Text is sent with --data-urlencode, so quoting/newlines/emoji are handled.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

CHAT="${TELEGRAM_CHAT_ID:-}"
PARSE=""
REPLY_TO=""
SILENT=""
FROM_STDIN=""

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --chat)     CHAT="$2"; shift 2;;
    --parse)    PARSE="$2"; shift 2;;
    --reply-to) REPLY_TO="$2"; shift 2;;
    --silent)   SILENT="1"; shift;;
    --stdin)    FROM_STDIN="1"; shift;;
    -h|--help)  usage 0;;
    --)         shift; break;;
    -*)         echo "unknown option: $1" >&2; usage 2;;
    *)          break;;
  esac
done

if [ -n "$FROM_STDIN" ]; then
  TEXT="$(cat)"
else
  TEXT="$*"
fi

[ -n "$CHAT" ] || { echo "error: no chat id (pass --chat or set TELEGRAM_CHAT_ID)" >&2; exit 2; }
[ -n "$TEXT" ] || { echo "error: empty message text" >&2; exit 2; }

# Build curl args safely without bash arrays (works on bash 3.2).
set -- -d chat_id="$CHAT" --data-urlencode text="$TEXT"
[ -n "$PARSE" ]    && set -- "$@" -d parse_mode="$PARSE"
[ -n "$REPLY_TO" ] && set -- "$@" -d reply_to_message_id="$REPLY_TO"
[ -n "$SILENT" ]   && set -- "$@" -d disable_notification=true

RESP="$(tg_api sendMessage "$@")"

if have_jq; then
  if [ "$(printf '%s' "$RESP" | jq -r '.ok')" = "true" ]; then
    printf '%s' "$RESP" | jq -r '"sent ok: message_id=\(.result.message_id) chat=\(.result.chat.id)"'
  else
    printf '%s' "$RESP" | jq -r '"send FAILED: \(.error_code) \(.description)"' >&2
    exit 1
  fi
else
  printf '%s\n' "$RESP"
  printf '%s' "$RESP" | grep -q '"ok":true' || exit 1
fi
