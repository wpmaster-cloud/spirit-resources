#!/usr/bin/env bash
# media_info.sh — summarize an audio/video/image file with ffprobe.
#
# Usage:
#   media_info.sh <file>          # human summary
#   media_info.sh <file> --raw    # full ffprobe JSON
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: media_info.sh <file> [--raw]" >&2; exit 2; }
FILE="$1"; shift || true
RAW=""
[ "${1:-}" = "--raw" ] && RAW=1

command -v ffprobe >/dev/null 2>&1 || {
  echo "ffprobe (part of ffmpeg) not installed. Install: apt-get install -y ffmpeg | brew install ffmpeg" >&2
  exit 127
}
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 2; }

J="$(ffprobe -v error -print_format json -show_format -show_streams -- "$FILE")"

if [ -n "$RAW" ] || ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$J"
  exit 0
fi

printf '%s' "$J" | jq -r '
  def n($v): ($v | tonumber? ) // 0;
  def fps($r): ($r | split("/") | if (length==2 and (.[1]|tonumber?)//0 != 0)
                 then ((.[0]|tonumber)/(.[1]|tonumber)) else 0 end);
  .format as $f
  | "file:     \($f.filename)",
    "format:   \($f.format_long_name // $f.format_name)",
    "duration: \(((n($f.duration))*100|floor)/100) s",
    "size:     \(((n($f.size))/1048576*100|floor)/100) MB",
    "bitrate:  \((n($f.bit_rate)/1000|floor)) kb/s",
    "streams:",
    ( .streams[]
      | "  #\(.index) \(.codec_type): \(.codec_name // "?")"
        + ( if .codec_type=="video"
              then " \(.width)x\(.height) @ \((fps(.r_frame_rate // "0/0")*100|floor)/100) fps"
            elif .codec_type=="audio"
              then " \(.sample_rate // "?")Hz \(.channels // "?")ch"
            else "" end )
    )
'
