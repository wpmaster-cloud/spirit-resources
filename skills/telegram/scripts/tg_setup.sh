#!/usr/bin/env bash
# tg_setup.sh — one-time setup / sanity check for the Telegram skill.
#
# Run this after setting TELEGRAM_BOT_TOKEN. It:
#   1. verifies the token              (getMe)
#   2. clears any webhook              (deleteWebhook — getUpdates needs polling)
#   3. lists chats that messaged the bot, so you can find your chat id
#
# Usage:
#   bash skills/telegram/scripts/tg_setup.sh
#
# Tip: send your bot a message in Telegram BEFORE running this, otherwise step 3
# has nothing to show.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

echo "== getMe =="
ME="$(tg_api getMe)"
if have_jq; then
  printf '%s' "$ME" | jq -r 'if .ok then "token ok: @\(.result.username) (bot id \(.result.id))" else "TOKEN INVALID: \(.error_code) \(.description)" end'
  printf '%s' "$ME" | jq -e '.ok' >/dev/null || exit 1
else
  printf '%s\n' "$ME"
fi

echo
echo "== deleteWebhook (getUpdates and webhooks are mutually exclusive) =="
WH="$(tg_api deleteWebhook -d drop_pending_updates=false)"
if have_jq; then
  printf '%s' "$WH" | jq -r '"deleteWebhook: ok=\(.ok)\(if .description then " (" + .description + ")" else "" end)"'
else
  printf '%s\n' "$WH"
fi

echo
echo "== chats that have messaged this bot =="
UP="$(tg_api getUpdates -d timeout=0 -d limit=50)"
if have_jq; then
  printf '%s' "$UP" | jq -r '
    [ .result[] | (.message // .edited_message // .channel_post) | select(. != null) | .chat ]
    | unique_by(.id)
    | if length == 0 then
        "  (none yet — send your bot a message in Telegram, then run this again)"
      else
        .[] | "  chat_id=\(.id)  type=\(.type)  name=\(.title // ((.first_name // "") + " " + (.last_name // "")) | gsub("^ +| +$";""))"
      end'
else
  printf '%s\n' "$UP"
fi

echo
echo "Next: record your chat id where the scripts can read it, e.g."
echo "  echo 'TELEGRAM_CHAT_ID=<id>' >> telegram/config.env"
echo "  (or export TELEGRAM_CHAT_ID in the agent's environment)"
