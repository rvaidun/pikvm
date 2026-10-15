#!/bin/bash
# Runs the uvc-gadget daemon: reads MJPEG frames from the v4l2loopback
# device (kept fed by receiver.py) and submits them to the gadget's UVC
# function, which the target PC sees as a webcam. uvc-gadget resolves the
# gadget-side /dev/videoN from the configfs function name itself.
#
# This must stay running: the kernel's UVC function keeps the whole
# composite gadget (keyboard and mouse included) disconnected from the host
# until uvc-gadget has opened it.
set -euo pipefail

LOOPBACK="${LOOPBACK:-/dev/video50}"
UVC_FUNCTION="${UVC_FUNCTION:-brikvm/functions/uvc.usb0}"

# v4l2loopback runs with exclusive_caps=1, so it only advertises CAPTURE
# once receiver.py has opened it for writing. uvc-gadget refuses a source
# that isn't a capture device, so wait for that.
until v4l2-ctl -d "$LOOPBACK" --info 2>/dev/null | grep -q 'Video Capture'; do
  sleep 1
done

exec /usr/local/bin/uvc-gadget -d "$LOOPBACK" "$UVC_FUNCTION"
