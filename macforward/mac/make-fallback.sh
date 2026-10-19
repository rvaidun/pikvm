#!/bin/bash
# Turn a recording into forward.sh's fallback clip: what the target's camera
# shows when you press f (see forward.sh).
#
# Usage:
#   ./make-fallback.sh <recording> [out.mp4]
#   LOOP=crossfade START=2 DURATION=30 ./make-fallback.sh ~/Downloads/sample.mov
#
# Writes fallback.mp4 next to this script by default, which is where
# forward.sh looks. The clip matches the live stream so the switch isn't
# obvious: 640x360 (cropped to 16:9), 30 fps, no audio (the mic stays live),
# no metadata (QuickTime records the Mac's make, model and dates). forward.sh
# plays it on a loop, so the loop seam is hidden:
#
#   LOOP=pingpong   forward, then backward (default). No jump at all; fine
#                   for sitting and listening, odd if you talk or gesture.
#   LOOP=crossfade  the last XFADE seconds dissolve into the start. Plays
#                   forward only, but if you moved you ghost for a moment.
#   LOOP=none       plain loop; jumps at the seam.
#
# Knobs: START / DURATION (seconds; trim the recording), LOOP, XFADE (default
# 1), OUT_WIDTH / OUT_HEIGHT, FPS, CRF.

set -euo pipefail

if [ $# -lt 1 ]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
IN="$1"
OUT="${2:-$HERE/fallback.mp4}"
LOOP="${LOOP:-pingpong}"
XFADE="${XFADE:-1}"
START="${START:-0}"
DURATION="${DURATION:-}"
OUT_WIDTH="${OUT_WIDTH:-640}"
OUT_HEIGHT="${OUT_HEIGHT:-360}"
FPS="${FPS:-30}"
CRF="${CRF:-18}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Trim and crop/scale to the live stream's size and rate. Kept
#    near-lossless so step 2 is the only real encode.
trim=(-ss "$START")
[ -n "$DURATION" ] && trim+=(-t "$DURATION")
ffmpeg -hide_banner -loglevel error -y "${trim[@]}" -i "$IN" -an \
  -vf "scale=${OUT_WIDTH}:${OUT_HEIGHT}:force_original_aspect_ratio=increase,crop=${OUT_WIDTH}:${OUT_HEIGHT},fps=${FPS},setsar=1,format=yuv420p" \
  -c:v libx264 -preset veryfast -crf 4 "$TMP/norm.mkv"

LEN="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/norm.mkv")"
echo "Normalized: ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS}, ${LEN}s; loop: $LOOP"

# 2. Build the loop.
case "$LOOP" in
  pingpong)
    # The backward half drops its first frame so the turnaround doesn't hold
    # a frame twice. reverse buffers the whole clip in memory: keep it short.
    graph="split[f][r];[r]reverse,trim=start_frame=1,setpts=PTS-STARTPTS[b];[f][b]concat=n=2:v=1:a=0"
    ;;
  crossfade)
    # Play from XFADE to the end, dissolving the last XFADE seconds into the
    # first XFADE: the clip then ends exactly where it starts.
    if awk "BEGIN { exit !($LEN < 3 * $XFADE) }"; then
      echo "Recording too short for a ${XFADE}s crossfade." >&2; exit 1
    fi
    offset="$(awk "BEGIN { printf \"%.6f\", $LEN - 2 * $XFADE }")"
    graph="split[v1][v2];[v1]trim=start=${XFADE},setpts=PTS-STARTPTS[body];[v2]trim=end=${XFADE},setpts=PTS-STARTPTS[head];
           [body][head]xfade=transition=fade:duration=${XFADE}:offset=${offset}"
    ;;
  none)
    graph="null"
    ;;
  *)
    echo "LOOP must be pingpong, crossfade or none" >&2; exit 1
    ;;
esac

# 3. Encode with a keyframe per second so looping (a seek to 0) is cheap.
ffmpeg -hide_banner -loglevel error -y -i "$TMP/norm.mkv" -filter_complex "$graph" \
  -c:v libx264 -preset slow -crf "$CRF" -profile:v main -bf 0 -g "$FPS" -pix_fmt yuv420p \
  -an -map_metadata -1 -movflags +faststart "$OUT"

echo "Wrote $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s per loop)"
echo "Preview the loop: ffplay -loop 0 \"$OUT\""
