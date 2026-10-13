#!/bin/bash
# Runs the uvc-gadget daemon: reads frames from /dev/video10 (v4l2loopback)
# and submits them to the UVC gadget's /dev/video0 endpoint, which the USB
# host sees as a webcam.
set -euo pipefail

# Wait for both devices (gadget video0 and loopback video10) to appear.
for i in $(seq 1 30); do
  [ -e /dev/video0 ] && [ -e /dev/video10 ] && break
  sleep 1
done

exec /usr/local/bin/uvc-gadget \
  -u /dev/video0 \
  -d /dev/video10 \
  -f 1 \
  -r 0 \
  -n 3
