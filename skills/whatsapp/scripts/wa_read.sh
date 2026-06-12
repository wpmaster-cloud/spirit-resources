#!/usr/bin/env bash
# wa_read.sh — read incoming WhatsApp notifications via Green API polling.
#
# Drains the instance's notification queue: receiveNotification → print →
# deleteNotification, repeated until the queue is empty (or --max is hit).
#
# Usage:
#   bash skills/whatsapp/scripts/wa_read.sh                # drain new notifications
#   bash skills/whatsapp/scripts/wa_read.sh --timeout 20   # wait up to 20s for the first one
#   bash skills/whatsapp/scripts/wa_read.sh --max 5        # stop after 5 notifications
#   bash skills/whatsapp/scripts/wa_read.sh --raw          # full JSON, one notification per line
#   bash skills/whatsapp/scripts/wa_read.sh --peek         # look at the OLDEST one without consuming
#
# Options:
#   --timeout <5-60>  long-poll seconds while the queue is empty (default 5)
#   --max <n>         consume at most n notifications (default: until empty)
#   --raw             print each notification body as raw JSON
#   --peek            do NOT delete — NB: the queue is FIFO, so peek always shows
#                     the same oldest notification until something deletes it
#   -h | --help       show this help
#
# Output, one line per message-type notification:
#   <in|out>  [<chatId>]  <senderName>: <text>      (media → [imageMessage: <downloadUrl>] <caption>)
# Other notification types print as:  --  [<typeWebhook>] <summary>
#
# Reading CONSUMES: once deleted, a notification is gone from the server queue
# (the text stays in your transcript). Undeleted notifications expire after 24h.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

TIMEOUT=5
MAX=0
RAW=""
PEEK=""

usage() { sed -n '2,26p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2;;
    --max)     MAX="$2"; shift 2;;
    --raw)     RAW="1"; shift;;
    --peek)    PEEK="1"; shift;;
    -h|--help) usage 0;;
    *)         echo "unknown option: $1" >&2; usage 2;;
  esac
done

# Render one notification body (stdin) as a human line.
FMT='
def msgtext:
  if   .typeMessage == "textMessage"         then .textMessageData.textMessage
  elif .typeMessage == "extendedTextMessage" then .extendedTextMessageData.text
  elif .typeMessage == "quotedMessage"       then .extendedTextMessageData.text
  elif (.typeMessage // "" | test("^(image|video|document|audio)Message$"))
       then "[\(.typeMessage): \(.fileMessageData.downloadUrl // "?")]" +
            (if (.fileMessageData.caption // "") != "" then " \(.fileMessageData.caption)" else "" end)
  elif .typeMessage == "locationMessage" then "[location: \(.locationMessageData.latitude),\(.locationMessageData.longitude)]"
  elif .typeMessage == "contactMessage"  then "[contact: \(.contactMessageData.displayName // "?")]"
  elif .typeMessage == "stickerMessage"  then "[sticker]"
  else "[\(.typeMessage // "unknown")]" end;
if .typeWebhook == "incomingMessageReceived" then
  "in   [\(.senderData.chatId)]  \(.senderData.senderName // .senderData.sender): \(.messageData | msgtext)  (idMessage=\(.idMessage))"
elif (.typeWebhook // "" | test("^outgoing(API)?MessageReceived$")) then
  "out  [\(.senderData.chatId)]  \(.messageData | msgtext)  (idMessage=\(.idMessage))"
elif .typeWebhook == "outgoingMessageStatus" then
  "--   [\(.chatId // "?")] status \(.status) idMessage=\(.idMessage)"
elif .typeWebhook == "stateInstanceChanged" then
  "--   [instance] state -> \(.stateInstance)"
else
  "--   [\(.typeWebhook // "unknown")]"
end'

COUNT=0
while :; do
  RESP="$(wa_api receiveNotification --get -d "receiveTimeout=$TIMEOUT")"
  if [ -z "$RESP" ] || [ "$RESP" = "null" ]; then
    break  # queue empty (timeout reached)
  fi
  RECEIPT="$(printf '%s' "$RESP" | jq -r '.receiptId // empty')"
  if [ -z "$RECEIPT" ]; then
    echo "receiveNotification FAILED: $RESP" >&2
    echo "(a non-empty webhookUrl in settings causes a 400 here — run wa_setup.sh)" >&2
    exit 1
  fi

  if [ -n "$RAW" ]; then
    printf '%s' "$RESP" | jq -c '.body'
  else
    printf '%s' "$RESP" | jq -r ".body | $FMT"
  fi

  if [ -n "$PEEK" ]; then
    break  # don't consume; the same notification stays at the head of the queue
  fi
  wa_delete_notification "$RECEIPT" >/dev/null

  COUNT=$((COUNT + 1))
  [ "$MAX" -gt 0 ] && [ "$COUNT" -ge "$MAX" ] && break
  TIMEOUT=5  # queue was non-empty; drain the rest briskly
done

[ "$COUNT" -eq 0 ] && [ -z "$PEEK" ] && echo "no new notifications"
exit 0
