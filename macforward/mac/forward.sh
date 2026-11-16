#!/bin/bash
# Mac webcam + mic -> H.264/AAC MPEG-TS over UDP -> Pi
#
# Usage:
#   ./forward.sh [--clips-only] [--force] [pi-host]
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
# START=fallback starts on the clip. Both sources run in the same ffmpeg and
# output stream, so the switch is instant and the Pi sees one continuous
# camera. clipfeed.py (python3) plays the clips.
#
# Audio switches on its own: m toggles the target's mic between the live
# mic and the clip's audio (the sound of whichever clip is on, in sync with
# it; silent if the clip has none). So live camera + live mic, clip + live
# mic and clip + clip audio are all a key away (live camera + clip audio
# works too). MIC_START=clip starts on the clip's audio. The clip audio
# follows the clip even while the picture is live.
#
# s syncs the mic to the picture: the audio switches right away to match
# (live camera -> live mic, clip -> clip audio) and then follows every
# picture switch (f, l, space, 1-9). m while synced unsyncs and flips the
# mic; s again unsyncs. SYNC=1 starts synced.
#
# One-shot clips: video files in CLIPS_DIR (default clips/ next to this
# script) get keys 1-9 in name order (name them 1-wave.mp4, 2-nod.mp4, ...).
# A key plays that clip once from the start, then the base fallback clip
# picks up again where it left off. Pressing one while live switches to the
# clip too, so it also ends on the fallback; l goes back to the camera (and
# cuts a clip short). Make a clip with mkdir clips and
# LOOP=none ./make-fallback.sh <recording> clips/1-wave.mp4
#
# --clips-only (or --no-live): never send the camera. The camera isn't even
# opened; the picture is the fallback clip and the one-shot clips, and the
# audio is the mic or the clip's audio (m). It exits at once if the fallback
# clip or a one-shot clip is missing or unreadable.
#
# Only one forward.sh runs at a time: a second one refuses to start and says
# which is running. --force (or --override) stops the running one and takes
# over.
#
# Devices (from `ffmpeg -f avfoundation -list_devices true -i ""`):
#   video 0 = MacBook Pro Camera
#   audio 1 = MacBook Pro Microphone
# The indices move when an iPhone connects as a Continuity Camera; set
# VIDEO_IDX / AUDIO_IDX to match.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIPS_ONLY=0
FORCE=0
PI_HOST=""
for arg in "$@"; do
  case "$arg" in
    --clips-only|--no-live) CLIPS_ONLY=1 ;;
    --force|--override) FORCE=1 ;;
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
MIC_START="${MIC_START:-live}"
SYNC="${SYNC:-0}"
# Started from live, a one-shot clip holds its first frame this long, so the
# switch (which takes ffmpeg ~0.2 s) doesn't cut off its start.
PREROLL_FRAMES="${PREROLL_FRAMES:-$((FPS / 5 + 1))}"
CLIPS_DIR="${CLIPS_DIR:-$HERE/clips}"

# --- One at a time -------------------------------------------------------
# The lock is a directory (mkdir is atomic) holding our pid and, once they
# start, the pids of our ffmpeg and clipfeed, so a takeover can clear them
# out even if the old forward.sh was killed without cleaning up.
LOCK="/tmp/macforward.$(id -u).lock"

is_ours() {   # is pid $1 alive and running command matching $2
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null &&
    ps -p "$1" -o command= 2>/dev/null | grep -q -e "$2"
}

kill_leftovers() {   # the old run's ffmpeg / clipfeed, if still running
  local p
  for p in $(cat "$LOCK/children" 2>/dev/null); do
    is_ours "$p" 'ffmpeg\|clipfeed' && kill "$p" 2>/dev/null || true
  done
}

take_lock() {
  local tries pid _
  for tries in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$LOCK" 2>/dev/null; then
      echo $$ >"$LOCK/pid"
      return 0
    fi
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then   # another one is starting this instant
      sleep 0.2
      continue
    fi
    if is_ours "$pid" forward.sh; then
      if [ "$FORCE" = 0 ]; then
        echo "forward.sh is already running (pid $pid, started $(ps -p "$pid" -o lstart= | sed 's/^ *//; s/ *$//'))." >&2
        echo "Quit it there (q or Ctrl-C), or run with --force to stop it and take over." >&2
        exit 1
      fi
      echo "Stopping the forward.sh already running (pid $pid)..."
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 25); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
      kill -KILL "$pid" 2>/dev/null || true
    fi
    # Gone (or stale from a run that died): clear what it left and retry.
    kill_leftovers
    [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$pid" ] && rm -rf "$LOCK"
  done
  echo "Couldn't take the lock at $LOCK; remove it if no forward.sh is running." >&2
  exit 1
}
take_lock

FFMPEG=""
FEEDER=""
TMP=""
cleanup() {
  printf '\033[?7h\n'   # line wrap back on
  if [ -n "$FFMPEG" ] && kill -0 "$FFMPEG" 2>/dev/null; then
    # Let ffmpeg finish cleanly: q on its command FIFO, or else a TERM.
    { printf 'q' >&3; } 2>/dev/null || kill "$FFMPEG" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$FFMPEG" 2>/dev/null || break; sleep 0.2; done
    kill "$FFMPEG" 2>/dev/null || true
  fi
  [ -n "$FEEDER" ] && kill "$FEEDER" 2>/dev/null || true
  [ -n "$TMP" ] && rm -rf "$TMP"
  [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = $$ ] && rm -rf "$LOCK"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'printf "\nStopped (another forward.sh --force took over, or killed)."; exit 143' TERM

# --- Sources -------------------------------------------------------------
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
afit="aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo"
camera=(-f avfoundation -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}"
        -pixel_format uyvy422 -i "${VIDEO_IDX}:${AUDIO_IDX}")
[ "$CLIPS_ONLY" = 1 ] && camera=(-f avfoundation -i ":${AUDIO_IDX}")   # mic only
# A keyframe every second: the Pi restarts its decoder when the host switches
# camera modes, and a lost UDP packet only corrupts video until the next one.
output=(-c:v h264_videotoolbox -b:v "$VBITRATE" -g "$FPS" -realtime 1
        -c:a aac -b:a "$ABITRATE" -ar 48000 -ac 2
        -f mpegts "udp://${PI_HOST}:${PORT}?pkt_size=1316")

if [ ! -f "$FALLBACK" ]; then
  echo "No fallback clip at $FALLBACK; streaming the camera only. Press Ctrl-C to stop."
  echo
  # In the background so a TERM (a --force takeover) runs cleanup at once.
  ffmpeg -hide_banner -loglevel info -nostdin "${camera[@]}" \
    -map 0:v -vf "$fit" -map 0:a "${output[@]}" &
  FFMPEG=$!
  echo "$FFMPEG" >"$LOCK/children"
  wait "$FFMPEG" || exit $?
  exit 0
fi

# Both video sources feed streamselect and both audio sources astreamselect;
# ffmpeg reads filter commands from its stdin ("c<target> <time> <command>
# <arg>\n"), so a FIFO lets the key loop below flip their maps without
# restarting anything. clipfeed.py plays the clip (and its audio) in the
# background while live, so it never starts from frame one. Everything is
# rebased to t=0 and runs in real time, which keeps it in step.
case "$START" in
  fallback) map=1 ;;
  *)        map=0 ;;
esac
case "$MIC_START" in
  clip) amap=1 ;;
  *)    amap=0 ;;
esac
[ "$CLIPS_ONLY" = 1 ] && map=1
[ "$SYNC" = 1 ] && amap="$map"
TMP="$(mktemp -d)"
mkfifo "$TMP/cmd" "$TMP/clip.yuv" "$TMP/clip.pcm" "$TMP/ctl"
LOG="$TMP/ffmpeg.log"

# The feeder writes the clip's frames and audio into FIFOs, playing the base
# clip on a loop and a one-shot clip whenever it's told to.
echo base >"$TMP/state"
python3 "$HERE/clipfeed.py" "$OUT_WIDTH" "$OUT_HEIGHT" "$FPS" \
  "$TMP/ctl" "$TMP/state" "$TMP/clip.pcm" "$FALLBACK" ${clips[@]+"${clips[@]}"} \
  2>"$TMP/clipfeed.log" >"$TMP/clip.yuv" &   # stderr first: the FIFO open can fail
FEEDER=$!
clip_in=(-f rawvideo -pix_fmt yuv420p -video_size "${OUT_WIDTH}x${OUT_HEIGHT}"
         -framerate "$FPS" -i "$TMP/clip.yuv"
         -f s16le -ar 48000 -ac 2 -i "$TMP/clip.pcm")

# The two audio sources' clocks are a few tens of ms apart, so the switch
# would step the timestamps back (or skip ahead); aresample trims or fills
# the switch point to keep the output continuous.
audio_graph="[0:a]${afit},asetpts=PTS-STARTPTS[mic];[2:a]${afit},asetpts=PTS-STARTPTS[clipa];
             [mic][clipa]astreamselect=inputs=2:map=${amap},aresample=async=1[a]"
if [ "$CLIPS_ONLY" = 1 ]; then   # input 0 is the mic alone: no camera to select
  graph="[1:v]setpts=PTS-STARTPTS,${fit},fps=${FPS}[v];${audio_graph}"
else
  graph="[0:v]setpts=PTS-STARTPTS,${fit}[cam];[1:v]setpts=PTS-STARTPTS,${fit}[clip];
         [cam][clip]streamselect=inputs=2:map=${map},fps=${FPS}[v];${audio_graph}"
fi

ffmpeg -hide_banner -loglevel warning -nostats "${camera[@]}" \
  "${clip_in[@]}" \
  -filter_complex "$graph" \
  -map '[v]' -map '[a]' "${output[@]}" <"$TMP/cmd" 2>"$LOG" &
FFMPEG=$!
echo "$FFMPEG $FEEDER" >"$LOCK/children"
exec 3>"$TMP/cmd"   # hold the FIFO open, or ffmpeg sees EOF

# The keys are listed once at startup, so the status line stays short
# enough not to wrap (a wrapped line can't be redrawn in place with \r).
keys="[f] fallback  [l] live  [space] toggle"
[ "$CLIPS_ONLY" = 1 ] && keys=""
case "${#clips[@]}" in
  0) ;;
  1) keys="${keys:+$keys  }[1] clip" ;;
  *) keys="${keys:+$keys  }[1-${#clips[@]}] clips" ;;
esac
keys="$keys  [m] mic  [s] sync  [q] quit"
shown=""
status() {
  local playing video mic sync=""
  playing="$(cat "$TMP/state" 2>/dev/null || true)"
  if [ "$map" = 0 ]; then
    video=$'\033[1;32m● LIVE\033[0m camera'
  elif [ "${playing#clip }" != "$playing" ]; then
    video="$(printf '\033[1;35m▶ CLIP %s\033[0m %s' \
      "${playing#clip }" "$(basename "${clips[${playing#clip }-1]}")")"
  elif [ "$CLIPS_ONLY" = 1 ]; then
    video="$(printf '\033[1;33m● CLIPS ONLY\033[0m %s' "$(basename "$FALLBACK")")"
  else
    video="$(printf '\033[1;33m● FALLBACK\033[0m %s' "$(basename "$FALLBACK")")"
  fi
  if [ "$amap" = 0 ]; then
    mic=$'\033[1;32m🎤 live mic\033[0m'
  else
    mic=$'\033[1;33m🔊 clip audio\033[0m'
  fi
  [ "$SYNC" = 1 ] && sync=$'  \033[1;36m🔗 synced\033[0m'
  printf '\r\033[K%s   %s%s' "$video" "$mic" "$sync"
  shown="$map $amap $SYNC $playing"
}

feeder() {   # send a command to clipfeed.py
  kill -0 "$FEEDER" 2>/dev/null && printf '%s\n' "$1" >"$TMP/ctl"
  return 0
}

select_source() {
  [ "$1" = "$map" ] && return
  [ "$CLIPS_ONLY" = 1 ] && return   # there's no camera to switch to
  map="$1"
  [ "$map" = 0 ] && feeder stop
  printf 'cstreamselect -1 map %s\n' "$map" >&3
  [ "$SYNC" = 1 ] && select_audio "$map"
  status
}

select_audio() {
  [ "$1" = "$amap" ] && return
  amap="$1"
  printf 'castreamselect -1 map %s\n' "$amap" >&3
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
echo "$keys"
echo
printf '\033[?7l'   # no line wrap while the status line is up: a narrow
                    # window cuts it off instead of starting a new line
status
while kill -0 "$FFMPEG" 2>/dev/null; do
  key=""
  IFS= read -rsn1 -t 1 key || true   # IFS= or a space reads as nothing
  case "$key" in
    f|F) select_source 1 ;;
    l|L) select_source 0 ;;
    " ") select_source $((1 - map)) ;;
    m|M) SYNC=0; select_audio $((1 - amap)); status ;;
    s|S) if [ "$SYNC" = 1 ]; then SYNC=0; else SYNC=1; select_audio "$map"; fi; status ;;
    [1-9]) play_clip "$key" ;;
    q|Q) exit 0 ;;
  esac
  # A clip ending changes the state file; keep the status line in step.
  [ "$shown" != "$map $amap $SYNC $(cat "$TMP/state" 2>/dev/null)" ] && status
done

printf '\n'
echo "ffmpeg exited:" >&2
grep -v -e '^Enter command' -e '^Command reply' -e '^$' "$LOG" | tail -20 >&2
[ -s "$TMP/clipfeed.log" ] && { echo "clipfeed:" >&2; tail -10 "$TMP/clipfeed.log" >&2; }
exit 1
