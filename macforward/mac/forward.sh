#!/bin/bash
# Mac webcam + mic -> H.264/AAC MPEG-TS over UDP -> Pi Zero
#
# Usage:
#   ./forward.sh [pi-zero-host]
#   PORT=1234 WIDTH=1280 HEIGHT=720 FPS=30 ./forward.sh pizero.local
#
# Devices (from `ffmpeg -f avfoundation -list_devices true -i ""`):
#   video 1 = MacBook Pro Camera
#   audio 1 = MacBook Pro Microphone
# Change VIDEO_IDX / AUDIO_IDX below if those indices move.

set -euo pipefail

PI_ZERO_HOST="${1:-pizero.local}"
PORT="${PORT:-1234}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
VIDEO_IDX="${VIDEO_IDX:-1}"
AUDIO_IDX="${AUDIO_IDX:-1}"
VBITRATE="${VBITRATE:-4M}"
ABITRATE="${ABITRATE:-128k}"

echo "Streaming ${WIDTH}x${HEIGHT}@${FPS} to ${PI_ZERO_HOST}:${PORT}"
echo "Video device index: $VIDEO_IDX   Audio device index: $AUDIO_IDX"
echo "Press Ctrl-C to stop."
echo

exec ffmpeg -hide_banner -loglevel info \
  -f avfoundation \
    -framerate "$FPS" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -pixel_format uyvy422 \
    -i "${VIDEO_IDX}:${AUDIO_IDX}" \
  -map 0:v -c:v h264_videotoolbox -b:v "$VBITRATE" -g $((FPS * 2)) -realtime 1 \
  -map 0:a -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2 \
  -f mpegts "udp://${PI_ZERO_HOST}:${PORT}?pkt_size=1316"
