#!/bin/bash
# Creates a composite USB gadget on the Pi 4 that presents to the target PC as:
#   - HID keyboard (/dev/hidg0)
#   - HID mouse    (/dev/hidg1)
#   - UVC camera   (fed by uvc-gadget from v4l2loopback /dev/video50)
#   - UAC2 mic     (ALSA hw:UAC2Gadget capture, fed by the receiver's ffmpeg)
#
# Needs:
#   /boot/firmware/config.txt   dtoverlay=dwc2,dr_mode=peripheral
#   /etc/modules-load.d/pikvm.conf   dwc2 \n libcomposite
#   PiKVM USB-C splitter so the Pi's USB-C port carries data to the target
#   and power comes from the splitter's barrel jack.
#
# Runs at boot via kvm-gadget.service. Idempotent.
set -euo pipefail

GADGET_NAME="brikvm"
GADGET_DIR="/sys/kernel/config/usb_gadget/${GADGET_NAME}"

# --- Spoofed device identity (override via /etc/kvm-gadget.env) -------------
# Default is Logitech MeetUp (046D:086B) — a real conferencing device that
# natively has camera + mic + HID remote on one USB cable, so our composite
# matches its shape. Alternatives:
#   VENDOR_ID=0x046D PRODUCT_ID=0x0A87  MANUFACTURER=Logitech  PRODUCT="GROUP Video Conferencing"
#   VENDOR_ID=0x0B0E PRODUCT_ID=0x0431  MANUFACTURER=Jabra     PRODUCT="PanaCast 50"
VENDOR_ID="${VENDOR_ID:-0x046D}"
PRODUCT_ID="${PRODUCT_ID:-0x086B}"
MANUFACTURER="${MANUFACTURER:-Logitech}"
PRODUCT="${PRODUCT:-MeetUp}"
# Windows names the camera and mic from each function's own interface
# string, not the device's product string, so these need spoofing too.
CAMERA_NAME="${CAMERA_NAME:-$MANUFACTURER $PRODUCT}"
MIC_NAME="${MIC_NAME:-$MANUFACTURER $PRODUCT}"
# Use the Pi's own CPU serial so the target OS treats us as the same
# device across reboots (realistic). Fall back to a stable fake if unreadable.
SERIAL="${SERIAL:-$(awk -F: '/Serial/ {gsub(/ /,"",$2); print $2}' /proc/cpuinfo 2>/dev/null || true)}"
SERIAL="${SERIAL:-00000000DEADBEEF}"

modprobe libcomposite
# v4l2loopback is the staging buffer between the Mac-stream receiver (ffmpeg)
# and the UVC gadget. exclusive_caps=1 makes it look like a plain capture
# device to uvc-gadget once ffmpeg is writing. video_nr=50 because the Pi 4's
# hardware codec/ISP already own /dev/video10-31. Options also live in
# /etc/modprobe.d/kvm-v4l2loopback.conf so any loader gets the same node.
modprobe v4l2loopback video_nr=50 card_label="briKVM-Loopback" exclusive_caps=1 || true

# --- Teardown previous instance (idempotent) --------------------------------
# ConfigFS only lets you remove things in reverse creation order: symlinks
# first, then user-created dirs leaf-first. Default groups (class/fs etc.)
# disappear with their parent.
if [ -d "$GADGET_DIR" ]; then
  (
    cd "$GADGET_DIR"
    echo "" > UDC 2>/dev/null || true
    rm -f configs/c.1/hid.usb0 configs/c.1/hid.usb1 configs/c.1/uvc.usb0 configs/c.1/uac2.usb0
    rmdir configs/c.1/strings/0x409 configs/c.1 2>/dev/null || true
    U=functions/uvc.usb0
    if [ -d "$U" ]; then
      rm -f "$U"/control/class/fs/h "$U"/control/class/ss/h
      rm -f "$U"/streaming/class/fs/h "$U"/streaming/class/hs/h "$U"/streaming/class/ss/h
      rm -f "$U"/streaming/header/h/m
      rmdir "$U"/streaming/header/h "$U"/streaming/mjpeg/m/720p "$U"/streaming/mjpeg/m 2>/dev/null || true
      rmdir "$U"/control/header/h "$U" 2>/dev/null || true
    fi
    rmdir functions/hid.usb0 functions/hid.usb1 functions/uac2.usb0 2>/dev/null || true
    rmdir strings/0x409 2>/dev/null || true
  )
  rmdir "$GADGET_DIR"
fi

cd /sys/kernel/config/usb_gadget
mkdir -p "$GADGET_NAME" && cd "$GADGET_NAME"

# --- Device descriptor -------------------------------------------------------
echo "$VENDOR_ID"  > idVendor
echo "$PRODUCT_ID" > idProduct
echo 0x0111        > bcdDevice      # device v1.11
echo 0x0200        > bcdUSB         # USB 2.0
# Miscellaneous / Interface Association Descriptor class. UVC and UAC2 group
# their interfaces with IADs, and Windows' usbccgp only honors IADs when the
# device declares 0xEF/0x02/0x01; with 0x00 the camera and mic split apart.
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

mkdir -p strings/0x409
echo "$SERIAL"       > strings/0x409/serialnumber
echo "$MANUFACTURER" > strings/0x409/manufacturer
echo "$PRODUCT"      > strings/0x409/product

# --- Configuration -----------------------------------------------------------
mkdir -p configs/c.1/strings/0x409
echo "briKVM composite" > configs/c.1/strings/0x409/configuration
echo 500                > configs/c.1/MaxPower       # mA; UVC+UAC2 want headroom
echo 0xA0               > configs/c.1/bmAttributes   # bus-powered, remote wakeup

# --- HID function: boot keyboard (8-byte report) ----------------------------
# Report: [modifiers][reserved][key1..key6]
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol         # 1 = keyboard
echo 1 > functions/hid.usb0/subclass         # 1 = boot interface
echo 8 > functions/hid.usb0/report_length
# No interrupt OUT endpoint: with one, f_hid stalls SET_REPORT on ep0, and
# Windows' keyboard driver (which sets the lock LEDs that way at start) then
# never polls the keyboard. LED reports still arrive, readable from /dev/hidg0.
echo 1 > functions/hid.usb0/no_out_endpoint
echo -ne '\x05\x01\x09\x06\xA1\x01\x05\x07\x19\xE0\x29\xE7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x01\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x01\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xC0' \
  > functions/hid.usb0/report_desc

# --- HID function: mouse (4-byte report: buttons, dx, dy, wheel) ------------
mkdir -p functions/hid.usb1
echo 0 > functions/hid.usb1/protocol         # 0 = none (report protocol only)
echo 0 > functions/hid.usb1/subclass
echo 4 > functions/hid.usb1/report_length
echo 1 > functions/hid.usb1/no_out_endpoint  # mice have no output reports
echo -ne '\x05\x01\x09\x02\xA1\x01\x09\x01\xA1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x03\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7F\x75\x08\x95\x03\x81\x06\xC0\xC0' \
  > functions/hid.usb1/report_desc

# --- UVC function (1280x720 MJPG @ 30fps) -----------------------------------
mkdir -p functions/uvc.usb0/control/header/h
echo "$CAMERA_NAME" > functions/uvc.usb0/function_name
cd functions/uvc.usb0/control
ln -s header/h class/fs
ln -s header/h class/ss
cd -

mkdir -p functions/uvc.usb0/streaming/mjpeg/m/720p
cd functions/uvc.usb0/streaming/mjpeg/m/720p
echo 1280                 > wWidth
echo 720                  > wHeight
echo 333333               > dwDefaultFrameInterval   # 100ns units -> 30fps
echo 333333               > dwFrameInterval
echo $((1280 * 720 * 2))  > dwMinBitRate
echo $((1280 * 720 * 2))  > dwMaxBitRate
echo $((1280 * 720 * 2))  > dwMaxVideoFrameBufferSize
cd -

mkdir -p functions/uvc.usb0/streaming/header/h
cd functions/uvc.usb0/streaming/header/h
ln -s ../../mjpeg/m .
cd -
for speed in fs hs ss; do
  cd functions/uvc.usb0/streaming/class/$speed
  ln -s ../../header/h .
  cd -
done

# --- UAC2 function (mic to host = capture direction) ------------------------
mkdir -p functions/uac2.usb0
echo 2     > functions/uac2.usb0/c_chmask    # stereo capture
echo 48000 > functions/uac2.usb0/c_srate
echo 2     > functions/uac2.usb0/c_ssize     # 16-bit
echo 0     > functions/uac2.usb0/p_chmask    # no playback (host->Pi)
echo "$MIC_NAME" > functions/uac2.usb0/function_name

# --- Wire functions into the configuration ---------------------------------
# Link order sets interface numbers. UVC must come first (interfaces 0/1):
# the kernel renumbers UVC requests to 0/1 for userspace, and uvc-gadget
# matches them against the real configfs numbers, so anywhere else it
# ignores every probe request and the host can never start the camera.
ln -s functions/uvc.usb0  configs/c.1/
ln -s functions/hid.usb0  configs/c.1/
ln -s functions/hid.usb1  configs/c.1/
ln -s functions/uac2.usb0 configs/c.1/

# --- Bind to the Pi 4 USB-C UDC ---------------------------------------------
UDC=$(ls /sys/class/udc | head -1)
if [ -z "$UDC" ]; then
  echo "ERROR: no UDC available. Check dtoverlay=dwc2,dr_mode=peripheral in" >&2
  echo "       /boot/firmware/config.txt and that the Pi's USB-C port is" >&2
  echo "       connected via the PiKVM splitter to the target PC." >&2
  exit 1
fi
echo "$UDC" > UDC
echo "briKVM gadget bound to $UDC as ${MANUFACTURER} ${PRODUCT} (${VENDOR_ID}:${PRODUCT_ID})"
echo "Devices: /dev/hidg0 (kbd), /dev/hidg1 (mouse), uvc.usb0 (camera),"
echo "         /dev/video50 (v4l2loopback source), hw:UAC2Gadget (mic)"
