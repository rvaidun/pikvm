#!/bin/bash
# Builds the kernel's UVC gadget function (usb_f_uvc) with dwc2-bulk.patch
# applied, for the running kernel, and installs it to
# /lib/modules/<kver>/updates/ where modprobe prefers it over the stock one.
#
# Why: the Pi 4's dwc2 controller has no descriptor DMA, so isochronous IN
# must be re-armed from an interrupt before every service interval; on a
# busy Pi ~12% of packets miss, and stock f_uvc turns each miss into a
# corrupt frame. The patch:
#   - treats dwc2's -ENODATA "missed isoc slot" like -EXDEV, so a miss drops
#     its frame cleanly instead of splicing it into the next one;
#   - adds `bulk=1` (and `bulk_payload=`), which streams over a bulk endpoint
#     instead. Bulk has no deadlines, so nothing is lost.
#
# The sources are fetched from kernel.org's stable tree at the upstream
# version the running kernel is based on; the patch is written against
# 7.0.x. Rerun after a kernel upgrade (install.sh does).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
[ -d "$KDIR" ] || { echo "No kernel headers at $KDIR" >&2; exit 1; }

# Ubuntu records the upstream version in /proc/version_signature
# ("Ubuntu 7.0.0-1020.20-raspi 7.0.14"); elsewhere uname -r starts with it
# ("6.12.25+rpt-rpi-v8"). kernel.org tags x.y.0 as vx.y.
if [ -r /proc/version_signature ]; then
  UPSTREAM="$(awk '{print $NF}' /proc/version_signature)"
else
  UPSTREAM="$(grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$KVER")"
fi
TAG="v$(sed -E 's/^([0-9]+\.[0-9]+)\.0$/\1/' <<<"$UPSTREAM")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/usb/gadget/function"
echo "Fetching usb_f_uvc sources for $TAG"
for f in f_uvc.c f_uvc.h u_uvc.h uvc.h uvc_configfs.c uvc_configfs.h \
         uvc_queue.c uvc_queue.h uvc_v4l2.c uvc_v4l2.h uvc_video.c uvc_video.h; do
  curl -sSf "$BASE/$f?h=$TAG" -o "$WORK/$f"
done
# Tracepoints only exist in newer kernels.
for f in uvc_trace.c uvc_trace.h; do
  curl -sf "$BASE/$f?h=$TAG" -o "$WORK/$f" || rm -f "$WORK/$f"
done

patch -d "$WORK" -p1 --forward < "$HERE/dwc2-bulk.patch"

cat > "$WORK/Kbuild" <<'EOF'
obj-m := usb_f_uvc.o
usb_f_uvc-y := f_uvc.o uvc_queue.o uvc_v4l2.o uvc_video.o uvc_configfs.o
ifneq ($(CONFIG_TRACING),)
ifneq ($(wildcard $(src)/uvc_trace.c),)
CFLAGS_uvc_trace.o := -I$(src)
usb_f_uvc-y += uvc_trace.o
endif
endif
EOF

make -C "$KDIR" M="$WORK" modules
install -D -m 0644 "$WORK/usb_f_uvc.ko" "/lib/modules/$KVER/updates/usb_f_uvc.ko"
depmod -a "$KVER"
echo "Installed patched usb_f_uvc for $KVER ($(modinfo -n usb_f_uvc))"
