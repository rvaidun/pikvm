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
#   1. Enables the dwc2 USB OTG controller in peripheral mode.
#   2. Autoloads dwc2 + libcomposite at boot; pins v4l2loopback to /dev/video50.
#   3. Installs ffmpeg + v4l2loopback (DKMS, needs kernel headers) + build deps.
#   4. Builds and installs uvc-gadget (+ libuvcgadget) from freedesktop.org.
#   5. Copies bridge.py, setup-gadget.sh, receiver.sh, uvc-handler.sh to /opt/kvm/.
#   6. Installs udev rule and all four systemd units, enables them.
#   7. Installs aiohttp (apt pkg) for the WebSocket bridge.

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

# /dev/video10-31 belong to the Pi 4's hardware codec/ISP, so park the
# loopback at /dev/video50 no matter who loads the module.
cat > /etc/modprobe.d/kvm-v4l2loopback.conf <<'EOF'
options v4l2loopback video_nr=50 card_label=briKVM-Loopback exclusive_caps=1
EOF

# --- 3. apt deps (ffmpeg, v4l2loopback, build tooling for uvc-gadget) -------
# v4l2loopback is built by DKMS, so the running kernel's headers must exist.
# Ubuntu raspi: linux-headers-$(uname -r). Raspberry Pi OS: linux-headers-rpi-v8.
HEADERS_PKG="linux-headers-$(uname -r)"
apt-cache show "$HEADERS_PKG" >/dev/null 2>&1 || HEADERS_PKG="linux-headers-rpi-v8"
apt-get update
apt-get install -y \
  "$HEADERS_PKG" \
  python3-aiohttp \
  ustreamer edid-decode \
  ffmpeg \
  v4l-utils v4l2loopback-dkms \
  libasound2-dev \
  build-essential git pkg-config meson ninja-build

# --- 4. Build uvc-gadget from source (not packaged in Debian/Ubuntu) -------
# `meson install` puts the binary in /usr/local/bin and its shared
# libuvcgadget in /usr/local/lib, hence the ldconfig.
if [ ! -x /usr/local/bin/uvc-gadget ]; then
  BUILD_DIR=$(mktemp -d)
  trap "rm -rf $BUILD_DIR" EXIT
  git clone --depth 1 https://gitlab.freedesktop.org/camera/uvc-gadget.git "$BUILD_DIR/uvc-gadget"
  meson setup --prefix=/usr/local "$BUILD_DIR/uvc-gadget/build" "$BUILD_DIR/uvc-gadget"
  meson install -C "$BUILD_DIR/uvc-gadget/build"
  ldconfig
fi
echo "uvc-gadget installed at /usr/local/bin/uvc-gadget"

# Fail loudly now rather than at first boot if the DKMS build didn't work.
modprobe v4l2loopback || echo "WARNING: v4l2loopback failed to load; check 'dkms status'" >&2

# --- 5. Deploy code ---------------------------------------------------------
install -d -o root -g root -m 0755 /opt/kvm
install -o root -g root -m 0755 "$SRC_DIR/setup-gadget.sh" /opt/kvm/setup-gadget.sh
install -o root -g root -m 0755 "$SRC_DIR/bridge.py"       /opt/kvm/bridge.py
install -o root -g root -m 0755 "$SRC_DIR/receiver.sh"     /opt/kvm/receiver.sh
install -o root -g root -m 0755 "$SRC_DIR/uvc-handler.sh"  /opt/kvm/uvc-handler.sh
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
install -o root -g root -m 0644 "$SRC_DIR/kvm-uvc.service"      /etc/systemd/system/kvm-uvc.service
install -o root -g root -m 0644 "$SRC_DIR/kvm-receiver.service" /etc/systemd/system/kvm-receiver.service

# Patch the bridge service to use whichever user is installing (default rahul).
sed -i "s/^User=.*/User=${BRIDGE_USER}/" /etc/systemd/system/kvm-bridge.service

systemctl daemon-reload
systemctl enable \
  kvm-gadget.service \
  kvm-bridge.service \
  kvm-uvc.service \
  kvm-receiver.service

cat <<EOF

Install complete. Reboot to pick up the dwc2 peripheral overlay:

  sudo reboot

After reboot, verify:
  ls -l /dev/hidg0 /dev/hidg1 /dev/video50
  cat /sys/class/udc/*/state     # "configured" once the target enumerates the Pi
  aplay -L | grep UAC2Gadget
  systemctl status kvm-gadget kvm-bridge kvm-uvc kvm-receiver
  journalctl -fu kvm-bridge

Then:
  1. Open http://<pi-ip>:8082/ in a browser and click the video.
  2. From the Mac, point the forwarder at this Pi:
       cd .../pikvm/macforward/mac && ./forward.sh <pi-ip>
     The target should see a "Logitech MeetUp" camera + microphone.
EOF
