#!/bin/bash
# HDMI -> CSI (TC358743) -> ustreamer MJPEG on :8080, which the web UI embeds.
#
# The TC358743 has no EDID of its own, so until one is loaded the target PC
# sees no monitor and sends nothing. edid/1080p50.hex prefers 1920x1080@50,
# the most the Pi 4's 2-lane CSI-2 link can carry in UYVY (1080p60 needs 3
# lanes), with 1280x720@60 as a fallback.
set -euo pipefail

EDID="${EDID:-/opt/kvm/edid/1080p50.hex}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
QUALITY="${QUALITY:-80}"

# unicam's video node number depends on probe order, so find it by name.
DEVICE=""
for i in $(seq 1 30); do
  for v in /sys/class/video4linux/video*; do
    if [ "$(cat "$v/name" 2>/dev/null)" = "unicam-image" ]; then
      DEVICE="/dev/$(basename "$v")"
      break 2
    fi
  done
  sleep 1
done
if [ -z "$DEVICE" ]; then
  echo "ERROR: no unicam capture device. Check dtoverlay=tc358743 in config.txt." >&2
  exit 1
fi

# Clearing the EDID drops hot-plug and loading it raises it again, so the
# source sees a monitor unplug and replug, re-reads the EDID and picks a mode.
# Reloading the same EDID alone is too brief a blip for Windows to notice
# after it has given up on the output, so a restart of this service doubles
# as "re-detect the display".
v4l2-ctl -d "$DEVICE" --clear-edid=pad=0
sleep 2
v4l2-ctl -d "$DEVICE" --set-edid=pad=0,file="$EDID",format=hex
echo "EDID loaded on $DEVICE; streaming on http://${LISTEN_HOST}:${LISTEN_PORT}/stream"

# --dv-timings follows resolution changes on the HDMI side; --persistent
# keeps serving a NO SIGNAL frame instead of exiting when the source sleeps.
# m2m-image uses the Pi's hardware JPEG encoder (bcm2835-codec).
exec ustreamer \
  --device="$DEVICE" \
  --persistent \
  --dv-timings \
  --format=uyvy \
  --encoder=m2m-image \
  --workers=3 \
  --buffers=4 \
  --quality="$QUALITY" \
  --drop-same-frames=30 \
  --host="$LISTEN_HOST" \
  --port="$LISTEN_PORT"
