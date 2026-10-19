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
# Fallback video: with a clip at FALLBACK (default fallback.mp4 next to this
# script; make one with make-fallback.sh), keys switch the picture while it
# runs: f = fallback clip (looped), l = live camera, space = toggle, q = quit.
# START=fallback starts on the clip. The mic stays live either way. Both
# sources run in the same ffmpeg and output stream, so the switch is
# instant and the Pi sees one continuous camera.
#
# Devices (from `ffmpeg -f avfoundation -list_devices true -i ""`):
#   video 0 = MacBook Pro Camera
#   audio 1 = MacBook Pro Microphone
# The indices move when an iPhone connects as a Continuity Camera; set
# VIDEO_IDX / AUDIO_IDX to match.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
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
FALLBACK="${FALLBACK:-$HERE/fallback.mp4}"
START="${START:-live}"

echo "Capturing ${WIDTH}x${HEIGHT}, streaming ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS} to ${PI_HOST}:${PORT}"
echo "Video device index: $VIDEO_IDX   Audio device index: $AUDIO_IDX"

fit="scale=${OUT_WIDTH}:${OUT_HEIGHT}:force_original_aspect_ratio=increase,crop=${OUT_WIDTH}:${OUT_HEIGHT},setsar=1,format=yuv420p"
camera=(-f avfoundation -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}"
        -pixel_format uyvy422 -i "${VIDEO_IDX}:${AUDIO_IDX}")
# A keyframe every second: the Pi restarts its decoder when the host switches
# camera modes, and a lost UDP packet only corrupts video until the next one.
output=(-c:v h264_videotoolbox -b:v "$VBITRATE" -g "$FPS" -realtime 1
        -map 0:a -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2
        -f mpegts "udp://${PI_HOST}:${PORT}?pkt_size=1316")

if [ ! -f "$FALLBACK" ]; then
  echo "No fallback clip at $FALLBACK; streaming the camera only. Press Ctrl-C to stop."
  echo
  exec ffmpeg -hide_banner -loglevel info "${camera[@]}" \
    -map 0:v -vf "$fit" "${output[@]}"
fi

# Both sources feed streamselect; ffmpeg reads filter commands from its stdin
# ("c<target> <time> <command> <arg>\n"), so a FIFO lets the key loop below
# flip streamselect's map without restarting anything. The clip plays (and
# loops) in the background while live, so it never starts from frame one.
# Both are rebased to t=0 and run in real time, which keeps them in step.
case "$START" in
  fallback) map=1 ;;
  *)        map=0 ;;
esac
TMP="$(mktemp -d)"
mkfifo "$TMP/cmd"
LOG="$TMP/ffmpeg.log"

ffmpeg -hide_banner -loglevel warning -nostats "${camera[@]}" \
  -re -stream_loop -1 -i "$FALLBACK" \
  -filter_complex "[0:v]setpts=PTS-STARTPTS,${fit}[cam];[1:v]setpts=PTS-STARTPTS,${fit}[clip];
                   [cam][clip]streamselect=inputs=2:map=${map},fps=${FPS}[v]" \
  -map '[v]' "${output[@]}" <"$TMP/cmd" 2>"$LOG" &
FFMPEG=$!
exec 3>"$TMP/cmd"   # hold the FIFO open, or ffmpeg sees EOF

cleanup() {
  printf '\n'
  if kill -0 "$FFMPEG" 2>/dev/null; then
    printf 'q' >&3 2>/dev/null || true       # let ffmpeg finish cleanly
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$FFMPEG" 2>/dev/null || break; sleep 0.2; done
    kill "$FFMPEG" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

status() {
  if [ "$map" = 0 ]; then
    printf '\r\033[K\033[1;32m● LIVE\033[0m camera     [f] fallback  [space] toggle  [q] quit'
  else
    printf '\r\033[K\033[1;33m● FALLBACK\033[0m %s     [l] live  [space] toggle  [q] quit' "$(basename "$FALLBACK")"
  fi
}

select_source() {
  [ "$1" = "$map" ] && return
  map="$1"
  printf 'cstreamselect -1 map %s\n' "$map" >&3
  status
}

echo "Fallback clip: $FALLBACK"
echo
status
while kill -0 "$FFMPEG" 2>/dev/null; do
  key=""
  read -rsn1 -t 1 key || true
  case "$key" in
    f|F) select_source 1 ;;
    l|L) select_source 0 ;;
    " ") select_source $((1 - map)) ;;
    q|Q) exit 0 ;;
  esac
done

printf '\n'
echo "ffmpeg exited:" >&2
grep -v -e '^Enter command' -e '^Command reply' -e '^$' "$LOG" | tail -20 >&2
exit 1
