#!/bin/bash
# One-shot installer for the Pi 4 half of briKVM.
#
# Prerequisites:
#   - Raspberry Pi 4 running Raspberry Pi OS (Bookworm 64-bit or newer).
#   - PiKVM USB-C splitter wired so the Pi's USB-C carries data to the
#     target PC and the splitter's barrel jack supplies power.
#   - An HDMI capture source (CSI bridge recommended, USB dongle OK).
#
# What it does:
#   1. Enables the dwc2 USB OTG controller in peripheral mode.
#   2. Autoloads dwc2 + libcomposite at boot.
#   3. Installs ffmpeg + v4l2loopback + build deps.
#   4. Builds and installs uvc-gadget from freedesktop.org.
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
if ! grep -qE '^dtoverlay=dwc2' "$CONFIG_TXT"; then
  echo "Adding dtoverlay=dwc2,dr_mode=peripheral to $CONFIG_TXT"
  printf '\n# briKVM: USB-C in gadget mode via PiKVM splitter\ndtoverlay=dwc2,dr_mode=peripheral\n' >> "$CONFIG_TXT"
else
  echo "dwc2 overlay already present in $CONFIG_TXT (leaving alone)"
fi

# --- 2. Module autoload ------------------------------------------------------
cat > /etc/modules-load.d/pikvm.conf <<'EOF'
dwc2
libcomposite
EOF

# --- 3. apt deps (ffmpeg, v4l2loopback, build tooling for uvc-gadget) -------
apt-get update
apt-get install -y \
  python3-aiohttp \
  ffmpeg \
  v4l-utils v4l2loopback-dkms \
  libasound2-dev \
  build-essential git pkg-config meson ninja-build

# --- 4. Build uvc-gadget from source (not packaged in Debian) ---------------
if [ ! -x /usr/local/bin/uvc-gadget ]; then
  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR" EXIT
  git clone --depth 1 https://gitlab.freedesktop.org/camera/uvc-gadget.git "$TMPDIR/uvc-gadget"
  cd "$TMPDIR/uvc-gadget"
  meson setup build
  meson compile -C build
  install -m 0755 build/uvc-gadget /usr/local/bin/uvc-gadget
  cd - >/dev/null
fi
echo "uvc-gadget: $(/usr/local/bin/uvc-gadget --version 2>/dev/null || echo installed)"

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

Install complete. Reboot to pick up the dwc2 overlay:

  sudo reboot

After reboot, verify:
  ls -l /dev/hidg0 /dev/hidg1 /dev/video0 /dev/video10
  aplay -L | grep UAC2Gadget
  systemctl status kvm-gadget kvm-bridge kvm-uvc kvm-receiver
  journalctl -fu kvm-bridge

Then:
  1. Open http://<pi-ip>:8082/ in a browser and click the video.
  2. From the Mac, point the forwarder at this Pi:
       cd .../pikvm/macforward/mac && ./forward.sh <pi-ip>
     Windows should enumerate a camera + microphone on the composite device.
EOF
