#!/usr/bin/env bash
# Shared helpers for the google skill: credential resolution, OAuth access-token
# minting (refresh_token -> short-lived access_token, cached on disk), and an
# authenticated curl wrapper. Sourced by the g_*/gmail_*/drive_* scripts — not
# run directly. Needs: curl, jq, base64 (all in the agent image).
set -euo pipefail

# Per-agent state (token cache, optional config) lives under <workspace>/google/.
STATE_DIR="${GOOGLE_STATE_DIR:-google}"
mkdir -p "$STATE_DIR"

# Credentials: env wins; otherwise source <workspace>/google/config.env if present.
if [ -z "${GOOGLE_CLIENT_ID:-}" ] && [ -f "$STATE_DIR/config.env" ]; then
  set -a; . "$STATE_DIR/config.env"; set +a
fi

: "${GOOGLE_CLIENT_ID:?set GOOGLE_CLIENT_ID (env or google/config.env)}"
: "${GOOGLE_CLIENT_SECRET:?set GOOGLE_CLIENT_SECRET}"
: "${GOOGLE_REFRESH_TOKEN:?set GOOGLE_REFRESH_TOKEN — see references/google-api.md to mint one}"

TOKEN_CACHE="$STATE_DIR/.access_token"

# g_access_token: echo a valid access token, minting a fresh one from the refresh
# token whenever the cache is missing or within 60s of expiry.
g_access_token() {
  if [ -f "$TOKEN_CACHE" ]; then
    local exp tok
    exp=$(jq -r '.exp // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
    tok=$(jq -r '.access_token // empty' "$TOKEN_CACHE" 2>/dev/null || true)
    if [ -n "$tok" ] && [ "$(date +%s)" -lt "$((exp - 60))" ]; then
      printf '%s' "$tok"; return 0
    fi
  fi
  local resp tok ttl
  resp=$(curl -sS https://oauth2.googleapis.com/token \
    -d client_id="$GOOGLE_CLIENT_ID" \
    -d client_secret="$GOOGLE_CLIENT_SECRET" \
    -d refresh_token="$GOOGLE_REFRESH_TOKEN" \
    -d grant_type=refresh_token)
  tok=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  ttl=$(printf '%s' "$resp" | jq -r '.expires_in // 0')
  if [ -z "$tok" ]; then
    echo "google: token refresh failed: $resp" >&2
    return 1
  fi
  jq -nc --arg t "$tok" --argjson e "$(( $(date +%s) + ttl ))" \
    '{access_token:$t, exp:$e}' > "$TOKEN_CACHE"
  chmod 600 "$TOKEN_CACHE" 2>/dev/null || true
  printf '%s' "$tok"
}

# gapi <curl args...>: curl with the Bearer header attached.
gapi() { curl -sS -H "Authorization: Bearer $(g_access_token)" "$@"; }

# base64url encode stdin (no padding) / decode stdin (pads as needed).
b64url()        { base64 | tr '+/' '-_' | tr -d '=\n'; }
b64url_decode() {
  local s pad
  s=$(cat); s=${s//-/+}; s=${s//_/\/}
  pad=$(( (4 - ${#s} % 4) % 4 ))
  printf '%s%s' "$s" "$(printf '%*s' "$pad" '' | tr ' ' '=')" | base64 -d
}

# die <msg>: print to stderr and exit 1.
die() { echo "google: $*" >&2; exit 1; }
