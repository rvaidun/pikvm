#!/bin/bash
# One-shot installer for rahKVM MacForward on Raspberry Pi Zero 2 W.
#
# Prereqs:
#   - Fresh install of Raspberry Pi OS Lite (64-bit, Bookworm or newer)
#   - Pi Zero connected to a monitor+keyboard OR SSH-reachable
#   - Internet access
#
# What it does:
#   1. Enables USB OTG (dwc2) + loads modules at boot
#   2. Installs apt deps (ffmpeg, build tools, v4l2loopback)
#   3. Builds and installs uvc-gadget from source
#   4. Copies scripts to /opt/macforward
#   5. Installs + enables systemd units
#   6. Reboots (so dwc2 + v4l2loopback take effect)
#
# Run via: sudo bash install.sh
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> 1. Enable USB OTG"
CONFIG=/boot/firmware/config.txt
if ! grep -q "^dtoverlay=dwc2" "$CONFIG"; then
  echo "" >> "$CONFIG"
  echo "# rahKVM MacForward" >> "$CONFIG"
  echo "dtoverlay=dwc2" >> "$CONFIG"
fi

CMDLINE=/boot/firmware/cmdline.txt
if ! grep -q "modules-load=.*dwc2" "$CMDLINE"; then
  sed -i 's|$| modules-load=dwc2|' "$CMDLINE"
fi

echo "==> 2. Install packages"
apt-get update
apt-get install -y \
  ffmpeg \
  build-essential git pkg-config \
  v4l-utils v4l2loopback-dkms \
  libasound2-dev

echo "==> 3. Build uvc-gadget"
if [ ! -x /usr/local/bin/uvc-gadget ]; then
  cd /tmp
  rm -rf uvc-gadget
  git clone https://gitlab.freedesktop.org/camera/uvc-gadget.git
  cd uvc-gadget
  # fdo repo uses meson
  if command -v meson >/dev/null; then
    meson setup build
    meson compile -C build
    install -m0755 build/uvc-gadget /usr/local/bin/
  else
    apt-get install -y meson ninja-build
    meson setup build
    meson compile -C build
    install -m0755 build/uvc-gadget /usr/local/bin/
  fi
fi
echo "uvc-gadget installed: $(which uvc-gadget)"

echo "==> 4. Install scripts to /opt/macforward"
install -d /opt/macforward
install -m0755 "$HERE/setup-gadget.sh" /opt/macforward/setup-gadget.sh
install -m0755 "$HERE/receiver.sh"      /opt/macforward/receiver.sh
install -m0755 "$HERE/uvc-handler.sh"   /opt/macforward/uvc-handler.sh

echo "==> 5. Install systemd units"
install -m0644 "$HERE/systemd/macforward-gadget.service"   /etc/systemd/system/
install -m0644 "$HERE/systemd/macforward-uvc.service"      /etc/systemd/system/
install -m0644 "$HERE/systemd/macforward-receiver.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable macforward-gadget.service
systemctl enable macforward-uvc.service
systemctl enable macforward-receiver.service

echo
echo "==> 6. Install complete."
echo "    Reboot now (sudo reboot), then plug the Pi Zero's USB (data) port"
echo "    into the Windows target. Windows should see a 'rahKVM MacForward'"
echo "    camera + microphone appear."
echo
echo "    From the Mac, run:   ./mac/forward.sh <pi-zero-host-or-ip>"
