#!/bin/bash
# Switch the camera between the stock and patched UVC gadget drivers, e.g. to
# show what the patch fixes. The target PC sees a USB replug (keyboard and
# mouse included). Not persistent: a reboot goes back to bulk (modprobe.d).
#
#   uvc-mode.sh          show the current mode
#   uvc-mode.sh stock    the kernel's own usb_f_uvc, isochronous: dwc2's
#                        missed slots splice half-sent frames into the next
#                        one (RGB garbage)
#   uvc-mode.sh isoc     patched module, still isochronous: misses drop their
#                        frame cleanly, so frames arrive cut off (top of the
#                        image, then green)
#   uvc-mode.sh bulk     patched module over bulk: no misses (the default)
set -euo pipefail

P=/sys/module/usb_f_uvc/parameters
current() {
  if [ ! -d /sys/module/usb_f_uvc ]; then echo "not loaded"
  elif [ ! -e "$P/bulk" ]; then echo "stock"
  elif [ "$(cat "$P/bulk")" = "Y" ]; then echo "bulk"
  else echo "isoc"
  fi
}

MODE="${1:-}"
if [ -z "$MODE" ]; then
  echo "camera mode: $(current)"
  exit 0
fi
case "$MODE" in stock|isoc|bulk) ;; *) echo "usage: $0 [stock|isoc|bulk]" >&2; exit 2 ;; esac
[ "$EUID" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

STOCK=$(ls /lib/modules/"$(uname -r)"/kernel/drivers/usb/gadget/function/usb_f_uvc.ko* | head -1)
if [ "$MODE" != stock ] && [ ! -e /lib/modules/"$(uname -r)"/updates/usb_f_uvc.ko ]; then
  echo "No patched module for $(uname -r); run install.sh first." >&2
  exit 1
fi

# receiver.py holds the camera's video node, so it has to let go before the
# gadget can be torn down and the module unloaded.
systemctl stop kvm-receiver kvm-bridge
/opt/kvm/setup-gadget.sh teardown
if [ -d /sys/module/usb_f_uvc ]; then
  rmmod usb_f_uvc
fi
case "$MODE" in
  stock) # By path, since modprobe would pick updates/. insmod doesn't load
         # dependencies, so do that first.
         modprobe -a $(modinfo -F depends "$STOCK" | tr , ' ')
         insmod "$STOCK" ;;
  isoc)  modprobe usb_f_uvc bulk=0 ;;  # command-line options override modprobe.d
  bulk)  modprobe usb_f_uvc bulk=1 ;;
esac
systemctl restart kvm-gadget
systemctl start kvm-bridge kvm-receiver
echo "camera mode: $(current)"
