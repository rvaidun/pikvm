#!/bin/bash
# Mac webcam + mic -> H.264/AAC MPEG-TS over UDP -> Pi
#
# Usage:
#   ./forward.sh [--clips-only] [pi-host]
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
# --clips-only (or --no-live): never send the camera. The camera isn't even
# opened; the picture is the fallback clip and the one-shot clips, and only
# the mic is live. It exits at once if the fallback clip or a one-shot clip
# is missing or unreadable.
#
# Devices (from `ffmpeg -f avfoundation -list_devices true -i ""`):
#   video 0 = MacBook Pro Camera
#   audio 1 = MacBook Pro Microphone
# The indices move when an iPhone connects as a Continuity Camera; set
# VIDEO_IDX / AUDIO_IDX to match.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIPS_ONLY=0
PI_HOST=""
for arg in "$@"; do
  case "$arg" in
    --clips-only|--no-live) CLIPS_ONLY=1 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    *)  PI_HOST="$arg" ;;
  esac
done
PI_HOST="${PI_HOST:-pizero.local}"
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

clips=()
for f in "$CLIPS_DIR"/*; do
  case "$f" in *.mp4|*.mov|*.m4v|*.mkv) clips+=("$f") ;; esac
  [ "${#clips[@]}" -ge 9 ] && break
done

if [ "$CLIPS_ONLY" = 1 ]; then
  # Fail now rather than after the stream is up: a bad clip would mean
  # nothing to show, and there's no camera to fall back to.
  for f in "$FALLBACK" ${clips[@]+"${clips[@]}"}; do
    if [ ! -f "$f" ]; then
      echo "--clips-only needs a fallback clip, and there's none at $FALLBACK" >&2
      echo "(make one with make-fallback.sh, or set FALLBACK=...)" >&2
      exit 1
    fi
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
         -of csv=p=0 "$f" 2>/dev/null | grep -q video; then
      echo "--clips-only: no readable video in $f" >&2
      exit 1
    fi
  done
  echo "Clips only (no camera), streaming ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS} to ${PI_HOST}:${PORT}"
  echo "Audio device index: $AUDIO_IDX"
else
  echo "Capturing ${WIDTH}x${HEIGHT}, streaming ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS} to ${PI_HOST}:${PORT}"
  echo "Video device index: $VIDEO_IDX   Audio device index: $AUDIO_IDX"
fi

fit="scale=${OUT_WIDTH}:${OUT_HEIGHT}:force_original_aspect_ratio=increase,crop=${OUT_WIDTH}:${OUT_HEIGHT},setsar=1,format=yuv420p"
camera=(-f avfoundation -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}"
        -pixel_format uyvy422 -i "${VIDEO_IDX}:${AUDIO_IDX}")
[ "$CLIPS_ONLY" = 1 ] && camera=(-f avfoundation -i ":${AUDIO_IDX}")   # mic only
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
[ "$CLIPS_ONLY" = 1 ] && map=1
TMP="$(mktemp -d)"
mkfifo "$TMP/cmd"
LOG="$TMP/ffmpeg.log"

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
  # Loop through the concat demuxer, the clip listed 1000 times, rather than
  # -stream_loop alone: with -re, each -stream_loop wrap stalled the stream
  # ~0.5 s and then burst, longer than the Pi's jitter buffer, so the loop
  # point froze and skipped. Concat goes on to the next copy without the
  # stall; -stream_loop only has to cover the (hours-long) list.
  esc="$(printf '%s' "$FALLBACK" | sed "s/'/'\\\\''/g")"
  { echo "ffconcat version 1.0"
    for _ in $(seq 1000); do echo "file '$esc'"; done; } >"$TMP/loop.ffconcat"
  clip_in=(-re -f concat -safe 0 -stream_loop -1 -i "$TMP/loop.ffconcat")
fi

if [ "$CLIPS_ONLY" = 1 ]; then   # input 0 is the mic alone: no camera to select
  graph="[1:v]setpts=PTS-STARTPTS,${fit},fps=${FPS}[v]"
else
  graph="[0:v]setpts=PTS-STARTPTS,${fit}[cam];[1:v]setpts=PTS-STARTPTS,${fit}[clip];
         [cam][clip]streamselect=inputs=2:map=${map},fps=${FPS}[v]"
fi

ffmpeg -hide_banner -loglevel warning -nostats "${camera[@]}" \
  "${clip_in[@]}" \
  -filter_complex "$graph" \
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
live_key="[l] live  "
[ "$CLIPS_ONLY" = 1 ] && live_key=""
shown=""
status() {
  local playing=""
  [ -n "$FEEDER" ] && playing="$(cat "$TMP/state" 2>/dev/null || true)"
  if [ "$map" = 0 ]; then
    printf '\r\033[K\033[1;32m● LIVE\033[0m camera     [f] fallback%s  [space] toggle  [q] quit' "$clip_keys"
  elif [ "${playing#clip }" != "$playing" ]; then
    printf '\r\033[K\033[1;35m▶ CLIP %s\033[0m %s     %s%s  [q] quit' \
      "${playing#clip }" "$(basename "${clips[${playing#clip }-1]}")" "$live_key" "${clip_keys#  }"
  elif [ "$CLIPS_ONLY" = 1 ]; then
    printf '\r\033[K\033[1;33m● CLIPS ONLY\033[0m %s     %s  [q] quit' \
      "$(basename "$FALLBACK")" "${clip_keys#  }"
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
  [ "$CLIPS_ONLY" = 1 ] && return   # there's no camera to switch to
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
