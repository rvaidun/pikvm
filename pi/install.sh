#!/bin/bash
# One-shot installer for the Pi 4 half of briKVM.
#
# Prerequisites:
#   - Raspberry Pi 4 running 64-bit Raspberry Pi OS (Bookworm+) or Ubuntu
#     Server for Raspberry Pi (tested on Ubuntu 26.04, kernel 7.0 raspi).
#   - PiKVM USB-C splitter wired so the Pi's USB-C carries data to the
#     target PC and the splitter's barrel jack supplies power.
#
# What it does:
#   1. Enables the dwc2 USB OTG controller in peripheral mode and the
#      TC358743 HDMI-to-CSI overlay.
#   2. Autoloads dwc2 + libcomposite at boot; loads usb_f_uvc in bulk mode.
#   3. Installs ffmpeg, ustreamer, aiohttp, kernel headers + build tools.
#   4. Builds the patched usb_f_uvc (kernel/usb_f_uvc/) for the running kernel.
#   5. Copies bridge.py, receiver.py, the shell helpers and the EDID to /opt/kvm/.
#   6. Installs the udev rule and the four systemd units, enables them, and
#      removes units from older versions (kvm-uvc).

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo." >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_USER="${BRIDGE_USER:-rahul}"

CONFIG_TXT="/boot/firmware/config.txt"
if [ ! -f "$CONFIG_TXT" ]; then
  CONFIG_TXT="/boot/config.txt"       # older Raspberry Pi OS layout
fi

# --- 1. dwc2 in peripheral mode ---------------------------------------------
# A bare `dtoverlay=dwc2` (what Ubuntu's raspi config.txt ships) means OTG,
# which can leave the Pi 4's USB-C port acting as a host. Force peripheral.
# The [cm4] section's `dtoverlay=dwc2,dr_mode=host` doesn't match and is left alone.
if grep -qE '^dtoverlay=dwc2,dr_mode=peripheral' "$CONFIG_TXT"; then
  echo "dwc2 peripheral overlay already present in $CONFIG_TXT"
elif grep -qE '^dtoverlay=dwc2$' "$CONFIG_TXT"; then
  echo "Switching bare dtoverlay=dwc2 to dr_mode=peripheral in $CONFIG_TXT"
  sed -i 's/^dtoverlay=dwc2$/dtoverlay=dwc2,dr_mode=peripheral/' "$CONFIG_TXT"
else
  echo "Adding dtoverlay=dwc2,dr_mode=peripheral to $CONFIG_TXT"
  printf '\n[all]\n# briKVM: USB-C in gadget mode via PiKVM splitter\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$CONFIG_TXT"
fi

# --- 1b. HDMI-to-CSI bridge (TC358743) --------------------------------------
# Not auto-detected by camera_auto_detect (no EEPROM), so load it explicitly.
if ! grep -qE '^dtoverlay=tc358743' "$CONFIG_TXT"; then
  echo "Adding dtoverlay=tc358743 to $CONFIG_TXT"
  printf '\n[all]\n# briKVM: HDMI-to-CSI bridge\ndtoverlay=tc358743\n' >> "$CONFIG_TXT"
fi

# --- 2. Module autoload ------------------------------------------------------
cat > /etc/modules-load.d/pikvm.conf <<'EOF'
dwc2
libcomposite
EOF

# Stream the camera over bulk, not isochronous (see kernel/usb_f_uvc/build.sh).
# The stock module ignores the unknown option, and receiver.py falls back to
# isochronous when the patched module isn't loaded.
cat > /etc/modprobe.d/kvm-uvc.conf <<'EOF'
options usb_f_uvc bulk=1
EOF
rm -f /etc/modprobe.d/kvm-v4l2loopback.conf   # from versions that used v4l2loopback

# --- 3. apt deps ---------------------------------------------------------------
# The patched usb_f_uvc is built against the running kernel's headers.
# Ubuntu raspi: linux-headers-$(uname -r). Raspberry Pi OS: linux-headers-rpi-v8.
HEADERS_PKG="linux-headers-$(uname -r)"
apt-cache show "$HEADERS_PKG" >/dev/null 2>&1 || HEADERS_PKG="linux-headers-rpi-v8"
apt-get update
apt-get install -y \
  "$HEADERS_PKG" \
  python3-aiohttp \
  ustreamer edid-decode \
  ffmpeg \
  v4l-utils \
  build-essential curl patch

# --- 4. Patched UVC gadget module ------------------------------------------
# Without it the camera still works over isochronous, but on a Pi 4 the
# picture is corrupted by dropped packets, so say so loudly.
if ! bash "$SRC_DIR/kernel/usb_f_uvc/build.sh"; then
  echo "WARNING: building the patched usb_f_uvc failed; the camera will use the" >&2
  echo "         stock isochronous module and its frames will be corrupted." >&2
fi

# --- 5. Deploy code ---------------------------------------------------------
install -d -o root -g root -m 0755 /opt/kvm
install -o root -g root -m 0755 "$SRC_DIR/setup-gadget.sh" /opt/kvm/setup-gadget.sh
install -o root -g root -m 0755 "$SRC_DIR/bridge.py"       /opt/kvm/bridge.py
install -o root -g root -m 0755 "$SRC_DIR/receiver.py"     /opt/kvm/receiver.py
install -o root -g root -m 0755 "$SRC_DIR/hdmi-capture.sh" /opt/kvm/hdmi-capture.sh
rm -f /opt/kvm/receiver.sh   # replaced by receiver.py
install -d -o root -g root -m 0755 /opt/kvm/edid
install -o root -g root -m 0644 "$SRC_DIR/edid/1080p50.hex" /opt/kvm/edid/1080p50.hex
rm -f /opt/kvm/uvc-handler.sh   # replaced by receiver.py's UVC driver
install -d -o root -g root -m 0755 /opt/kvm/static
install -o root -g root -m 0644 "$SRC_DIR/static/index.html" /opt/kvm/static/index.html

# Optional override file for VID/PID/strings.
if [ ! -f /etc/kvm-gadget.env ]; then
  cat > /etc/kvm-gadget.env <<'EOF'
# Override the spoofed USB identity. Default is Logitech MeetUp
# (046D:086B) — a real conferencing device with camera + mic + HID remote.
# Alternatives:
#   VENDOR_ID=0x046D
#   PRODUCT_ID=0x0A87
#   MANUFACTURER=Logitech
#   PRODUCT=GROUP Video Conferencing
EOF
fi

if [ ! -f /etc/kvm-receiver.env ]; then
  cat > /etc/kvm-receiver.env <<'EOF'
# Override the Mac->Pi stream parameters. Must match the Mac's forward.sh.
# PORT=1234
# WIDTH=1280
# HEIGHT=720
# FPS=30
EOF
fi

# --- 6. udev + systemd ------------------------------------------------------
install -o root -g root -m 0644 "$SRC_DIR/99-kvm-hidg.rules" /etc/udev/rules.d/99-kvm-hidg.rules
udevadm control --reload-rules

install -o root -g root -m 0644 "$SRC_DIR/kvm-gadget.service"   /etc/systemd/system/kvm-gadget.service
install -o root -g root -m 0644 "$SRC_DIR/kvm-bridge.service"   /etc/systemd/system/kvm-bridge.service
install -o root -g root -m 0644 "$SRC_DIR/kvm-receiver.service" /etc/systemd/system/kvm-receiver.service
install -o root -g root -m 0644 "$SRC_DIR/kvm-ustreamer.service" /etc/systemd/system/kvm-ustreamer.service

# Patch the bridge service to use whichever user is installing (default rahul).
sed -i "s/^User=.*/User=${BRIDGE_USER}/" /etc/systemd/system/kvm-bridge.service

# kvm-uvc ran the freedesktop uvc-gadget daemon; receiver.py is the UVC
# driver now and the two would fight over the gadget's video node.
if [ -f /etc/systemd/system/kvm-uvc.service ]; then
  systemctl disable --now kvm-uvc.service || true
  rm -f /etc/systemd/system/kvm-uvc.service
fi

systemctl daemon-reload
systemctl enable \
  kvm-gadget.service \
  kvm-bridge.service \
  kvm-receiver.service \
  kvm-ustreamer.service

cat <<EOF

Install complete. Reboot to pick up the overlays and the patched module:

  sudo reboot

After reboot, verify:
  ls -l /dev/hidg0 /dev/hidg1
  cat /sys/class/udc/*/state                 # "configured" once the target enumerates the Pi
  cat /sys/module/usb_f_uvc/parameters/bulk  # Y = patched module, bulk camera
  cat /proc/asound/cards | grep UAC2Gadget
  systemctl status kvm-gadget kvm-bridge kvm-receiver kvm-ustreamer
  journalctl -fu kvm-receiver

Then:
  1. Open http://<pi-ip>:8082/ in a browser and click the video.
  2. From the Mac, point the forwarder at this Pi:
       cd .../pikvm/macforward/mac && ./forward.sh <pi-ip>
     The target should see a "Logitech MeetUp" camera + microphone.
EOF
