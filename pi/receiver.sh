#!/bin/bash
# Receive the Mac's MPEG-TS stream over UDP, demux into:
#   video -> MJPEG -> /dev/video50 (v4l2loopback)   [uvc-handler forwards to USB]
#   audio -> ALSA hw:UAC2Gadget playback            [UAC2 gadget presents as mic to host]
#
# Video and audio run in separate ffmpeg processes: the UAC2 gadget's ALSA
# device only drains while the host has the mic open, and a blocked ALSA
# write would otherwise freeze the video output too. The main process hands
# raw PCM to the audio sink over localhost UDP, which never blocks.
#
# The loopback is fed MJPEG because that's the only format the UVC gadget
# advertises; uvc-gadget passes the host's requested format straight
# through to the source device.
#
# Started by kvm-receiver.service. The UDP read times out when the Mac stops
# streaming so ffmpeg exits, systemd restarts us, and the next Mac
# connection starts from a clean decoder state.
set -euo pipefail

PORT="${PORT:-1234}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
MJPEG_QUALITY="${MJPEG_QUALITY:-5}"     # ffmpeg -q:v, 2 (best) .. 31 (worst)
LOOPBACK="${LOOPBACK:-/dev/video50}"
AUDIO_PORT="${AUDIO_PORT:-1236}"        # localhost-only hop to the audio sink
TIMEOUT_US="${TIMEOUT_US:-5000000}"

# The UAC2 ALSA card number depends on module load order; look it up at runtime.
UAC2_CARD=$(aplay -L 2>/dev/null | awk '/^hw:CARD=UAC2Gadget/{print; exit}' || true)
UAC2_CARD="${UAC2_CARD:-hw:UAC2Gadget}"

echo "Receiver listening on udp://0.0.0.0:${PORT}"
echo "Video sink: $LOOPBACK (MJPEG ${WIDTH}x${HEIGHT}@${FPS})   Audio sink: $UAC2_CARD"

ffmpeg -hide_banner -loglevel warning -nostdin \
  -f s16le -ar 48000 -ac 2 \
  -i "udp://127.0.0.1:${AUDIO_PORT}?overrun_nonfatal=1&fifo_size=100000" \
  -f alsa "$UAC2_CARD" &
AUDIO_PID=$!
trap 'kill "$AUDIO_PID" 2>/dev/null || true' EXIT

ffmpeg -hide_banner -loglevel info -nostdin \
  -fflags +nobuffer+discardcorrupt -flags low_delay \
  -i "udp://0.0.0.0:${PORT}?overrun_nonfatal=1&fifo_size=1000000&timeout=${TIMEOUT_US}" \
  -map 0:v -vf "scale=${WIDTH}:${HEIGHT},fps=${FPS},format=yuvj422p" \
    -c:v mjpeg -q:v "$MJPEG_QUALITY" -f v4l2 "$LOOPBACK" \
  -map 0:a -c:a pcm_s16le -ar 48000 -ac 2 \
    -f s16le "udp://127.0.0.1:${AUDIO_PORT}?pkt_size=1024"
