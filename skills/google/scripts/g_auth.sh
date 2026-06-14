#!/usr/bin/env bash
# One-time: mint a Google OAuth refresh token via the loopback flow, so the other
# scripts can run unattended forever after. Opens a consent URL in your browser,
# captures Google's redirect on 127.0.0.1, exchanges the code, and prints (or
# saves) the refresh token. Run this on a machine WITH a browser (e.g. your
# laptop), not in a headless pod. Needs: curl, jq, python3.
#
# The OAuth client must allow the loopback redirect: a "Desktop app" client does
# automatically; a "Web application" client needs http://localhost:<port> added
# to its Authorized redirect URIs in the Cloud Console.
#
# Usage:
#   g_auth.sh                 # scopes: gmail send+modify, drive, calendar
#   g_auth.sh --port 8765     # change the loopback port (must match the client)
#   g_auth.sh --scope "https://www.googleapis.com/auth/gmail.readonly"
#   g_auth.sh --save          # also append GOOGLE_REFRESH_TOKEN to google/config.env
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null || true
STATE_DIR="${GOOGLE_STATE_DIR:-google}"; mkdir -p "$STATE_DIR"
# Only client id/secret are needed here — NOT a refresh token (we're minting it),
# so this script deliberately does not source _common.sh.
if [ -z "${GOOGLE_CLIENT_ID:-}" ] && [ -f "$STATE_DIR/config.env" ]; then
  set -a; . "$STATE_DIR/config.env"; set +a
fi
: "${GOOGLE_CLIENT_ID:?set GOOGLE_CLIENT_ID (env or google/config.env)}"
: "${GOOGLE_CLIENT_SECRET:?set GOOGLE_CLIENT_SECRET}"
command -v python3 >/dev/null || { echo "g_auth: python3 required for the loopback listener" >&2; exit 1; }

PORT=8765; SAVE=0
SCOPE="https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/calendar"
while [ $# -gt 0 ]; do
  case "$1" in
    --port)  PORT="$2"; shift 2;;
    --scope) SCOPE="$2"; shift 2;;
    --save)  SAVE=1; shift;;
    *) echo "g_auth: unknown flag: $1" >&2; exit 1;;
  esac
done

REDIRECT="http://localhost:$PORT"
CODEFILE="$STATE_DIR/.oauth_code"; rm -f "$CODEFILE"
enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$SCOPE")
AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth?client_id=${GOOGLE_CLIENT_ID}&redirect_uri=${REDIRECT}&response_type=code&scope=${enc}&access_type=offline&prompt=consent"

# One-shot listener: serve exactly one request, save its ?code=, then exit.
python3 - "$PORT" "$CODEFILE" >/dev/null 2>&1 <<'PY' &
import sys, http.server, urllib.parse
port=int(sys.argv[1]); codefile=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        open(codefile,'w').write(p.get('code',[''])[0])
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers()
        self.wfile.write(b'<h2>Authorized. Close this tab and return to the terminal.</h2>')
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',port),H).handle_request()
PY
LISTENER=$!

echo "==> Open this URL, sign in, and approve (browser on THIS machine):"
echo
echo "$AUTH_URL"
echo
command -v open >/dev/null && open "$AUTH_URL" >/dev/null 2>&1 || true
echo "==> Waiting for the redirect on $REDIRECT (up to 180s)..."
for _ in $(seq 1 180); do [ -s "$CODEFILE" ] && break; sleep 1; done
wait "$LISTENER" 2>/dev/null || true
CODE=$(cat "$CODEFILE" 2>/dev/null || true); rm -f "$CODEFILE"
[ -n "$CODE" ] || { echo "g_auth: no authorization code received (timed out, denied, or redirect_uri mismatch)" >&2; exit 1; }

resp=$(curl -sS https://oauth2.googleapis.com/token \
  -d client_id="$GOOGLE_CLIENT_ID" -d client_secret="$GOOGLE_CLIENT_SECRET" \
  -d code="$CODE" -d grant_type=authorization_code -d redirect_uri="$REDIRECT")
RT=$(printf '%s' "$resp" | jq -r '.refresh_token // empty')
[ -n "$RT" ] || { echo "g_auth: token exchange failed: $(printf '%s' "$resp" | jq -r '.error_description // .error // .')" >&2; exit 1; }

echo
echo "==> Success. Store this (env var or google/config.env):"
echo "GOOGLE_REFRESH_TOKEN=$RT"
if [ "$SAVE" = 1 ]; then
  printf 'GOOGLE_REFRESH_TOKEN=%s\n' "$RT" >> "$STATE_DIR/config.env"
  echo "(appended to $STATE_DIR/config.env)"
fi
