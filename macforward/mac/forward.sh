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
# One-shot clips: video files in CLIPS_DIR (default clips/ next to this
# script) get keys 1-9 in name order (name them 1-wave.mp4, 2-nod.mp4, ...).
# A key plays that clip once from the start, then the base fallback clip
# picks up again where it left off. Pressing one while live switches to the
# clip too, so it also ends on the fallback; l goes back to the camera (and
# cuts a clip short). clipfeed.py (python3) feeds the base clip and the
# one-shot clips to ffmpeg as one stream. Make a clip with mkdir clips and
# LOOP=none ./make-fallback.sh <recording> clips/1-wave.mp4
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
# Started from live, a one-shot clip holds its first frame this long, so the
# switch (which takes ffmpeg ~0.2 s) doesn't cut off its start.
PREROLL_FRAMES="${PREROLL_FRAMES:-$((FPS / 5 + 1))}"
CLIPS_DIR="${CLIPS_DIR:-$HERE/clips}"

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

clips=()
for f in "$CLIPS_DIR"/*; do
  case "$f" in *.mp4|*.mov|*.m4v|*.mkv) clips+=("$f") ;; esac
  [ "${#clips[@]}" -ge 9 ] && break
done

FEEDER=""
if [ "${#clips[@]}" -gt 0 ]; then
  # The feeder writes the clip source as raw frames into a FIFO, playing
  # the base clip on a loop and a one-shot clip whenever it's told to.
  mkfifo "$TMP/clip.yuv" "$TMP/ctl"
  echo base >"$TMP/state"
  python3 "$HERE/clipfeed.py" "$OUT_WIDTH" "$OUT_HEIGHT" "$FPS" \
    "$TMP/ctl" "$TMP/state" "$FALLBACK" "${clips[@]}" \
    >"$TMP/clip.yuv" 2>"$TMP/clipfeed.log" &
  FEEDER=$!
  clip_in=(-f rawvideo -pix_fmt yuv420p -video_size "${OUT_WIDTH}x${OUT_HEIGHT}"
           -framerate "$FPS" -i "$TMP/clip.yuv")
else
  clip_in=(-re -stream_loop -1 -i "$FALLBACK")
fi

ffmpeg -hide_banner -loglevel warning -nostats "${camera[@]}" \
  "${clip_in[@]}" \
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
  [ -n "$FEEDER" ] && kill "$FEEDER" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

clip_keys=""
[ "${#clips[@]}" -gt 0 ] && clip_keys="  [1-${#clips[@]}] clip"
shown=""
status() {
  local playing=""
  [ -n "$FEEDER" ] && playing="$(cat "$TMP/state" 2>/dev/null || true)"
  if [ "$map" = 0 ]; then
    printf '\r\033[K\033[1;32m● LIVE\033[0m camera     [f] fallback%s  [space] toggle  [q] quit' "$clip_keys"
  elif [ "${playing#clip }" != "$playing" ]; then
    printf '\r\033[K\033[1;35m▶ CLIP %s\033[0m %s     [l] live%s  [q] quit' \
      "${playing#clip }" "$(basename "${clips[${playing#clip }-1]}")" "$clip_keys"
  else
    printf '\r\033[K\033[1;33m● FALLBACK\033[0m %s     [l] live%s  [space] toggle  [q] quit' \
      "$(basename "$FALLBACK")" "$clip_keys"
  fi
  shown="$map $playing"
}

feeder() {   # send a command to clipfeed.py
  [ -n "$FEEDER" ] && kill -0 "$FEEDER" 2>/dev/null && printf '%s\n' "$1" >"$TMP/ctl"
  return 0
}

select_source() {
  [ "$1" = "$map" ] && return
  map="$1"
  [ "$map" = 0 ] && feeder stop
  printf 'cstreamselect -1 map %s\n' "$map" >&3
  status
}

play_clip() {
  [ "$1" -le "${#clips[@]}" ] || return 0
  if [ "$map" = 0 ]; then
    feeder "play $1 $PREROLL_FRAMES"
  else
    feeder "play $1"
  fi
  select_source 1
  status
}

echo "Fallback clip: $FALLBACK"
i=0
while [ "$i" -lt "${#clips[@]}" ]; do echo "  [$((i + 1))] $(basename "${clips[$i]}")"; i=$((i + 1)); done
echo
status
while kill -0 "$FFMPEG" 2>/dev/null; do
  key=""
  read -rsn1 -t 1 key || true
  case "$key" in
    f|F) select_source 1 ;;
    l|L) select_source 0 ;;
    " ") select_source $((1 - map)) ;;
    [1-9]) play_clip "$key" ;;
    q|Q) exit 0 ;;
  esac
  # A clip ending changes the state file; keep the status line in step.
  [ -n "$FEEDER" ] && [ "$shown" != "$map $(cat "$TMP/state" 2>/dev/null)" ] && status
done

printf '\n'
echo "ffmpeg exited:" >&2
grep -v -e '^Enter command' -e '^Command reply' -e '^$' "$LOG" | tail -20 >&2
exit 1
