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
# obvious: 640x360 (cropped to 16:9), 30 fps, no metadata (QuickTime records
# the Mac's make, model and dates). The recording's audio is kept (48 kHz
# stereo AAC) for forward.sh's clip audio (m); AUDIO=none drops it. The
# audio is cut and looped with the picture, and crossfades where it
# dissolves. forward.sh plays it on a loop, so the loop seam is hidden:
#
#   LOOP=auto       (default) finds the start and end SEARCH seconds where
#                   the picture is closest, moving the same way (so your
#                   head ends where it started), cuts the loop there and
#                   dissolves over XFADE seconds. Plays forward only; the
#                   loop is a little shorter than the recording.
#   LOOP=pingpong   forward, then backward. No jump at all; fine for
#                   sitting and listening, odd if you talk or gesture.
#   LOOP=crossfade  the last XFADE seconds dissolve into the start. Plays
#                   forward only, but if you moved you ghost for a moment.
#   LOOP=none       plain loop; jumps at the seam.
#
# Knobs: START / DURATION (seconds; trim the recording), LOOP, XFADE (default
# 1, auto: 0.5), SEARCH (auto: seconds at each end to search, default 1/4 of
# the recording up to 8), OUT_WIDTH / OUT_HEIGHT, FPS, CRF, AUDIO=none,
# ABITRATE (default 160k).

set -euo pipefail

if [ $# -lt 1 ]; then
  awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
IN="$1"
OUT="${2:-$HERE/fallback.mp4}"
LOOP="${LOOP:-auto}"
if [ "$LOOP" = auto ]; then XFADE="${XFADE:-0.5}"; else XFADE="${XFADE:-1}"; fi
SEARCH="${SEARCH:-}"
START="${START:-0}"
DURATION="${DURATION:-}"
OUT_WIDTH="${OUT_WIDTH:-640}"
OUT_HEIGHT="${OUT_HEIGHT:-360}"
FPS="${FPS:-30}"
CRF="${CRF:-18}"
AUDIO="${AUDIO:-keep}"
ABITRATE="${ABITRATE:-160k}"

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

# 1a. The audio, beside the video as a WAV, padded or cut to the video's
#     exact length so every later step can cut both at the same times.
HAS_AUDIO=0
if [ "$AUDIO" != none ] && ffprobe -v error -select_streams a:0 -show_entries \
     stream=codec_type -of csv=p=0 "$IN" | grep -q audio; then
  HAS_AUDIO=1
  ffmpeg -hide_banner -loglevel error -y "${trim[@]}" -i "$IN" -vn \
    -af "aresample=48000:async=1,apad,atrim=end=${LEN},asetpts=PTS-STARTPTS" \
    -ac 2 -c:a pcm_s16le "$TMP/norm.wav"
fi
sec() { awk "BEGIN { printf \"%.6f\", $1 / $FPS }"; }   # frames -> seconds
echo "Normalized: ${OUT_WIDTH}x${OUT_HEIGHT}@${FPS}, ${LEN}s; loop: $LOOP"

# 1b. auto: pick the loop's start frame A (near the beginning) and end frame
#     B (near the end) that look most alike, then crossfade [B, B+XFADE]
#     into [A, A+XFADE] -- the same dissolve as LOOP=crossfade, but between
#     two moments where you are already in the same pose. Frames are compared
#     as 32x18 grayscale thumbnails; a pair scores the mean pixel difference
#     at A/B plus every frame through the dissolve (so the motion matches,
#     not just one still), and the lowest score wins.
if [ "$LOOP" = auto ]; then
  # A = first frame kept, END = one past the last (B plus the dissolve).
  read -r A END SCORE STEP SECS < <(
    ffmpeg -hide_banner -loglevel error -i "$TMP/norm.mkv" \
      -vf "scale=32:18:flags=area,format=gray" -f rawvideo - |
    python3 -c '
import sys
from operator import sub
fps, xfade, search = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
raw = sys.stdin.buffer.read()
px = 32 * 18
fr = [raw[i:i + px] for i in range(0, len(raw) - px + 1, px)]
n = len(fr)
x = max(1, round(xfade * fps))
win = round(float(search) * fps) if search else min(round(8 * fps), n // 4)
if n < 2 * win + x + fps:
    sys.exit("recording too short for LOOP=auto; try SEARCH smaller")
diff = lambda a, b: sum(map(abs, map(sub, fr[a], fr[b]))) / px
# Every head frame against every tail frame, once (numpy if it is there).
hs = range(0, win + x)
ts = range(n - x - 1 - win, n)
try:
    import numpy as np
    H = np.frombuffer(b"".join(fr[i] for i in hs), np.uint8).reshape(len(hs), px).astype(np.int16)
    T = np.frombuffer(b"".join(fr[j] for j in ts), np.uint8).reshape(len(ts), px).astype(np.int16)
    M = np.abs(H[:, None, :] - T[None, :, :]).mean(axis=2).tolist()
except ImportError:
    M = [[diff(i, j) for j in ts] for i in hs]
# Compare every 3rd frame through the dissolve: enough to catch motion.
taps = sorted(set(range(0, x + 1, 3)) | {x})
b0 = ts[0]
best = min((sum(M[a + t][b - b0 + t] for t in taps) / len(taps), a, b)
           for a in range(win) for b in range(b0, b0 + win))
step = sorted(diff(i, i + 1) for i in range(n - 1))[n // 2]
print(best[1], best[2] + x, "%.2f" % best[0], "%.2f" % step, "%.2f" % ((best[2] - best[1]) / fps))
' "$FPS" "$XFADE" "$SEARCH"
  )
  [ -n "${END:-}" ] || { echo "Loop search failed." >&2; exit 1; }
  echo "Auto loop: ${SECS}s from frame $A; seam difference $SCORE (a normal frame-to-frame change is $STEP)"
  # Keep [A, B + XFADE] and let the crossfade branch below loop it.
  ffmpeg -hide_banner -loglevel error -y -i "$TMP/norm.mkv" \
    -vf "trim=start_frame=${A}:end_frame=${END},setpts=PTS-STARTPTS" \
    -c:v libx264 -preset veryfast -crf 4 "$TMP/cut.mkv"
  mv "$TMP/cut.mkv" "$TMP/norm.mkv"
  if [ "$HAS_AUDIO" = 1 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$TMP/norm.wav" \
      -af "atrim=start=$(sec "$A"):end=$(sec "$END"),asetpts=PTS-STARTPTS" \
      -c:a pcm_s16le "$TMP/cut.wav"
    mv "$TMP/cut.wav" "$TMP/norm.wav"
  fi
  LOOP=crossfade
fi

# 2. Build the loop.
case "$LOOP" in
  pingpong)
    # The backward half drops its first frame so the turnaround doesn't hold
    # a frame twice. reverse buffers the whole clip in memory: keep it short.
    graph="split[f][r];[r]reverse,trim=start_frame=1,setpts=PTS-STARTPTS[b];[f][b]concat=n=2:v=1:a=0"
    agraph="asplit[f][r];[r]areverse,atrim=start=$(sec 1),asetpts=PTS-STARTPTS[b];[f][b]concat=n=2:v=0:a=1"
    ;;
  crossfade)
    # Play from XFADE to the end, dissolving the last XFADE seconds into the
    # first XFADE: the clip then ends exactly where it starts. Done in whole
    # frames with blend: dissolve frame t mixes tail frame t into head frame
    # t at (t+1)/(X+1), so it leaves the frame before the tail and lands on
    # the frame after the head, which is where the loop restarts. (xfade
    # didn't ramp: its frames were off from both inputs, jumping in and out.)
    X="$(awk "BEGIN { print int($XFADE * $FPS + 0.5) }")"
    FR="$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$TMP/norm.mkv")"
    T0=$((FR - X))
    if [ "$X" -lt 1 ] || [ "$T0" -le "$X" ]; then
      echo "Recording too short for a ${XFADE}s crossfade." >&2; exit 1
    fi
    graph="split=3[a][b][c];
           [a]trim=start_frame=${X}:end_frame=${T0},setpts=PTS-STARTPTS[mid];
           [b]trim=start_frame=${T0}:end_frame=${FR},setpts=PTS-STARTPTS[tail];
           [c]trim=end_frame=${X},setpts=PTS-STARTPTS[head];
           [tail][head]blend=all_expr='A+(B-A)*(N+1)/(${X}+1)+0.5'[dis];
           [mid][dis]concat=n=2:v=1:a=0"
    # The audio follows: the tail fades out over the head fading in.
    agraph="asplit=3[a][b][c];
            [a]atrim=start=$(sec "$X"):end=$(sec "$T0"),asetpts=PTS-STARTPTS[mid];
            [b]atrim=start=$(sec "$T0"),asetpts=PTS-STARTPTS,afade=t=out:d=$(sec "$X")[tail];
            [c]atrim=end=$(sec "$X"),asetpts=PTS-STARTPTS,afade=t=in:d=$(sec "$X")[head];
            [tail][head]amix=inputs=2:normalize=0[dis];
            [mid][dis]concat=n=2:v=0:a=1"
    ;;
  none)
    graph="null"
    agraph="anull"
    ;;
  *)
    echo "LOOP must be auto, pingpong, crossfade or none" >&2; exit 1
    ;;
esac

# 3. Encode with a keyframe per second so looping (a seek to 0) is cheap.
#    The graphs' unlabeled inputs take the video and the WAV's audio.
ain=(); aout=(-an)
if [ "$HAS_AUDIO" = 1 ]; then
  ain=(-i "$TMP/norm.wav"); graph="${graph};${agraph}"
  aout=(-c:a aac -b:a "$ABITRATE")
fi
ffmpeg -hide_banner -loglevel error -y -i "$TMP/norm.mkv" ${ain[@]+"${ain[@]}"} -filter_complex "$graph" \
  -c:v libx264 -preset slow -crf "$CRF" -profile:v main -bf 0 -g "$FPS" -pix_fmt yuv420p \
  "${aout[@]}" -map_metadata -1 -movflags +faststart "$OUT"

[ "$HAS_AUDIO" = 1 ] || echo "(no audio: forward.sh's clip audio will be silent for this clip)"
echo "Wrote $OUT ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")s per loop)"
echo "Preview the loop: ffplay -loop 0 \"$OUT\""
