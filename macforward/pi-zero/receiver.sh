#!/bin/bash
# Receive MPEG-TS stream from Mac over UDP, split into video + audio sinks:
#   video -> /dev/video10 (v4l2loopback)   [uvc-gadget forwards this to USB]
#   audio -> ALSA hw:UAC2Gadget capture    [UAC2 USB gadget presents this as mic to host]
#
# Started by macforward-receiver.service. Will exit cleanly if the stream drops
# so systemd restarts it, waiting for the next Mac connection.
set -euo pipefail

PORT="${PORT:-1234}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

# Find the UAC2 gadget ALSA card dynamically; its number depends on module load order.
UAC2_CARD=$(aplay -L 2>/dev/null | awk '/^hw:CARD=UAC2Gadget/{print; exit}' || true)
if [ -z "$UAC2_CARD" ]; then
  UAC2_CARD="hw:UAC2Gadget"
fi
echo "Receiver listening on udp://0.0.0.0:${PORT}"
echo "Video sink: /dev/video10   Audio sink: $UAC2_CARD"

exec ffmpeg -hide_banner -loglevel info \
  -fflags +nobuffer+discardcorrupt -flags low_delay \
  -i "udp://0.0.0.0:${PORT}?overrun_nonfatal=1&fifo_size=1000000" \
  -map 0:v -s "${WIDTH}x${HEIGHT}" -r "$FPS" -pix_fmt yuyv422 -f v4l2 /dev/video10 \
  -map 0:a -ar 48000 -ac 2 -f alsa "$UAC2_CARD"
