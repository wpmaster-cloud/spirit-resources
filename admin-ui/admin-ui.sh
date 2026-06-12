#!/usr/bin/env bash
set -euo pipefail

# Spirit admin UI — the fleet control plane in one Go binary, web UI
# embedded. An agent (or you) runs this next to a fleet folder and gets
# the API + dashboard on one port.
#
#   ./admin-ui.sh [--root DIR] [--port N] [--host IP] [--token T]
#
#   --root   agents folder (default: $AGENTS_ROOT, else ./agents)
#   --port   listen port              (default 8900)
#   --host   bind address             (default 127.0.0.1 — yours, on your machine)
#   --token  require "Authorization: Bearer T" on /api
#
# Runs the first of: ./admin-ui binary next to this script → `go run .`
# → a prebuilt binary downloaded from the spirit-resources releases.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${AGENTS_ROOT:-$PWD/agents}"
HOST=127.0.0.1
PORT=8900
TOKEN="${ADMIN_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)  ROOT="$2";  shift 2 ;;
    --port)  PORT="$2";  shift 2 ;;
    --host)  HOST="$2";  shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    *) echo "unknown flag: $1 (known: --root --port --host --token)" >&2; exit 64 ;;
  esac
done

# the canonical agent.sh new agents copy: caller's env wins, then the
# spirit repo layout, then an agent.sh next to the fleet (in-pod case)
if [[ -z "${AGENT_SH_SOURCE:-}" ]]; then
  for cand in "$DIR/../../agent/agent.sh" "$(dirname "$ROOT")/agent.sh" "$PWD/agent.sh"; do
    [[ -f "$cand" ]] && AGENT_SH_SOURCE="$cand" && break
  done
fi

export AGENTS_ROOT="$ROOT" LISTEN_ADDR="$HOST:$PORT" ADMIN_TOKEN="$TOKEN" \
       AGENT_SH_SOURCE="${AGENT_SH_SOURCE:-agent.sh}"

if [[ -x "$DIR/admin-ui" ]]; then
  exec "$DIR/admin-ui"
fi
if command -v go >/dev/null 2>&1; then
  cd "$DIR" && exec go run .
fi

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
URL="https://github.com/wpmaster-cloud/spirit-resources/releases/latest/download/admin-ui-$OS-$ARCH"
echo "==> no local binary and no Go toolchain — fetching $URL"
curl -fsSL -o "$DIR/admin-ui" "$URL"
chmod +x "$DIR/admin-ui"
exec "$DIR/admin-ui"
