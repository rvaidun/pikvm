#!/bin/bash
# Receive the Mac's MPEG-TS stream over UDP, demux into:
#   video -> /dev/video10 (v4l2loopback)   [uvc-handler forwards to USB]
#   audio -> ALSA hw:UAC2Gadget capture    [UAC2 gadget presents as mic to host]
#
# Started by kvm-receiver.service; exits cleanly on stream drop so systemd
# restarts it and the next Mac connection just works.
set -euo pipefail

PORT="${PORT:-1234}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

# The UAC2 ALSA card number depends on module load order; look it up at runtime.
UAC2_CARD=$(aplay -L 2>/dev/null | awk '/^hw:CARD=UAC2Gadget/{print; exit}' || true)
UAC2_CARD="${UAC2_CARD:-hw:UAC2Gadget}"

echo "Receiver listening on udp://0.0.0.0:${PORT}"
echo "Video sink: /dev/video10   Audio sink: $UAC2_CARD"

exec ffmpeg -hide_banner -loglevel info \
  -fflags +nobuffer+discardcorrupt -flags low_delay \
  -i "udp://0.0.0.0:${PORT}?overrun_nonfatal=1&fifo_size=1000000" \
  -map 0:v -s "${WIDTH}x${HEIGHT}" -r "$FPS" -pix_fmt yuyv422 -f v4l2 /dev/video10 \
  -map 0:a -ar 48000 -ac 2 -f alsa "$UAC2_CARD"
