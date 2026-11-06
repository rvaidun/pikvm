#!/bin/bash
# Builds dwc2_wakeup.ko (USB remote wakeup for the dwc2 gadget, see
# dwc2_wakeup.c) for the running kernel and installs it to
# /lib/modules/<kver>/updates/.
#
# dwc2 is built into the kernel and its struct lives in a private header
# (drivers/usb/dwc2/core.h) that the headers package doesn't ship, so fetch
# core.h and hw.h from kernel.org's stable tree at the upstream version the
# running kernel is based on, as usb_f_uvc/build.sh does. The module refuses
# to load if the layout doesn't match. Rerun after a kernel upgrade
# (install.sh does).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
[ -d "$KDIR" ] || { echo "No kernel headers at $KDIR" >&2; exit 1; }

if [ -r /proc/version_signature ]; then
  UPSTREAM="$(awk '{print $NF}' /proc/version_signature)"
else
  UPSTREAM="$(grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$KVER")"
fi
TAG="v$(sed -E 's/^([0-9]+\.[0-9]+)\.0$/\1/' <<<"$UPSTREAM")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/usb/dwc2"
echo "Fetching dwc2 headers for $TAG"
for f in core.h hw.h; do
  curl -sSf "$BASE/$f?h=$TAG" -o "$WORK/$f"
done
cp "$HERE/dwc2_wakeup.c" "$WORK/"
echo 'obj-m := dwc2_wakeup.o' > "$WORK/Kbuild"

make -C "$KDIR" M="$WORK" modules
install -D -m 0644 "$WORK/dwc2_wakeup.ko" "/lib/modules/$KVER/updates/dwc2_wakeup.ko"
depmod -a "$KVER"
echo "Installed dwc2_wakeup for $KVER"
