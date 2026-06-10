#!/usr/bin/env bash
# speak.sh — text-to-speech; writes an audio file and prints its path.
#
# Usage:
#   speak.sh "text to say" [out.mp3]
#
# The output extension picks the audio format (mp3 default; also opus, aac,
# flac, wav). Most TTS models cap input around 4096 characters — split longer
# texts into several calls.
#
# Config (env; first set value wins):
#   endpoint  LLM_AUDIO_BASE_URL → https://api.openai.com/v1
#   api key   LLM_AUDIO_API_KEY  → LLM_API_KEY
#   model     LLM_TTS_MODEL      → tts-1      voice  LLM_TTS_VOICE → alloy
set -euo pipefail

[ $# -ge 1 ] || { echo 'usage: speak.sh "text" [out.mp3]' >&2; exit 2; }
TEXT="$1"
OUT="${2:-speech-$(date +%s).mp3}"
FORMAT="$(printf '%s' "${OUT##*.}" | tr '[:upper:]' '[:lower:]')"
case "$FORMAT" in
  mp3|opus|aac|flac|wav|pcm) ;;
  *) FORMAT="mp3"; OUT="$OUT.mp3" ;;
esac

BASE="${LLM_AUDIO_BASE_URL:-https://api.openai.com/v1}"
KEY="${LLM_AUDIO_API_KEY:-${LLM_API_KEY:-}}"
TTS="${LLM_TTS_MODEL:-tts-1}"
VOICE="${LLM_TTS_VOICE:-alloy}"
[ -n "$KEY" ] || { echo "no API key: set LLM_API_KEY (or LLM_AUDIO_API_KEY)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Text reaches jq via --rawfile, not argv, so length never hits the kernel cap.
printf '%s' "$TEXT" > "$TMP/text"
jq -nc --rawfile input "$TMP/text" \
  --arg model "$TTS" --arg voice "$VOICE" --arg fmt "$FORMAT" \
  '{model:$model, voice:$voice, input:$input, response_format:$fmt}' > "$TMP/payload"

STATUS="$(curl -sS --connect-timeout 10 --max-time 300 --retry 2 \
  -o "$TMP/audio" -w "%{http_code}" \
  -X POST "$BASE/audio/speech" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  --data-binary @"$TMP/payload")" || STATUS=000

if [ "${STATUS#2}" = "$STATUS" ]; then
  echo "text-to-speech failed (HTTP $STATUS, $BASE, model $TTS):" >&2
  cat "$TMP/audio" >&2 2>/dev/null || true
  echo >&2
  echo "hint: the main provider may have no audio endpoint (Anthropic doesn't) — point LLM_AUDIO_BASE_URL/LLM_AUDIO_API_KEY at one that does." >&2
  exit 1
fi
[ -s "$TMP/audio" ] || { echo "tts endpoint returned no audio" >&2; exit 1; }

case "$OUT" in */*) mkdir -p -- "$(dirname -- "$OUT")" ;; esac
mv -- "$TMP/audio" "$OUT"
echo "wrote $OUT"
