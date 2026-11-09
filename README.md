# pikvm

DIY PI KVM heavily inspired by [https://pikvm.org/](https://pikvm.org/)

One USB-C cable from the Pi to the target PC carries a keyboard, a mouse, a webcam and a microphone, and an HDMI-to-CSI bridge captures the target's screen. You drive the target from a browser, and you can forward your Mac's webcam and mic so the target sees them as a regular USB  device.

## Hardware


I strongly recommend reading the [official PiKVM DIY guide](https://pikvm.org/diy/). This setup is largely based on that guide.

| Part | Notes |
|---|---|
| **PiKVM USB-C power/data splitter** | Plugs into the Pi's USB-C port. Power goes into one side, and data goes to the target PC through the other. <ul><li>[Official PiKVM USB Power/Data Splitter](https://www.pishop.us/product/pikvm-usb-power-data-splitter/)</li><li>[Generic Amazon alternative](https://www.amazon.com/dp/B0DNS52HXZ)</li></ul> |
| **Data-capable USB cable** | Connects the splitter's **USB/data** port to the target PC. Make sure the cable supports data transfer, not just charging. |
| **HDMI-to-CSI bridge** | Examples include the C779/B101 boards. Connects to the Pi's **CAMERA** connector using a ribbon cable. The target PC's HDMI output connects to the bridge's HDMI input. [Amazon link](https://www.amazon.com/dp/B08TR7R6RL). |
| **USB HDMI capture card (alternative)** | Instead of an HDMI-to-CSI bridge, you can use a [USB HDMI capture card](https://www.amazon.com/dp/B097QX7726). However, I found that the output in the web UI was fairly low resolution. This might have been because I used a cheap capture card. |

### Wiring

1. Seat the CSI ribbon from the bridge into the Pi's **CAMERA** port, with contacts facing the HDMI ports on the Pi 4.
2. Connect the target PC's HDMI out to the bridge's HDMI in.
3. Plug the splitter into the Pi's USB-C port.
4. Plug the power supply into the splitter's **PWR** port.
5. Run a data cable from the splitter's **USB/data** port to the target PC.

### Case

`case/kvm-case.scad` is a parametric OpenSCAD enclosure for the Pi 4 and the Waveshare HDMI-to-CSI adapter. `case/kvm-case-base.stl` and `case/kvm-case-lid.stl` are exported with the defaults. The adapter sits in a cradle behind the Pi's GPIO edge, with its HDMI input through the back wall. It needs no screws. The Pi sits on pegs through its mounting holes, and posts on the lid hold both boards down. Like the official Pi case, the lid clicks on and pulls off by hand: four springy clips have bumps that sit in shallow grooves inside the walls. To re-export:

```sh
openscad -D 'part="base"' -o case/kvm-case-base.stl case/kvm-case.scad
openscad -D 'part="lid"'  -o case/kvm-case-lid.stl  case/kvm-case.scad
```

## Pi setup
Assuming you have this repo cloned in your pi

```
sudo bash install.sh            # BRIDGE_USER=<you> sudo -E bash install.sh for a different user
sudo reboot
```

The installer is idempotent; re-run it any time. It:

1. Sets `dtoverlay=dwc2,dr_mode=peripheral` in `/boot/firmware/config.txt`, replacing the bare `dtoverlay=dwc2` (OTG) that Ubuntu ships.
2. Adds `dtoverlay=tc358743` for the HDMI-to-CSI bridge. It has no EEPROM, so camera auto-detect never finds it.
3. Autoloads `dwc2` and `libcomposite`, and sets `options usb_f_uvc bulk=1` in `/etc/modprobe.d/kvm-uvc.conf`.
4. Installs ffmpeg, ustreamer, the matching kernel headers and build tools.
5. Builds a patched `usb_f_uvc` kernel module for the running kernel (`pi/kernel/usb_f_uvc/build.sh`) and installs it to `/lib/modules/$(uname -r)/updates/`. See [Why a patched UVC module](#why-a-patched-uvc-module). **Re-run the installer after a kernel upgrade**, or the stock module comes back and the camera picture breaks up.
6. Copies the code to `/opt/kvm/`, then installs the udev rule and the four systemd units and enables them. It also removes `kvm-uvc` and the v4l2loopback config left by older versions.

### 4. Verify after the reboot

```sh
systemctl is-active kvm-gadget kvm-bridge kvm-receiver kvm-ustreamer   # all "active"
cat /sys/class/udc/*/state            # "configured" = the target has enumerated the Pi
cat /sys/class/udc/*/current_speed    # "high-speed"
cat /sys/module/usb_f_uvc/parameters/bulk   # "Y" = patched module, camera on bulk
cat /proc/asound/cards | grep UAC2Gadget    # the mic's ALSA side
ls -l /dev/hidg0 /dev/hidg1
curl -s localhost:8080/state          # ustreamer: "online": true and the HDMI resolution
```

On the target, Windows should chime and Device Manager should list a
**Logitech MeetUp** camera and microphone, plus a HID keyboard and mouse.

---

## Using it

### Control the target from a browser

Open **`http://<pi-ip>:8082/`**.

- The page shows the target's screen. It's ustreamer's MJPEG from `:8080/stream`.
- **Click the video** to capture keyboard and mouse. The mouse is relative and uses pointer lock.
- **Esc**, **Right ⌘**, or **⌘+⇧** releases capture. All keys are released on the target when you do.
- The **Ctrl+Alt+Del** button sends the combo, since your own OS would intercept it otherwise.
- Closing the tab also releases all keys and buttons, so nothing sticks down.

### Wake a sleeping target

When the target sleeps, the screen shows no signal. Move the mouse or press a
key on the page: the bridge notices the target has stopped polling and sends a
USB remote wakeup, as a real keyboard would. The first moves are dropped, and
the screen comes back a few seconds later. To do it by hand on the Pi:

```sh
echo 1 | sudo tee /sys/module/dwc2_wakeup/parameters/wake
cat /sys/module/dwc2_wakeup/parameters/state   # suspended=0 lx_state=L0 once it's awake
```

The write fails with "Operation already in progress" if the target is already
awake, and with "Connection timed out" if it didn't respond. That happens when
it's shut down or hibernating rather than asleep. The Pi 4's dwc2 driver can't
send a remote wakeup by itself, so `kernel/dwc2_wakeup/` adds one; see the
comment at the top of `dwc2_wakeup.c`.

### Forward the Mac's webcam and mic to the target

On the Mac (needs `brew install ffmpeg`):

```sh
cd ~/GitProjects/pikvm/macforward/mac
./forward.sh <pi-ip>              # e.g. ./forward.sh 192.168.1.8, Ctrl-C to stop
```

On the target, open the Camera app, or select **Logitech MeetUp** as the camera and mic
in Zoom or Teams. You'll see the Mac's camera within a second or two of
`forward.sh` starting. While the Mac isn't streaming, the camera shows black
and the mic is silent; the device stays connected either way.

Device indices default to `0:1` (MacBook Pro camera and mic). To list them:

```sh
ffmpeg -f avfoundation -list_devices true -i ""
VIDEO_IDX=0 AUDIO_IDX=0 ./forward.sh <pi-ip>
```

Other knobs: `WIDTH`/`HEIGHT` (capture mode), `OUT_WIDTH`/`OUT_HEIGHT` (sent
size, default 640×360), `FPS`, `VBITRATE`, `ABITRATE`, `PORT`. If you change the
port, set the same `PORT` in `/etc/kvm-receiver.env` on the Pi. The Pi pads or
scales whatever size arrives to the camera's 640×480 and 1280×720 frames.

#### Fallback video

`forward.sh` can switch the camera picture to a pre-recorded clip and back
while it runs. Record yourself with QuickTime (File → New Movie Recording,
using the same camera), then turn the recording into a clip once:

```sh
./make-fallback.sh ~/Downloads/sample.mov    # writes macforward/mac/fallback.mp4
./forward.sh 192.168.1.8
```

With `fallback.mp4` present, press **f** for the clip, **l** for the live
camera, **space** to toggle, and **q** to quit. `START=fallback` starts on the clip,
and `FALLBACK=<file>` uses a different one. The mic stays live the whole time.
Both sources go through the same ffmpeg and the same stream, so the switch
is instant and the Pi needs no changes: the target just sees one camera.

`make-fallback.sh` matches the clip to the live stream (640×360, 30 fps, no
audio, metadata stripped) and hides the loop seam. `LOOP=pingpong` (the
default) plays forward then backward, so there's no jump. That suits sitting
and listening; for talking or gestures, use `LOOP=crossfade`, which dissolves
the last second into the first. `START`/`DURATION` trim the recording.

---

## Services

| Unit | What it does | Port / device |
|---|---|---|
| `kvm-gadget` | `setup-gadget.sh`: builds the configfs composite gadget (HID kbd + mouse, UVC, UAC2) and binds it to the dwc2 UDC. | `/dev/hidg0`, `/dev/hidg1` |
| `kvm-bridge` | `bridge.py`: serves the web UI and turns WebSocket messages into HID reports. | TCP 8082 |
| `kvm-ustreamer` | `hdmi-capture.sh`: loads the EDID into the TC358743, then runs ustreamer with the Pi's hardware JPEG encoder. | TCP 8080 |
| `kvm-receiver` | `receiver.py`: the UVC camera driver. It answers the host's camera control requests, decodes the Mac's stream (on the Pi's hardware H.264 decoder) into YUY2 frames for the USB camera (black frames when idle), and sends PCM to the UAC2 mic. | UDP 1234 |

Logs: `journalctl -fu kvm-<name>`.

### Comparing the camera drivers

`uvc-mode.sh` swaps the UVC gadget module so you can see what the patch fixes
(the target sees a USB replug; a reboot goes back to `bulk`):

```sh
sudo /opt/kvm/uvc-mode.sh          # show the current mode
sudo /opt/kvm/uvc-mode.sh stock    # kernel's own module: RGB garbage
sudo /opt/kvm/uvc-mode.sh isoc     # patched, isochronous: frames cut off, green below
sudo /opt/kvm/uvc-mode.sh bulk     # patched, bulk: clean (the default)
```

### Configuration files

| File | Overrides |
|---|---|
| `/etc/kvm-gadget.env` | `VENDOR_ID`, `PRODUCT_ID`, `MANUFACTURER`, `PRODUCT`, `SERIAL` (USB identity); `CAMERA_NAME`, `MIC_NAME` (what Windows calls the camera and mic, default "Logitech MeetUp"); `UVC_MJPEG` (also offer MJPEG 720p30; set it in `kvm-receiver.env` too) |
| `/etc/kvm-receiver.env` | `PORT`, `UVC_MJPEG`, `MJPEG_QUALITY`, `H264_DECODER`, `UAC2_CARD`; `JITTER_MS` (how far the camera and mic run behind the Mac to keep the video smooth, default 500) |
| `/etc/kvm-ustreamer.env` | `EDID`, `LISTEN_HOST`, `LISTEN_PORT`, `QUALITY` |

Restart the relevant unit after editing. Changing the USB identity needs
`sudo systemctl restart kvm-gadget kvm-receiver`.

### Updating

```sh
cd ~/pikvm && git pull
sudo bash pi/install.sh
sudo systemctl stop kvm-receiver kvm-bridge
sudo systemctl restart kvm-gadget       # rebuilds the gadget; the target sees a replug
sudo systemctl start kvm-bridge kvm-receiver
sudo systemctl restart kvm-ustreamer
```

A reboot is only needed if `config.txt` changed, or if a new `usb_f_uvc` was
built while the old one was loaded (`modinfo -n usb_f_uvc` shows the file;
`lsmod | grep usb_f_uvc` shows it's in use). Rebooting is the easy way to
load the new module.

---

## Troubleshooting

**Target never chimes / `/sys/class/udc/*/state` says `not attached`**
1. `systemctl status kvm-receiver`: **receiver.py must be running.** The
   kernel's UVC function keeps the *whole* gadget, keyboard and mouse included,
   disconnected until a process subscribes to the camera's control events.
2. `grep fe980000 /proc/interrupts`: if the count stays at 0 while kvm-receiver
   is running, the target isn't on the bus at all. Suspect the cable first
   (charge-only cables are common), then the splitter port (it must be the
   data port, not PWR), then the target's USB port.
3. `dmesg | grep dwc2`: if you see `DWC OTG Controller ... new USB bus registered`,
   the controller came up as a *host*. Check that `config.txt` has
   `dtoverlay=dwc2,dr_mode=peripheral` and reboot.

**Web UI shows no video / ustreamer reports `online: false`**
- `journalctl -u kvm-ustreamer`. "No signal" usually means the target hasn't
  re-read the EDID or has turned the output off. `sudo systemctl restart
  kvm-ustreamer` clears and reloads the EDID, which looks like a monitor
  unplug and replug to the target. If `v4l2-ctl -d /dev/v4l-subdev0 --log-status`
  then shows `Cable detected (+5V power): yes` but `TMDS signal detected: no`,
  the Pi is fine and the target is the one not sending. Wake it, press
  **Win+P → Duplicate**, or use **Settings → Display → Detect**.
- `v4l2-ctl -d /dev/video0 --query-dv-timings` shows what the target is sending.
- The Pi 4's CSI port has 2 lanes, so the ceiling is **1080p50**. The shipped
  EDID (`pi/edid/1080p50.hex`) prefers 1920×1080@50 with 1280×720@60 as
  fallback. If the target forces 1080p60, the driver refuses the mode; set
  50 Hz or 720p on the target.
- `dmesg | grep tc358743` should show `tc358743 found`. If not, reseat the
  ribbon and check `dtoverlay=tc358743` in `config.txt`.
- Black bars on the sides mean the target is mirroring a non-16:9 laptop panel.
  Switch Windows to "Show only on 2" or "Extend" to get the full frame.

**Camera picture is corrupted (RGB blocks, the top of the frame then solid green)**
- `cat /sys/module/usb_f_uvc/parameters/bulk` must say `Y`. If the file is
  missing, the stock module is loaded, which streams isochronously and loses
  packets on a Pi 4 (see the design notes). Re-run `sudo bash pi/install.sh`
  (it rebuilds the module for the running kernel) and reboot.
- `journalctl -u kvm-receiver | grep "UVC gadget"` shows which mode receiver.py
  picked: `bulk, max payload 16384` is right.

**Camera app says "Something went wrong" with 0x80070428**
- That's Windows' Camera Frame Server service crashing, not the Pi. If the Pi
  is still sending video, the error is on the Windows side. In an admin
  PowerShell: `Restart-Service FrameServer -Force`, or reboot the target.

**Target sees the camera but it's black**
- That's the idle placeholder; the Mac isn't reaching the Pi. Check
  `journalctl -fu kvm-receiver` while `forward.sh` runs. "Mac stream live" means
  frames are arriving. The repeating `Error opening input ... udp://` line is
  normal while idle: the decoder times out every 5 s and respawns.
- Make sure nothing on the Mac's network blocks UDP 1234 to the Pi.

**Mic is silent**
- The target has to have the MeetUp mic open; the gadget only moves audio
  while the host is recording. Until then `journalctl -u kvm-receiver` repeats
  `audio sink exited ... restarting`, which is harmless.
- `cat /proc/asound/UAC2Gadget/pcm0p/info` must exist. The mic is the gadget's
  *playback* side (`p_chmask` in `setup-gadget.sh`). f_uac2 names directions
  from the gadget's point of view, so `c_chmask` would make a speaker instead.

**Keyboard or mouse do nothing**
- `journalctl -fu kvm-bridge` should show `WS client connected` and
  `HID endpoint opened`. If the bridge can't open `/dev/hidg*`, check that
  `/etc/udev/rules.d/99-kvm-hidg.rules` is installed and that the devices are
  group `input`.

---

## Design notes

- **Why receiver.py is the UVC driver.** The freedesktop `uvc-gadget` daemon
  reads its source with DMABUF export, which v4l2loopback doesn't implement, so
  the host's camera start timed out (`0xA00F4292`). receiver.py talks to the
  gadget's video node directly: it answers probe/commit, mmaps the gadget's
  buffers and copies in each frame. It must never exit (see the first
  troubleshooting item), so it sends black frames when the Mac is idle.
- **Why uncompressed (YUY2), not MJPEG.** The camera advertises YUY2
  640×480@30 and 1280×720@10 (~18 MB/s each, about what USB 2.0 bulk carries;
  720p30 would need 55 MB/s). It used to send MJPEG 1280×720@30, but Windows
  decodes MJPEG with the GPU's hardware JPEG decoder when the app asks for GPU
  frames (Chrome does), and AMD's (`amf-mft-mjpeg-decoder64.dll`, driver
  25.10) hangs the GPU after exactly 33 frames, whatever the JPEG: Chrome then
  sat at "starting your webcam". `tools/mjpegprobe` reproduces it. MJPEG
  720p30 can be switched back on with `UVC_MJPEG=1` in both `kvm-gadget.env`
  and `kvm-receiver.env`; with it on, apps asking for 720p30 pick MJPEG.
  The Mac sends 640×360 H.264 so the Pi only pads it (480p) or upscales it at
  10 fps (720p): resizing 720p on the Pi took most of its CPU.
- <a id="why-a-patched-uvc-module"></a>**Why a patched UVC module.** Webcams
  normally stream isochronously: a reserved slot every 125–500 µs. The Pi 4's
  dwc2 controller has no descriptor DMA, so the driver has to re-arm the
  endpoint from an interrupt before every slot, and its hardware only tracks
  even/odd slots. In practice about 12% of packets missed their slot. dwc2
  reports a miss as `-ENODATA`, which stock f_uvc treats as fatal: it dropped
  the half-sent frame without telling the host, and Windows spliced it onto
  the next frame (RGB garbage). `pi/kernel/usb_f_uvc/dwc2-bulk.patch`:
  - treats `-ENODATA` like the `-EXDEV` other controllers use, so a miss drops
    its frame cleanly;
  - adds a `bulk=1` module option that streams over a bulk endpoint instead.
    Bulk has no deadline: the host polls and the Pi answers when ready, so
    nothing is lost. Windows' built-in UVC driver supports bulk cameras.
    Upstream f_uvc already had a bulk data path but no way to switch it on, and
    its submit thread would spin forever with a bulk endpoint; the patch adds
    the descriptors, the module options, and those fixes.
  With bulk there is no alternate setting for the host to select, so
  receiver.py starts streaming when the host commits a format and restarts on
  the next commit. Each 16 KB request carries exactly one payload, so
  `dwMaxPayloadTransferSize` is the module's `bulk_payload`.
- **Why the camera runs half a second behind.** No frames were lost between
  the Mac and the Pi, but they arrived in clumps: Wi-Fi delivers a few late
  frames at once (~80 ms of spread, the odd 0.6 s stall), and the Pi's hardware
  H.264 decoder released 7-9 frames together around every keyframe. Sending
  only the newest frame threw away all but the last of each clump, so the
  camera stuttered. Now each frame has a time slot, `JITTER_MS` after an
  on-time frame would have arrived, and goes out then; the mic is delayed by
  the same amount. Decoding is in software (`H264_DECODER=h264`), which costs
  ~10% of a core more for the Mac's 640x360 and removes the clumps.
  `journalctl -u kvm-receiver` says once a minute if frames missed their
  slot; raise `JITTER_MS` if that keeps happening.
- **Why audio runs in a separate ffmpeg.** The UAC2 gadget's ALSA device only
  drains while the host is recording. A blocked ALSA write in the same ffmpeg
  as the video would freeze the camera too, so PCM hops over localhost UDP,
  which never blocks.

## Security

There is no authentication or encryption. Anyone who can reach port 8082 can
type on the target, and anyone who can reach UDP 1234 can feed its camera.
Keep the Pi on a trusted LAN or behind Tailscale or a VPN.

## Repo layout

```
pi/                    Raspberry Pi 4 KVM (this README)
  install.sh           one-shot installer
  setup-gadget.sh      configfs composite gadget
  bridge.py            web UI + WebSocket → HID
  receiver.py          Mac stream → UVC camera driver + UAC2 mic
  hdmi-capture.sh      EDID + ustreamer launcher
  uvc-mode.sh          switch between the stock and patched camera drivers
  kernel/usb_f_uvc/    patch + build script for the bulk-capable UVC gadget module
  kernel/dwc2_wakeup/  module that lets the Pi wake a sleeping target over USB
  edid/1080p50.hex     EDID for the TC358743
  static/index.html    browser UI
  *.service, *.rules   systemd units, udev rule
macforward/mac/        forward.sh: Mac webcam + mic → Pi (used with pi/)
macforward/pi-zero/    earlier standalone Pi Zero 2 W version (camera + mic only)
pico/                  earlier Pico HID bridge (superseded by the Pi 4 USB gadget)
```
