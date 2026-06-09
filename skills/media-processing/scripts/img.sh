#!/usr/bin/env bash
# img.sh — common image operations via ImageMagick, falling back to ffmpeg.
#
# Subcommands:
#   convert <in> <out>              change format by output extension
#   resize  <in> <WxH> <out>        fit within WxH, preserving aspect ratio
#   thumb   <in> <out> [size=512]   make a thumbnail no larger than size×size
#
# Prefers ImageMagick (`magick`/`convert`); uses ffmpeg if ImageMagick is absent.
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
usage() { sed -n '2,11p' "$0"; exit "${1:-0}"; }

IM=""
if have magick; then IM="magick"; elif have convert; then IM="convert"; fi

sub="${1:-}"; shift || true
case "$sub" in
  convert)
    [ $# -eq 2 ] || usage 2
    in="$1"; out="$2"
    if [ -n "$IM" ]; then "$IM" "$in" "$out"
    elif have ffmpeg; then ffmpeg -y -loglevel error -i "$in" "$out"
    else echo "need ImageMagick or ffmpeg" >&2; exit 127; fi
    echo "wrote $out" ;;

  resize)
    [ $# -eq 3 ] || usage 2
    in="$1"; geom="$2"; out="$3"
    if [ -n "$IM" ]; then "$IM" "$in" -resize "$geom" "$out"
    elif have ffmpeg; then
      w="${geom%x*}"; h="${geom#*x}"
      ffmpeg -y -loglevel error -i "$in" \
        -vf "scale='min($w,iw)':'min($h,ih)':force_original_aspect_ratio=decrease" "$out"
    else echo "need ImageMagick or ffmpeg" >&2; exit 127; fi
    echo "wrote $out" ;;

  thumb)
    [ $# -ge 2 ] || usage 2
    in="$1"; out="$2"; size="${3:-512}"
    if [ -n "$IM" ]; then "$IM" "$in" -thumbnail "${size}x${size}>" "$out"
    elif have ffmpeg; then
      ffmpeg -y -loglevel error -i "$in" \
        -vf "scale='min($size,iw)':'min($size,ih)':force_original_aspect_ratio=decrease" "$out"
    else echo "need ImageMagick or ffmpeg" >&2; exit 127; fi
    echo "wrote $out" ;;

  -h|--help|"") usage 0 ;;
  *) echo "unknown subcommand: $sub" >&2; usage 2 ;;
esac
