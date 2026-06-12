#!/usr/bin/env bash
# _common.sh — shared helpers for the WhatsApp (Green API) skill scripts.
# Sourced by wa_setup.sh / wa_send.sh / wa_read.sh. Not meant to be run directly.
#
# Responsibilities:
#   * resolve credentials (GREENAPI_ID_INSTANCE / GREENAPI_API_TOKEN / GREENAPI_API_URL)
#   * provide wa_api() — a thin curl wrapper around the Green API
#   * provide wa_chat_id() — normalize a phone number into a chatId
#
# Dependencies: curl + jq (both are guaranteed in a spirit agent environment).

set -euo pipefail

# --- credential resolution -------------------------------------------------
# Precedence: anything already in the environment wins (inherited from the
# agent process, which keeps the token out of the transcript). Only if the
# token is NOT already set do we source a config file:
#   1. $WA_CONFIG                (explicit path, if you set it)
#   2. whatsapp/config.env       (relative to the workspace root = run_command cwd)
#   3. skills/whatsapp/config.env (next to this skill)
if [ -z "${GREENAPI_API_TOKEN:-}" ]; then
  for _cfg in "${WA_CONFIG:-}" "whatsapp/config.env" "skills/whatsapp/config.env"; do
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
      # shellcheck disable=SC1090
      . "$_cfg"
      break
    fi
  done
fi

: "${GREENAPI_ID_INSTANCE:?GREENAPI_ID_INSTANCE is not set. Export it in the agent environment or put it in whatsapp/config.env — see skills/whatsapp/SKILL.md}"
: "${GREENAPI_API_TOKEN:?GREENAPI_API_TOKEN is not set. Export it in the agent environment or put it in whatsapp/config.env — see skills/whatsapp/SKILL.md}"

# Use the apiUrl shown in your console for this instance. Older instances live
# on api.green-api.com; newer ones on a numbered subdomain (e.g.
# https://7103.api.greenapi.com) — the generic host usually redirects, but the
# console value is authoritative.
GREENAPI_API_URL="${GREENAPI_API_URL:-https://api.green-api.com}"
GREENAPI_API_URL="${GREENAPI_API_URL%/}"

_WA_BASE="$GREENAPI_API_URL/waInstance$GREENAPI_ID_INSTANCE"

# --- helpers ---------------------------------------------------------------
# wa_api <method> [extra curl args...] -> prints the raw JSON response.
# URL shape: {apiUrl}/waInstance{id}/{method}/{token}[?query]
# For query params use curl's --get -d (keeps them after the token), e.g.:
#   wa_api receiveNotification --get -d receiveTimeout=20
# Timeout default 75s: receiveNotification can legitimately hang up to 60s.
wa_api() {
  _method="$1"; shift
  curl -sS --max-time "${WA_HTTP_TIMEOUT:-75}" \
    "$_WA_BASE/$_method/$GREENAPI_API_TOKEN" "$@"
}

# wa_delete_notification <receiptId> — the one method whose URL has a segment
# AFTER the token: deleteNotification/{token}/{receiptId}.
wa_delete_notification() {
  curl -sS --max-time "${WA_HTTP_TIMEOUT:-75}" -X DELETE \
    "$_WA_BASE/deleteNotification/$GREENAPI_API_TOKEN/$1"
}

# wa_chat_id <number-or-chatId> — pass @c.us / @g.us ids through untouched;
# turn a bare phone number (digits, optional +, spaces, dashes) into <digits>@c.us.
wa_chat_id() {
  case "$1" in
    *@c.us|*@g.us) printf '%s' "$1" ;;
    *) printf '%s@c.us' "$(printf '%s' "$1" | tr -cd '0-9')" ;;
  esac
}
