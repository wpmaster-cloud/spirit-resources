#!/usr/bin/env bash
# analyze-image.sh — describe or answer questions about image(s) with a vision model.
#
# Usage:
#   analyze-image.sh [-p "prompt"] <image> [image ...]
#
# Images are local paths or http(s) URLs. Everything is inlined as a base64
# data URI (never passed as a remote URL), so it works on every OpenAI-
# compatible endpoint — including Anthropic's compatibility layer, which
# rejects URL images. The model's answer is printed to stdout.
#
# Config (env; first set value wins):
#   endpoint  LLM_VISION_BASE_URL → BASE_URL → https://api.openai.com/v1
#   api key   LLM_VISION_API_KEY  → LLM_API_KEY
#   model     LLM_VISION_MODEL    → MODEL    → gpt-5.5
set -euo pipefail

PROMPT="Describe this image in detail."
if [ "${1:-}" = "-p" ]; then PROMPT="${2:?-p needs a prompt}"; shift 2; fi
[ $# -ge 1 ] || { echo 'usage: analyze-image.sh [-p "prompt"] <image> [image ...]' >&2; exit 2; }

BASE="${LLM_VISION_BASE_URL:-${BASE_URL:-https://api.openai.com/v1}}"
KEY="${LLM_VISION_API_KEY:-${LLM_API_KEY:-}}"
VMODEL="${LLM_VISION_MODEL:-${MODEL:-gpt-5.5}}"
[ -n "$KEY" ] || { echo "no API key: set LLM_API_KEY (or LLM_VISION_API_KEY)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# MIME type from the name's extension, else from the file's magic bytes.
mime_for() { # <name-for-extension> <local-path>
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    png) echo image/png ;; jpg|jpeg) echo image/jpeg ;; gif) echo image/gif ;;
    webp) echo image/webp ;; bmp) echo image/bmp ;;
    *) { command -v file >/dev/null 2>&1 && file --mime-type -b -- "$2"; } || echo image/png ;;
  esac
}

# Build the content array one part at a time. Image bytes ride into jq via
# --rawfile, never argv: argv is capped by the kernel and photos exceed it.
printf '%s' "$PROMPT" > "$TMP/prompt"
jq -nc --rawfile p "$TMP/prompt" '[{type:"text", text:$p}]' > "$TMP/content"

i=0
for SRC in "$@"; do
  i=$((i + 1))
  IMG="$SRC"
  case "$SRC" in
    http://*|https://*)
      IMG="$TMP/dl-$i"
      curl -fsSL --retry 2 -o "$IMG" "$SRC" || { echo "download failed: $SRC" >&2; exit 1; }
      ;;
  esac
  [ -f "$IMG" ] || { echo "no such image: $SRC" >&2; exit 2; }
  base64 < "$IMG" | tr -d '\n' > "$TMP/b64"
  jq -c --rawfile data "$TMP/b64" --arg mime "$(mime_for "$SRC" "$IMG")" \
    '. + [{type:"image_url", image_url:{url:("data:" + $mime + ";base64," + $data)}}]' \
    "$TMP/content" > "$TMP/content.next"
  mv "$TMP/content.next" "$TMP/content"
done

jq -c --arg model "$VMODEL" '{model:$model, messages:[{role:"user", content:.}]}' \
  "$TMP/content" > "$TMP/payload"

STATUS="$(curl -sS --connect-timeout 10 --max-time 300 --retry 2 \
  -o "$TMP/resp" -w "%{http_code}" \
  -X POST "$BASE/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  --data-binary @"$TMP/payload")" || STATUS=000

if [ "${STATUS#2}" = "$STATUS" ]; then
  echo "vision request failed (HTTP $STATUS, $BASE, model $VMODEL):" >&2
  cat "$TMP/resp" >&2 2>/dev/null || true
  echo >&2
  exit 1
fi

TEXT="$(jq -r '.choices[0].message.content // empty' "$TMP/resp")"
[ -n "$TEXT" ] || { echo "vision model returned no text:" >&2; cat "$TMP/resp" >&2; exit 1; }
printf '%s\n' "$TEXT"
