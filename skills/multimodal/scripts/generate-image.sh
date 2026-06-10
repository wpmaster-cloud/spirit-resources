#!/usr/bin/env bash
# generate-image.sh — text-to-image; writes image file(s) and prints their paths.
#
# Usage:
#   generate-image.sh [-s 1024x1024] [-n count] "prompt" [out.png]
#
# Extra images (-n 2+) get a -2, -3, ... suffix beside the first. Handles both
# response styles: inline base64 (gpt-image-1 always; DALL·E when asked) and
# hosted URLs (downloaded). gpt-image-1 rejects response_format, DALL·E needs
# it to return base64 — the payload adapts to the model name.
#
# Config (env; first set value wins):
#   endpoint  LLM_IMAGE_BASE_URL → https://api.openai.com/v1
#   api key   LLM_IMAGE_API_KEY  → LLM_API_KEY
#   model     LLM_IMAGE_MODEL    → gpt-image-1
set -euo pipefail

usage() { echo 'usage: generate-image.sh [-s WxH] [-n count] "prompt" [out.png]' >&2; exit 2; }

SIZE=""; N=1
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SIZE="${2:?-s needs a size}"; shift 2 ;;
    -n) N="${2:?-n needs a count}"; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage
case "$N" in ''|*[!0-9]*) usage ;; esac
PROMPT="$1"
OUT="${2:-image-$(date +%s).png}"

BASE="${LLM_IMAGE_BASE_URL:-https://api.openai.com/v1}"
KEY="${LLM_IMAGE_API_KEY:-${LLM_API_KEY:-}}"
IMODEL="${LLM_IMAGE_MODEL:-gpt-image-1}"
[ -n "$KEY" ] || { echo "no API key: set LLM_API_KEY (or LLM_IMAGE_API_KEY)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

printf '%s' "$PROMPT" > "$TMP/prompt"
jq -nc --rawfile prompt "$TMP/prompt" \
  --arg model "$IMODEL" --arg size "$SIZE" --argjson n "$N" '
  {model:$model, prompt:$prompt, n:$n}
  + (if $size != "" then {size:$size} else {} end)
  + (if ($model | startswith("gpt-image")) then {} else {response_format:"b64_json"} end)' \
  > "$TMP/payload"

STATUS="$(curl -sS --connect-timeout 10 --max-time 600 --retry 2 \
  -o "$TMP/resp" -w "%{http_code}" \
  -X POST "$BASE/images/generations" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  --data-binary @"$TMP/payload")" || STATUS=000

if [ "${STATUS#2}" = "$STATUS" ]; then
  echo "image generation failed (HTTP $STATUS, $BASE, model $IMODEL):" >&2
  cat "$TMP/resp" >&2 2>/dev/null || true
  echo >&2
  echo "hint: the main provider may have no image endpoint (Anthropic doesn't) — point LLM_IMAGE_BASE_URL/LLM_IMAGE_API_KEY at OpenAI; gpt-image-1 needs a verified org, dall-e-3 works on any key." >&2
  exit 1
fi

COUNT="$(jq '.data | length' "$TMP/resp")"
[ "$COUNT" -gt 0 ] || { echo "image endpoint returned no data:" >&2; cat "$TMP/resp" >&2; exit 1; }

case "${OUT##*/}" in
  *.*) EXT=".${OUT##*.}" ;;
  *)   EXT=".png"; OUT="$OUT.png" ;;
esac
STEM="${OUT%"$EXT"}"
case "$OUT" in */*) mkdir -p -- "$(dirname -- "$OUT")" ;; esac

for ((i = 0; i < COUNT; i++)); do
  REL="$OUT"
  [ "$i" -gt 0 ] && REL="$STEM-$((i + 1))$EXT"
  if jq -e ".data[$i].b64_json" "$TMP/resp" >/dev/null; then
    # Base64 streams jq → base64 -d, never through argv or a shell variable.
    jq -r ".data[$i].b64_json" "$TMP/resp" | base64 -d > "$REL"
  else
    URL="$(jq -r ".data[$i].url // empty" "$TMP/resp")"
    [ -n "$URL" ] || { echo "entry $i has neither b64_json nor url; skipped" >&2; continue; }
    curl -fsSL --retry 2 -o "$REL" "$URL"
  fi
  echo "wrote $REL"
done
