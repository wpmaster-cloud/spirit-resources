#!/usr/bin/env bash
set -euo pipefail

TOKEN_FILE="${GOOGLE_OAUTH_TOKEN_FILE:-/workspace/google-token.json}"

strip_wrapping_quotes() {
  local s="$1"
  s="${s%\"}"
  s="${s#\"}"
  s="${s%\'}"
  s="${s#\'}"
  printf '%s' "$s"
}

if [[ -n "${GOOGLE_OAUTH_TOKEN_JSON_B64:-}" ]]; then
  TOKEN_B64=$(printf '%s' "${GOOGLE_OAUTH_TOKEN_JSON_B64}" | tr -d '[:space:]')
  TOKEN_B64=$(strip_wrapping_quotes "$TOKEN_B64")
  PAD=$(( (4 - ${#TOKEN_B64} % 4) % 4 ))
  if [[ "$PAD" -eq 1 ]]; then
    TOKEN_B64="${TOKEN_B64}="
  elif [[ "$PAD" -eq 2 ]]; then
    TOKEN_B64="${TOKEN_B64}=="
  elif [[ "$PAD" -eq 3 ]]; then
    TOKEN_B64="${TOKEN_B64}==="
  fi
  printf '%s' "$TOKEN_B64" | base64 -d >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE" || true
  echo "Wrote Google OAuth token file: $TOKEN_FILE"
elif [[ -n "${GOOGLE_OAUTH_TOKEN_JSON:-}" ]]; then
  TOKEN_JSON=$(strip_wrapping_quotes "${GOOGLE_OAUTH_TOKEN_JSON}")
  printf '%s' "$TOKEN_JSON" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE" || true
  echo "Wrote Google OAuth token file: $TOKEN_FILE"
else
  echo "GOOGLE_OAUTH_TOKEN_JSON_B64 or GOOGLE_OAUTH_TOKEN_JSON is required."
  exit 1
fi

PYBIN="/python/bin/python3"
if [[ ! -x "$PYBIN" ]]; then
  PYBIN="/python/bin/python"
fi
if [[ ! -x "$PYBIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYBIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYBIN="$(command -v python)"
  else
    echo "Python not found. Install Python first (e.g. ./scripts/install_python.sh)."
    exit 1
  fi
fi

echo "Installing Gmail Python dependencies via ${PYBIN}..."
"$PYBIN" -m pip install --upgrade --quiet google-auth-oauthlib google-auth google-api-python-client

if "$PYBIN" -c "import google_auth_oauthlib, google.auth, googleapiclient" >/dev/null 2>&1; then
  echo "Gmail Python environment is ready."
else
  echo "Gmail dependency validation failed."
  exit 1
fi
