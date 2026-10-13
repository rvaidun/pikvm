#!/bin/bash
# Smoke-test: record 5 seconds of camera + mic to a file.
# If the file plays with both video and audio, the encoding half of forward.sh works.
set -euo pipefail

OUT="/tmp/macforward-test.mp4"
rm -f "$OUT"

ffmpeg -hide_banner -y \
  -f avfoundation -framerate 30 -video_size 1280x720 -pixel_format uyvy422 \
  -i "1:1" \
  -t 5 \
  -c:v h264_videotoolbox -b:v 4M \
  -c:a aac -b:a 128k \
  "$OUT"

echo
echo "Wrote $OUT. Opening in QuickTime..."
open -a "QuickTime Player" "$OUT"
