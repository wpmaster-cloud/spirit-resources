#!/usr/bin/env bash
# transcribe.sh — speech-to-text for an audio file; prints the transcript.
#
# Usage:
#   transcribe.sh <audio-file>        # mp3 wav m4a ogg flac webm aac ...
#
# Long recordings make long transcripts; redirect to a file so the result
# isn't cut by the runtime's command-output cap:
#   transcribe.sh call.mp3 > transcript.txt
#
# Config (env; first set value wins):
#   endpoint  LLM_AUDIO_BASE_URL → https://api.openai.com/v1
#   api key   LLM_AUDIO_API_KEY  → LLM_API_KEY
#   model     LLM_STT_MODEL      → whisper-1
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: transcribe.sh <audio-file>" >&2; exit 2; }
FILE="$1"
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }

BASE="${LLM_AUDIO_BASE_URL:-https://api.openai.com/v1}"
KEY="${LLM_AUDIO_API_KEY:-${LLM_API_KEY:-}}"
STT="${LLM_STT_MODEL:-whisper-1}"
[ -n "$KEY" ] || { echo "no API key: set LLM_API_KEY (or LLM_AUDIO_API_KEY)" >&2; exit 1; }

RESP="$(mktemp)"
trap 'rm -f -- "$RESP"' EXIT

STATUS="$(curl -sS --connect-timeout 10 --max-time 600 --retry 2 \
  -o "$RESP" -w "%{http_code}" \
  -X POST "$BASE/audio/transcriptions" \
  -H "Authorization: Bearer $KEY" \
  -F model="$STT" -F file=@"$FILE")" || STATUS=000

if [ "${STATUS#2}" = "$STATUS" ]; then
  echo "transcription failed (HTTP $STATUS, $BASE, model $STT):" >&2
  cat "$RESP" >&2 2>/dev/null || true
  echo >&2
  echo "hint: the main provider may have no audio endpoint (Anthropic doesn't) — point LLM_AUDIO_BASE_URL/LLM_AUDIO_API_KEY at one that does (OpenAI whisper-1, Groq whisper-large-v3)." >&2
  exit 1
fi

TEXT="$(jq -r '.text // empty' "$RESP")"
[ -n "$TEXT" ] || { echo "no transcript in response:" >&2; cat "$RESP" >&2; exit 1; }
printf '%s\n' "$TEXT"
