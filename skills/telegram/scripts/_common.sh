#!/usr/bin/env bash
# _common.sh — shared helpers for the Telegram skill scripts.
# Sourced by tg_setup.sh / tg_send.sh / tg_read.sh. Not meant to be run directly.
#
# Responsibilities:
#   * resolve credentials (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID)
#   * resolve where read-offset state lives
#   * provide tg_api() — a thin curl wrapper around the Bot API
#
# Only dependency is curl. jq is used when present for nicer output; scripts fall
# back to raw JSON without it.

set -euo pipefail

# --- credential resolution -------------------------------------------------
# Precedence: anything already in the environment wins (inherited from the
# agent process, which keeps the token out of the transcript). Only if the
# token is NOT already set do we source a config file, so it can fill the gap
# without restarting the agent's environment.
#   1. $TG_CONFIG               (explicit path, if you set it)
#   2. telegram/config.env      (relative to the workspace root = run_command cwd)
#   3. skills/telegram/config.env (next to this skill)
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  for _cfg in "${TG_CONFIG:-}" "telegram/config.env" "skills/telegram/config.env"; do
    if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
      # shellcheck disable=SC1090
      . "$_cfg"
      break
    fi
  done
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set. Export it in the agent environment or put it in telegram/config.env — see skills/telegram/SKILL.md}"

# Override TG_API_BASE to point at a local/self-hosted Bot API server (or a mock).
TG_API_BASE="${TG_API_BASE:-https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}}"

# --- state location --------------------------------------------------------
# Where the getUpdates offset is remembered. Defaults to telegram/ under the
# workspace root; override with TG_STATE_DIR.
TG_STATE_DIR="${TG_STATE_DIR:-telegram}"
mkdir -p "$TG_STATE_DIR"
TG_OFFSET_FILE="${TG_OFFSET_FILE:-$TG_STATE_DIR/offset}"

# --- helpers ---------------------------------------------------------------
# tg_api <method> [extra curl args...]  -> prints the raw JSON response.
# Example: tg_api sendMessage -d chat_id=1 --data-urlencode text="hi"
tg_api() {
  _method="$1"; shift
  curl -sS --max-time "${TG_HTTP_TIMEOUT:-30}" "$TG_API_BASE/$_method" "$@"
}

# have_jq -> 0 if jq is usable, 1 otherwise.
have_jq() { command -v jq >/dev/null 2>&1; }
