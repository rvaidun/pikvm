#!/bin/bash
# Mac webcam + mic -> H.264/AAC MPEG-TS over UDP -> Pi
#
# Usage:
#   ./forward.sh [pi-host]
#   PORT=1234 OUT_WIDTH=640 OUT_HEIGHT=360 FPS=30 ./forward.sh 192.168.1.8
#
# The camera is captured at WIDTH x HEIGHT (a mode it supports) and scaled
# here to OUT_WIDTH x OUT_HEIGHT before encoding. The Pi turns the stream
# into the USB camera's uncompressed YUY2 640x480@30 / 1280x720@10 frames;
# resizing 720p there takes most of a Pi 4's CPU, while padding 640x360 to
# 640x480 is nearly free, so the Mac does the resize.
#
# Devices (from `ffmpeg -f avfoundation -list_devices true -i ""`):
#   video 0 = MacBook Pro Camera
#   audio 1 = MacBook Pro Microphone
# The indices move when an iPhone connects as a Continuity Camera; set
# VIDEO_IDX / AUDIO_IDX to match.

set -euo pipefail

PI_HOST="${1:-pizero.local}"
PORT="${PORT:-1234}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
OUT_WIDTH="${OUT_WIDTH:-640}"
OUT_HEIGHT="${OUT_HEIGHT:-360}"
FPS="${FPS:-30}"
VIDEO_IDX="${VIDEO_IDX:-0}"
AUDIO_IDX="${AUDIO_IDX:-1}"
VBITRATE="${VBITRATE:-2M}"
ABITRATE="${ABITRATE:-128k}"

echo "Capturing ${WIDTH}x${HEIGHT}, streaming ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS} to ${PI_HOST}:${PORT}"
echo "Video device index: $VIDEO_IDX   Audio device index: $AUDIO_IDX"
echo "Press Ctrl-C to stop."
echo

# A keyframe every second: the Pi restarts its decoder when the host switches
# camera modes, and a lost UDP packet only corrupts video until the next one.
exec ffmpeg -hide_banner -loglevel info \
  -f avfoundation \
    -framerate "$FPS" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -pixel_format uyvy422 \
    -i "${VIDEO_IDX}:${AUDIO_IDX}" \
  -map 0:v -vf "scale=${OUT_WIDTH}:${OUT_HEIGHT}" \
    -c:v h264_videotoolbox -b:v "$VBITRATE" -g "$FPS" -realtime 1 \
  -map 0:a -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2 \
  -f mpegts "udp://${PI_HOST}:${PORT}?pkt_size=1316"
