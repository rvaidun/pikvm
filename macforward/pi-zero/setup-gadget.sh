#!/bin/bash
# Creates a composite USB gadget on the Pi Zero that enumerates on the
# USB host (Windows PC) as:
#   - UVC video camera    (1280x720 MJPG @ 30fps)
#   - UAC2 microphone     (48kHz stereo 16-bit)
#
# Runs at boot via macforward-gadget.service. Idempotent.
set -euo pipefail

GADGET_NAME="macforward"
GADGET_DIR="/sys/kernel/config/usb_gadget/${GADGET_NAME}"

modprobe libcomposite
modprobe v4l2loopback video_nr=10 card_label="MacForwardLoopback" exclusive_caps=1 || true

# Tear down any previous instance (idempotent).
if [ -d "$GADGET_DIR" ]; then
  echo "" > "${GADGET_DIR}/UDC" 2>/dev/null || true
  rm -f "${GADGET_DIR}/configs/c.1/uvc.usb0" || true
  rm -f "${GADGET_DIR}/configs/c.1/uac2.usb0" || true
  rm -f "${GADGET_DIR}/configs/c.1/hid.usb0" || true
  rm -f "${GADGET_DIR}/configs/c.1/hid.usb1" || true
  rmdir "${GADGET_DIR}/configs/c.1/strings/0x409" 2>/dev/null || true
  rmdir "${GADGET_DIR}/configs/c.1" 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/uvc.usb0"/streaming/mjpeg/m/*  2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/uvc.usb0"/streaming/mjpeg/m    2>/dev/null || true
  find "${GADGET_DIR}/functions/uvc.usb0" -type l -delete       2>/dev/null || true
  find "${GADGET_DIR}/functions/uvc.usb0" -depth -type d -empty -delete 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/uac2.usb0" 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/hid.usb0" 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/hid.usb1" 2>/dev/null || true
  rmdir "${GADGET_DIR}/strings/0x409" 2>/dev/null || true
  rmdir "${GADGET_DIR}" 2>/dev/null || true
fi

cd /sys/kernel/config/usb_gadget
mkdir -p "$GADGET_NAME" && cd "$GADGET_NAME"

# --- Device descriptor ---
echo 0x046D > idVendor      # Logitech, same identity as pi/setup-gadget.sh
echo 0x086B > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB
mkdir -p strings/0x409
echo "8A3F1C2D"          > strings/0x409/serialnumber
echo "Logitech"          > strings/0x409/manufacturer
echo "MeetUp"            > strings/0x409/product

# --- Configuration ---
mkdir -p configs/c.1
echo 500 > configs/c.1/MaxPower

# --- UVC function (1280x720 MJPG @ 30fps) ---
mkdir -p functions/uvc.usb0/control/header/h
cd functions/uvc.usb0/control
ln -s header/h class/fs
ln -s header/h class/ss
cd -

mkdir -p functions/uvc.usb0/streaming/mjpeg/m/720p
cd functions/uvc.usb0/streaming/mjpeg/m/720p
echo 1280     > wWidth
echo 720      > wHeight
echo 333333   > dwDefaultFrameInterval
echo 333333   > dwFrameInterval
echo $((1280*720*2))  > dwMinBitRate
echo $((1280*720*2))  > dwMaxBitRate
echo $((1280*720*2))  > dwMaxVideoFrameBufferSize
cd -

mkdir -p functions/uvc.usb0/streaming/header/h
cd functions/uvc.usb0/streaming/header/h
ln -s ../../mjpeg/m .
cd -
cd functions/uvc.usb0/streaming/class/fs
ln -s ../../header/h .
cd -
cd functions/uvc.usb0/streaming/class/hs
ln -s ../../header/h .
cd -
cd functions/uvc.usb0/streaming/class/ss
ln -s ../../header/h .
cd -

# --- UAC2 function (48kHz stereo, capture-only direction = Windows mic) ---
mkdir -p functions/uac2.usb0
echo 2     > functions/uac2.usb0/c_chmask      # stereo
echo 48000 > functions/uac2.usb0/c_srate       # 48kHz
echo 2     > functions/uac2.usb0/c_ssize       # 16-bit
echo 0     > functions/uac2.usb0/p_chmask      # no playback (host->Pi)

# --- HID function: boot keyboard (8-byte report) ---
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol        # 1 = keyboard
echo 1 > functions/hid.usb0/subclass        # 1 = boot interface
echo 8 > functions/hid.usb0/report_length
# Standard HID boot keyboard report descriptor (63 bytes).
echo -ne '\x05\x01\x09\x06\xA1\x01\x05\x07\x19\xE0\x29\xE7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x01\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x01\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xC0' \
  > functions/hid.usb0/report_desc

# --- HID function: mouse (4-byte report: buttons, dx, dy, wheel) ---
mkdir -p functions/hid.usb1
echo 0 > functions/hid.usb1/protocol        # 0 = none (report protocol only)
echo 0 > functions/hid.usb1/subclass
echo 4 > functions/hid.usb1/report_length
echo -ne '\x05\x01\x09\x02\xA1\x01\x09\x01\xA1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x03\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7F\x75\x08\x95\x03\x81\x06\xC0\xC0' \
  > functions/hid.usb1/report_desc

# --- Link functions to configuration ---
ln -s functions/uvc.usb0  configs/c.1/
ln -s functions/uac2.usb0 configs/c.1/
ln -s functions/hid.usb0  configs/c.1/
ln -s functions/hid.usb1  configs/c.1/

# --- Activate on first available UDC ---
UDC=$(ls /sys/class/udc | head -1)
if [ -z "$UDC" ]; then
  echo "ERROR: no UDC available. Check dtoverlay=dwc2 in config.txt and that you're on the USB (not PWR) port." >&2
  exit 1
fi
echo "$UDC" > UDC
echo "Gadget bound to $UDC"
echo "UVC device: /dev/video0 (gadget side) + /dev/video10 (loopback source)"
echo "UAC2 device: look at 'aplay -L' for hw:UAC2Gadget*"
