#!/usr/bin/env bash
# wa_setup.sh — verify the Green API instance: auth state, QR pairing, settings.
#
# Usage:
#   bash skills/whatsapp/scripts/wa_setup.sh                 # state + settings check
#   bash skills/whatsapp/scripts/wa_setup.sh --qr            # also save pairing QR to whatsapp/qr.png
#   bash skills/whatsapp/scripts/wa_setup.sh --fix-settings  # enable polling-friendly settings (REBOOTS the instance)
#   bash skills/whatsapp/scripts/wa_setup.sh --check 79001234567  # does this number have WhatsApp?
#
# What it checks:
#   * getStateInstance — must be "authorized" before anything else works
#   * getSettings      — webhookUrl must be EMPTY for receiveNotification polling,
#                        incomingWebhook must be "yes" to receive incoming messages
#
# --fix-settings posts {webhookUrl:"", incomingWebhook:"yes"}. Green API reboots
# the instance and applies settings within ~5 minutes — don't spam it.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
. "$HERE/_common.sh"

WANT_QR=""
FIX=""
CHECK_NUM=""

usage() { sed -n '2,16p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --qr)           WANT_QR="1"; shift;;
    --fix-settings) FIX="1"; shift;;
    --check)        CHECK_NUM="$2"; shift 2;;
    -h|--help)      usage 0;;
    *)              echo "unknown option: $1" >&2; usage 2;;
  esac
done

# --- 1. instance state -------------------------------------------------------
STATE_RESP="$(wa_api getStateInstance)"
STATE="$(printf '%s' "$STATE_RESP" | jq -r '.stateInstance // empty')"
if [ -z "$STATE" ]; then
  echo "getStateInstance FAILED: $STATE_RESP" >&2
  echo "(check GREENAPI_ID_INSTANCE / GREENAPI_API_TOKEN / GREENAPI_API_URL)" >&2
  exit 1
fi
echo "instance $GREENAPI_ID_INSTANCE: state=$STATE"

case "$STATE" in
  authorized) ;;
  notAuthorized)
    echo "NOT AUTHORIZED — the instance is not linked to a WhatsApp account yet."
    WANT_QR="1";;
  blocked|yellowCard)
    echo "WARNING: state=$STATE — the account is restricted/banned; see the Green API console." >&2;;
  starting|sleepMode)
    echo "Instance is $STATE — wait ~1 minute and re-run." ;;
esac

# --- 2. QR pairing -----------------------------------------------------------
if [ -n "$WANT_QR" ] && [ "$STATE" = "notAuthorized" ]; then
  QR_RESP="$(wa_api qr)"
  QR_TYPE="$(printf '%s' "$QR_RESP" | jq -r '.type // empty')"
  if [ "$QR_TYPE" = "qrCode" ]; then
    mkdir -p whatsapp
    printf '%s' "$QR_RESP" | jq -r '.message' | base64 -d > whatsapp/qr.png
    echo "QR saved to whatsapp/qr.png — scan it within ~20s from the phone:"
    echo "  WhatsApp > Settings > Linked Devices > Link a Device"
    echo "(QR rotates every ~20s; re-run with --qr for a fresh one. The console"
    echo " at https://console.green-api.com shows a live-refreshing QR too.)"
  else
    echo "qr: $(printf '%s' "$QR_RESP" | jq -r '.message // .')"
  fi
fi
[ "$STATE" = "authorized" ] || exit 0

# --- 3. settings sanity for polling -------------------------------------------
SETTINGS="$(wa_api getSettings)"
WID="$(printf '%s' "$SETTINGS" | jq -r '.wid // empty')"
[ -n "$WID" ] && echo "account: $WID"
HOOK_URL="$(printf '%s' "$SETTINGS" | jq -r '.webhookUrl // ""')"
INCOMING="$(printf '%s' "$SETTINGS" | jq -r '.incomingWebhook // ""')"

OK=1
if [ -n "$HOOK_URL" ]; then
  echo "PROBLEM: webhookUrl is set ($HOOK_URL) — receiveNotification polling returns 400 while a webhook URL is configured."
  OK=""
fi
if [ "$INCOMING" != "yes" ]; then
  echo "PROBLEM: incomingWebhook=$INCOMING — incoming messages will NOT land in the notification queue."
  OK=""
fi

if [ -n "$OK" ]; then
  echo "settings ok: webhookUrl empty, incomingWebhook=yes — wa_read.sh will work."
elif [ -n "$FIX" ]; then
  echo "applying setSettings {webhookUrl:\"\", incomingWebhook:\"yes\"} — instance will REBOOT, settings live within ~5 min..."
  printf '%s' '{"webhookUrl":"","incomingWebhook":"yes"}' \
    | wa_api setSettings -H 'Content-Type: application/json' --data-binary @-
  echo
else
  echo "re-run with --fix-settings to fix (note: this reboots the instance)."
  exit 1
fi

# --- 4. optional: checkWhatsapp ------------------------------------------------
if [ -n "$CHECK_NUM" ]; then
  NUM="$(printf '%s' "$CHECK_NUM" | tr -cd '0-9')"
  printf '{"phoneNumber":%s}' "$NUM" \
    | wa_api checkWhatsapp -H 'Content-Type: application/json' --data-binary @- \
    | jq -r --arg n "$NUM" 'if .existsWhatsapp == true then "\($n): has WhatsApp" elif .existsWhatsapp == false then "\($n): NO WhatsApp" else "checkWhatsapp failed: \(.)" end'
fi
