#!/usr/bin/env bash
# analyze-video.sh — summarize a video: frames go to the vision model, the
# audio track gets transcribed, and both sections are printed.
#
# Usage:
#   analyze-video.sh [-p "prompt"] [-n max-frames] <video>
#
# Frames are sampled evenly across the whole clip (ffprobe for the duration
# when available, else 1 fps), capped at max-frames (default 8) so vision cost
# stays flat regardless of clip length. A silent clip, a missing audio track,
# or unconfigured transcription drops the transcript section with a note on
# stderr instead of failing the visual summary. Requires ffmpeg.
#
# Config: same environment as analyze-image.sh and transcribe.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROMPT=""; MAX=8
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROMPT="${2:?-p needs a prompt}"; shift 2 ;;
    -n) MAX="${2:?-n needs a count}"; shift 2 ;;
    -*) echo 'usage: analyze-video.sh [-p "prompt"] [-n max-frames] <video>' >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo 'usage: analyze-video.sh [-p "prompt"] [-n max-frames] <video>' >&2; exit 2; }
case "$MAX" in ''|*[!0-9]*|0) echo "-n needs a positive integer" >&2; exit 2 ;; esac
VIDEO="$1"
[ -f "$VIDEO" ] || { echo "no such file: $VIDEO" >&2; exit 2; }
command -v ffmpeg >/dev/null 2>&1 || {
  echo "ffmpeg not installed. Install: apt-get install -y ffmpeg | brew install ffmpeg" >&2
  exit 127
}

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Sample evenly across the clip when the duration is known, else 1 fps;
# -frames:v caps the count either way.
FPS=1
if command -v ffprobe >/dev/null 2>&1; then
  DUR="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 -- "$VIDEO" 2>/dev/null || true)"
  case "$DUR" in
    ''|N/A) ;;
    *) FPS="$(awk -v n="$MAX" -v d="$DUR" 'BEGIN { if (d > 0) printf "%.6f", n / d; else print 1 }')" ;;
  esac
fi
ffmpeg -v error -i "$VIDEO" -vf "fps=$FPS" -frames:v "$MAX" -y "$TMP/frame_%03d.jpg"

FRAMES=("$TMP"/frame_*.jpg)
[ -e "${FRAMES[0]}" ] || { echo "could not extract any frames from $VIDEO" >&2; exit 1; }

VP="${PROMPT:-Describe what happens in this video.}"
VP="$VP

(You are given ${#FRAMES[@]} frames sampled in chronological order from a video.)"
VISUAL="$("$SCRIPT_DIR/analyze-image.sh" -p "$VP" "${FRAMES[@]}")"
printf 'Visual analysis (%s sampled frames):\n%s\n' "${#FRAMES[@]}" "$VISUAL"

# Audio: extract as mono 16 kHz WAV (no external encoder needed) and transcribe.
if ffmpeg -v error -i "$VIDEO" -vn -ac 1 -ar 16000 -y "$TMP/audio.wav" 2>/dev/null \
  && [ -s "$TMP/audio.wav" ]; then
  if TRANSCRIPT="$("$SCRIPT_DIR/transcribe.sh" "$TMP/audio.wav")" && [ -n "$TRANSCRIPT" ]; then
    printf '\nAudio transcript:\n%s\n' "$TRANSCRIPT"
  else
    echo "(transcription unavailable — visual summary only)" >&2
  fi
else
  echo "(no audio track — visual summary only)" >&2
fi
