#!/usr/bin/env bash
# wa_send.sh — send a WhatsApp message (or file) via Green API.
#
# Usage:
#   bash skills/whatsapp/scripts/wa_send.sh "Build finished ✅"
#   bash skills/whatsapp/scripts/wa_send.sh --chat 79001234567 "hello"
#   bash skills/whatsapp/scripts/wa_send.sh --chat 120363043968066463@g.us "to the group"
#   bash skills/whatsapp/scripts/wa_send.sh --reply-to 3EB0C767D097B7C7C030 "ack"
#   echo "$LONG_BODY" | bash skills/whatsapp/scripts/wa_send.sh --stdin
#   bash skills/whatsapp/scripts/wa_send.sh --file-url https://x.io/r.pdf --name report.pdf --caption "Q2"
#
# Options:
#   --chat <id>       recipient: phone number or full chatId (…@c.us / …@g.us)
#                     (default: $WHATSAPP_DEFAULT_CHAT_ID)
#   --reply-to <id>   quote a previous message by its idMessage
#   --stdin           read the message body from stdin instead of arguments
#   --file-url <url>  send a file by URL instead of text (sendFileByUrl)
#   --name <fname>    filename with extension for --file-url (default: URL basename)
#   --caption <text>  caption for --file-url (max 1024 chars)
#   -h | --help       show this help
#
# Text limit is 20000 chars (UTF-8); files up to 100 MB. The body is built with
# jq via stdin, so quoting/newlines/emoji are handled.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

CHAT="${WHATSAPP_DEFAULT_CHAT_ID:-}"
REPLY_TO=""
FROM_STDIN=""
FILE_URL=""
FILE_NAME=""
CAPTION=""

usage() { sed -n '2,23p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --chat)     CHAT="$2"; shift 2;;
    --reply-to) REPLY_TO="$2"; shift 2;;
    --stdin)    FROM_STDIN="1"; shift;;
    --file-url) FILE_URL="$2"; shift 2;;
    --name)     FILE_NAME="$2"; shift 2;;
    --caption)  CAPTION="$2"; shift 2;;
    -h|--help)  usage 0;;
    --)         shift; break;;
    -*)         echo "unknown option: $1" >&2; usage 2;;
    *)          break;;
  esac
done

[ -n "$CHAT" ] || { echo "error: no recipient (pass --chat or set WHATSAPP_DEFAULT_CHAT_ID)" >&2; exit 2; }
CHAT="$(wa_chat_id "$CHAT")"

if [ -n "$FILE_URL" ]; then
  [ -n "$FILE_NAME" ] || { FILE_NAME="${FILE_URL##*/}"; FILE_NAME="${FILE_NAME%%\?*}"; }
  [ -n "$FILE_NAME" ] || { echo "error: cannot derive a filename from the URL; pass --name" >&2; exit 2; }
  PAYLOAD="$(jq -nc --arg chat "$CHAT" --arg url "$FILE_URL" --arg name "$FILE_NAME" \
                   --arg cap "$CAPTION" --arg quoted "$REPLY_TO" '
    {chatId:$chat, urlFile:$url, fileName:$name}
    + (if $cap    != "" then {caption:$cap}           else {} end)
    + (if $quoted != "" then {quotedMessageId:$quoted} else {} end)')"
  METHOD="sendFileByUrl"
else
  if [ -n "$FROM_STDIN" ]; then TEXT="$(cat)"; else TEXT="$*"; fi
  [ -n "$TEXT" ] || { echo "error: empty message text" >&2; exit 2; }
  # Text goes through stdin (jq -Rs), not argv — bodies can be up to 20k chars.
  PAYLOAD="$(printf '%s' "$TEXT" | jq -Rsc --arg chat "$CHAT" --arg quoted "$REPLY_TO" '
    {chatId:$chat, message:.}
    + (if $quoted != "" then {quotedMessageId:$quoted} else {} end)')"
  METHOD="sendMessage"
fi

RESP="$(printf '%s' "$PAYLOAD" | wa_api "$METHOD" -H 'Content-Type: application/json' --data-binary @-)"

ID="$(printf '%s' "$RESP" | jq -r '.idMessage // empty' 2>/dev/null || true)"
if [ -n "$ID" ]; then
  echo "sent ok: idMessage=$ID chat=$CHAT"
else
  echo "send FAILED: $RESP" >&2
  exit 1
fi
