#!/usr/bin/env bash
# Spin up the bash-agent session editor UI.
#
# Usage:
#   ./ui.sh                                  # edit ./session.jsonl, open a browser
#   ./ui.sh --port 9000
#   ./ui.sh --session /path/to/other/session.jsonl   # edit any agent's session
#   ./ui.sh --no-open                        # don't auto-open a browser
#
# A thin launcher for ui/server.js — a zero-dependency Node stdlib server (no
# build step, no npm install). All arguments are passed straight through; the
# SESSION_FILE env var and the server's flags are honored. See ui/README.md.

set -euo pipefail

# Resolve this script's folder and run from there, so it behaves the same no
# matter where it is invoked (the same trick agent.sh uses).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v node >/dev/null 2>&1; then
  printf 'ui.sh needs Node.js (node) on PATH to serve the session editor.\n' >&2
  exit 1
fi

exec node "$SCRIPT_DIR/ui/server.js" "$@"
