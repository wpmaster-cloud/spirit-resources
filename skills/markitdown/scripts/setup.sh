#!/usr/bin/env bash
# Idempotently install the MarkItDown CLI so `markitdown` resolves on PATH.
#
# Strategy (first that works): uv tool -> pipx -> dedicated venv (+ ~/.local/bin shim).
# Also best-effort installs optional system deps (ffmpeg, exiftool) used only for
# audio transcription and image/audio metadata.
#
# Env:
#   MARKITDOWN_EXTRAS   pip extras to install. Default: "all".
#                       e.g. "pdf,docx,pptx,xlsx" for a smaller install.
#   MARKITDOWN_HOME     where the venv fallback lives.
#                       Default: $HOME/.markitdown-venv
set -euo pipefail

EXTRAS="${MARKITDOWN_EXTRAS:-all}"
SPEC="markitdown[${EXTRAS}]"

log() { printf '==> %s\n' "$*" >&2; }

# Already installed? no-op.
if command -v markitdown >/dev/null 2>&1; then
  log "markitdown already installed: $(command -v markitdown)"
  markitdown --version 2>/dev/null || true
  exit 0
fi

# --- pick a Python >= 3.10 (MarkItDown's minimum) ---------------------------
PY=""
for c in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$c" >/dev/null 2>&1 \
     && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,10) else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  log "no Python >=3.10 found."
  log "On Debian: sudo apt-get update && sudo apt-get install -y python3 python3-venv python3-pip pipx"
  exit 1
fi
log "using python: $("$PY" --version 2>&1) ($PY)"

installed=0

# 1) uv — fast, isolated tool install
if command -v uv >/dev/null 2>&1; then
  log "installing via: uv tool install '$SPEC'"
  uv tool install "$SPEC" && installed=1 || log "uv install failed, trying next method"
fi

# 2) pipx — isolated CLI on PATH
if [ "$installed" -eq 0 ] && command -v pipx >/dev/null 2>&1; then
  log "installing via: pipx install '$SPEC'"
  pipx install "$SPEC" && installed=1 || log "pipx install failed, trying next method"
fi

# 3) dedicated venv fallback (+ shim on PATH)
if [ "$installed" -eq 0 ]; then
  VENV="${MARKITDOWN_HOME:-$HOME/.markitdown-venv}"
  log "installing into venv: $VENV"
  "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip >/dev/null
  "$VENV/bin/pip" install "$SPEC"
  installed=1

  BIN_DIR="$HOME/.local/bin"
  if mkdir -p "$BIN_DIR" 2>/dev/null && ln -sf "$VENV/bin/markitdown" "$BIN_DIR/markitdown" 2>/dev/null; then
    log "linked $BIN_DIR/markitdown -> $VENV/bin/markitdown"
    case ":${PATH}:" in
      *":$BIN_DIR:"*) ;;
      *) log "NOTE: $BIN_DIR is not on PATH — run: export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac
  else
    log "venv ready — call it directly: $VENV/bin/markitdown"
  fi
fi

# --- optional system deps (audio transcription / EXIF metadata) -------------
if command -v apt-get >/dev/null 2>&1; then
  SUDO=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  if $SUDO apt-get update -y >/dev/null 2>&1 \
     && $SUDO apt-get install -y ffmpeg libimage-exiftool-perl >/dev/null 2>&1; then
    log "installed optional system deps: ffmpeg, exiftool"
  else
    log "skipped optional system deps (ffmpeg, exiftool) — only needed for audio/image"
  fi
fi

# --- verify -----------------------------------------------------------------
if command -v markitdown >/dev/null 2>&1; then
  log "OK: $(command -v markitdown)"
  markitdown --version 2>/dev/null || true
else
  log "markitdown installed but not on PATH yet (see notes above)."
fi
