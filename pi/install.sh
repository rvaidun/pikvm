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
#   3. Copies bridge.py + setup-gadget.sh to /opt/kvm/.
#   4. Installs the udev rule, both systemd units, and enables them.
#   5. Installs aiohttp + pyserial deps (apt pkg).

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

# --- 3. Deploy code ----------------------------------------------------------
install -d -o root -g root -m 0755 /opt/kvm
install -o root -g root -m 0755 "$SRC_DIR/setup-gadget.sh" /opt/kvm/setup-gadget.sh
install -o root -g root -m 0755 "$SRC_DIR/bridge.py"        /opt/kvm/bridge.py
install -d -o root -g root -m 0755 /opt/kvm/static
install -o root -g root -m 0644 "$SRC_DIR/static/index.html" /opt/kvm/static/index.html

# Optional override file for VID/PID/strings.
if [ ! -f /etc/kvm-gadget.env ]; then
  cat > /etc/kvm-gadget.env <<'EOF'
# Override the spoofed USB identity. Leave commented to use the default
# Logitech USB Receiver (046D:C534).
# VENDOR_ID=0x413C
# PRODUCT_ID=0x2113
# MANUFACTURER=Dell
# PRODUCT=Dell USB Entry Keyboard
EOF
fi

# --- 4. udev + systemd -------------------------------------------------------
install -o root -g root -m 0644 "$SRC_DIR/99-kvm-hidg.rules" /etc/udev/rules.d/99-kvm-hidg.rules
udevadm control --reload-rules

install -o root -g root -m 0644 "$SRC_DIR/kvm-gadget.service" /etc/systemd/system/kvm-gadget.service
install -o root -g root -m 0644 "$SRC_DIR/kvm-bridge.service" /etc/systemd/system/kvm-bridge.service

# Patch the bridge service to use whichever user is installing (default rahul).
sed -i "s/^User=.*/User=${BRIDGE_USER}/" /etc/systemd/system/kvm-bridge.service

systemctl daemon-reload
systemctl enable kvm-gadget.service kvm-bridge.service

# --- 5. Python deps ----------------------------------------------------------
apt-get update
apt-get install -y python3-aiohttp

cat <<EOF

Install complete. Reboot to pick up the dwc2 overlay:

  sudo reboot

After reboot, verify:
  ls -l /dev/hidg0 /dev/hidg1
  systemctl status kvm-gadget kvm-bridge
  journalctl -fu kvm-bridge

Then open http://<pi-ip>:8082/ in a browser and click the video.
EOF
