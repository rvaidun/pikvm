#!/bin/bash
# Creates a composite USB HID gadget on the Pi 4 that enumerates on the
# target PC as a plug-and-play keyboard + mouse. By default it masquerades
# as a Logitech USB Receiver (VID 046D:C534) so Windows sees a boring,
# driverless input device.
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
VENDOR_ID="${VENDOR_ID:-0x046D}"           # Logitech
PRODUCT_ID="${PRODUCT_ID:-0xC534}"         # USB Receiver (keyboard + mouse)
MANUFACTURER="${MANUFACTURER:-Logitech}"
PRODUCT="${PRODUCT:-USB Receiver}"
# Use the Pi's own CPU serial so the target OS treats us as the same
# device across reboots (realistic). Fall back to a stable fake if unreadable.
SERIAL="${SERIAL:-$(awk -F: '/Serial/ {gsub(/ /,"",$2); print $2}' /proc/cpuinfo 2>/dev/null || true)}"
SERIAL="${SERIAL:-00000000DEADBEEF}"

modprobe libcomposite

# --- Teardown previous instance (idempotent) --------------------------------
if [ -d "$GADGET_DIR" ]; then
  echo "" > "${GADGET_DIR}/UDC" 2>/dev/null || true
  rm -f "${GADGET_DIR}/configs/c.1/hid.usb0" 2>/dev/null || true
  rm -f "${GADGET_DIR}/configs/c.1/hid.usb1" 2>/dev/null || true
  rmdir "${GADGET_DIR}/configs/c.1/strings/0x409" 2>/dev/null || true
  rmdir "${GADGET_DIR}/configs/c.1" 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/hid.usb0" 2>/dev/null || true
  rmdir "${GADGET_DIR}/functions/hid.usb1" 2>/dev/null || true
  rmdir "${GADGET_DIR}/strings/0x409" 2>/dev/null || true
  rmdir "${GADGET_DIR}" 2>/dev/null || true
fi

cd /sys/kernel/config/usb_gadget
mkdir -p "$GADGET_NAME" && cd "$GADGET_NAME"

# --- Device descriptor -------------------------------------------------------
echo "$VENDOR_ID"  > idVendor
echo "$PRODUCT_ID" > idProduct
echo 0x0111        > bcdDevice      # device v1.11
echo 0x0200        > bcdUSB         # USB 2.0
# Composite devices: 0x00 in device class lets each interface declare its own.
echo 0x00 > bDeviceClass
echo 0x00 > bDeviceSubClass
echo 0x00 > bDeviceProtocol

mkdir -p strings/0x409
echo "$SERIAL"       > strings/0x409/serialnumber
echo "$MANUFACTURER" > strings/0x409/manufacturer
echo "$PRODUCT"      > strings/0x409/product

# --- Configuration -----------------------------------------------------------
mkdir -p configs/c.1/strings/0x409
echo "HID composite" > configs/c.1/strings/0x409/configuration
echo 250             > configs/c.1/MaxPower       # mA; bus-powered receiver
echo 0xA0            > configs/c.1/bmAttributes   # bus-powered, remote wakeup

# --- HID function: boot keyboard (8-byte report) ----------------------------
# Report: [modifiers][reserved][key1..key6]
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol         # 1 = keyboard
echo 1 > functions/hid.usb0/subclass         # 1 = boot interface
echo 8 > functions/hid.usb0/report_length
echo -ne '\x05\x01\x09\x06\xA1\x01\x05\x07\x19\xE0\x29\xE7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x01\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x01\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xC0' \
  > functions/hid.usb0/report_desc

# --- HID function: mouse (4-byte report: buttons, dx, dy, wheel) ------------
mkdir -p functions/hid.usb1
echo 0 > functions/hid.usb1/protocol         # 0 = none (report protocol only)
echo 0 > functions/hid.usb1/subclass
echo 4 > functions/hid.usb1/report_length
echo -ne '\x05\x01\x09\x02\xA1\x01\x09\x01\xA1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x03\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7F\x75\x08\x95\x03\x81\x06\xC0\xC0' \
  > functions/hid.usb1/report_desc

ln -s functions/hid.usb0 configs/c.1/
ln -s functions/hid.usb1 configs/c.1/

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
echo "Devices: /dev/hidg0 (keyboard), /dev/hidg1 (mouse)"
