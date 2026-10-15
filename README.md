# briKVM

A DIY IP-KVM built on a Raspberry Pi 4. One USB-C cable from the Pi to the
target PC carries a keyboard, a mouse, a webcam and a microphone, and an
HDMI-to-CSI bridge captures the target's screen. You drive the target from a
browser, and you can forward your Mac's webcam and mic so the target sees
them as a plug-and-play USB conferencing device.

```
                       ┌──────────────────────── Raspberry Pi 4 ─────────────────────────┐
 Target HDMI out ────► │ TC358743 (CSI) ─► ustreamer :8080 ──────────────┐               │
                       │                                                 ▼               │
 Browser ◄───────────► │ bridge.py :8082 (web UI + WebSocket) ─► /dev/hidg0 (keyboard)   │
                       │                                      └► /dev/hidg1 (mouse)      │──► USB-C ──► Target PC
 Mac webcam + mic ───► │ receiver.py udp:1234 ─► /dev/video50 ─► uvc-gadget (camera)     │   (via PiKVM   sees "Logitech MeetUp":
  (forward.sh)         │                      └► ALSA UAC2Gadget (microphone)            │    splitter)   kbd + mouse + cam + mic
                       └─────────────────────────────────────────────────────────────────┘
```

The USB gadget identifies itself as a **Logitech MeetUp (046D:086B)**, a real
conferencing device that natively ships a camera, mic and HID remote on one
cable, so the composite device looks ordinary to the target OS.

---

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4 (2 GB+) | The USB-C port is the only port that can act as a USB *device*. |
| PiKVM USB-C power/data splitter | Plugs into the Pi's USB-C port. Power goes in one side, data goes to the target from the other. |
| 5 V / 3 A USB-C power supply | Goes into the splitter's **PWR** port. |
| **Data-capable** USB cable, splitter → target | Goes from the splitter's **USB/data** port to the target PC. Many USB-A↔C cables are charge-only and will power things but never enumerate. If the target never chimes, swap the cable first. A USB-C↔USB-C cable is known to work. |
| HDMI-to-CSI bridge (TC358743, e.g. the C779/B101 boards) | Ribbon cable into the Pi's CAMERA connector. Target HDMI out → bridge HDMI in. |
| microSD card | Ubuntu Server 26.04 for Raspberry Pi (tested) or 64-bit Raspberry Pi OS Bookworm+. |

### Wiring

1. Seat the CSI ribbon from the bridge into the Pi's **CAMERA** port, with contacts facing the HDMI ports on the Pi 4.
2. Connect the target PC's HDMI out to the bridge's HDMI in.
3. Plug the splitter into the Pi's USB-C port.
4. Plug the power supply into the splitter's **PWR** port.
5. Run a data cable from the splitter's **USB/data** port to the target PC.

---

## Pi setup

### 1. Flash and boot

Flash Ubuntu Server for Raspberry Pi (or Raspberry Pi OS 64-bit) with Raspberry
Pi Imager. In the imager settings, set the hostname, your user (the services
assume `rahul`; see `BRIDGE_USER` below), Wi-Fi/Ethernet and an SSH key. Boot
and SSH in:

```sh
ssh rahul@<pi-ip>
```

### 2. Give the Pi access to this (private) repo

```sh
ssh-keygen -t ed25519           # if ~/.ssh/id_ed25519 doesn't exist yet
cat ~/.ssh/id_ed25519.pub       # add at github.com → Settings → SSH keys
ssh -T git@github.com           # should greet you by username
```

### 3. Clone and install

```sh
git clone git@github.com:rvaidun/pikvm.git ~/pikvm
cd ~/pikvm/pi
sudo bash install.sh            # BRIDGE_USER=<you> sudo -E bash install.sh for a different user
sudo reboot
```

The installer is idempotent; re-run it any time. It:

1. Sets `dtoverlay=dwc2,dr_mode=peripheral` in `/boot/firmware/config.txt`, replacing the bare `dtoverlay=dwc2` (OTG) that Ubuntu ships.
2. Adds `dtoverlay=tc358743` for the HDMI-to-CSI bridge. It has no EEPROM, so camera auto-detect never finds it.
3. Autoloads `dwc2` and `libcomposite`, and pins v4l2loopback to `/dev/video50`. `/dev/video10`–`31` belong to the Pi 4's hardware codec and ISP.
4. Installs ffmpeg, ustreamer, v4l2loopback-dkms plus the matching kernel headers, and build tools.
5. Builds [uvc-gadget](https://gitlab.freedesktop.org/camera/uvc-gadget) into `/usr/local`. It isn't packaged.
6. Copies the code to `/opt/kvm/`, then installs the udev rule and the five systemd units and enables them.

### 4. Verify after the reboot

```sh
systemctl is-active kvm-gadget kvm-bridge kvm-receiver kvm-uvc kvm-ustreamer   # all "active"
cat /sys/class/udc/*/state            # "configured" = the target has enumerated the Pi
cat /sys/class/udc/*/current_speed    # "high-speed"
ls -l /dev/hidg0 /dev/hidg1 /dev/video50
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

Device indices default to `1:1` (MacBook Pro camera and mic). To list them:

```sh
ffmpeg -f avfoundation -list_devices true -i ""
VIDEO_IDX=0 AUDIO_IDX=0 ./forward.sh <pi-ip>
```

Other knobs: `WIDTH`, `HEIGHT`, `FPS`, `VBITRATE`, `ABITRATE`, `PORT`. If you
change the resolution or port, set the same values in `/etc/kvm-receiver.env`
on the Pi. Note that the gadget only advertises 1280×720.

---

## Services

| Unit | What it does | Port / device |
|---|---|---|
| `kvm-gadget` | `setup-gadget.sh`: builds the configfs composite gadget (HID kbd + mouse, UVC, UAC2) and binds it to the dwc2 UDC. | `/dev/hidg0`, `/dev/hidg1` |
| `kvm-bridge` | `bridge.py`: serves the web UI and turns WebSocket messages into HID reports. | TCP 8082 |
| `kvm-ustreamer` | `hdmi-capture.sh`: loads the EDID into the TC358743, then runs ustreamer with the Pi's hardware JPEG encoder. | TCP 8080 |
| `kvm-receiver` | `receiver.py`: decodes the Mac's stream into MJPEG on `/dev/video50` (black frames when idle) and PCM to the UAC2 mic. | UDP 1234 |
| `kvm-uvc` | `uvc-handler.sh`: runs `uvc-gadget` to move frames from `/dev/video50` to the USB camera. | — |

Logs: `journalctl -fu kvm-<name>`.

### Configuration files

| File | Overrides |
|---|---|
| `/etc/kvm-gadget.env` | `VENDOR_ID`, `PRODUCT_ID`, `MANUFACTURER`, `PRODUCT`, `SERIAL` (USB identity); `CAMERA_NAME`, `MIC_NAME` (what Windows calls the camera and mic, default "Logitech MeetUp") |
| `/etc/kvm-receiver.env` | `PORT`, `WIDTH`, `HEIGHT`, `FPS`, `MJPEG_QUALITY`, `UAC2_CARD` |
| `/etc/kvm-ustreamer.env` | `EDID`, `LISTEN_HOST`, `LISTEN_PORT`, `QUALITY` |

Restart the relevant unit after editing. Changing the USB identity needs
`sudo systemctl restart kvm-gadget kvm-uvc`.

### Updating

```sh
cd ~/pikvm && git pull
sudo bash pi/install.sh
sudo systemctl restart kvm-gadget kvm-receiver kvm-uvc kvm-bridge kvm-ustreamer
```

A reboot is only needed if `config.txt` changed.

---

## Troubleshooting

**Target never chimes / `/sys/class/udc/*/state` says `not attached`**
1. `systemctl status kvm-uvc`: **uvc-gadget must be running.** The kernel's UVC
   function keeps the *whole* gadget, keyboard and mouse included, disconnected
   until uvc-gadget opens it. That in turn needs `kvm-receiver` to be feeding
   `/dev/video50`.
2. `grep fe980000 /proc/interrupts`: if the count stays at 0 while uvc-gadget is
   running, the target isn't on the bus at all. Suspect the cable first
   (charge-only cables are common), then the splitter port (it must be the
   data port, not PWR), then the target's USB port.
3. `dmesg | grep dwc2`: if you see `DWC OTG Controller ... new USB bus registered`,
   the controller came up as a *host*. Check that `config.txt` has
   `dtoverlay=dwc2,dr_mode=peripheral` and reboot.

**Web UI shows no video / ustreamer reports `online: false`**
- `journalctl -u kvm-ustreamer`. "No signal" usually means the target hasn't
  re-read the EDID. Unplug and replug the HDMI cable, or `sudo systemctl restart kvm-ustreamer`.
- `v4l2-ctl -d /dev/video0 --query-dv-timings` shows what the target is sending.
- The Pi 4's CSI port has 2 lanes, so the ceiling is **1080p50**. The shipped
  EDID (`pi/edid/1080p50.hex`) prefers 1920×1080@50 with 1280×720@60 as
  fallback. If the target forces 1080p60, the driver refuses the mode; set
  50 Hz or 720p on the target.
- `dmesg | grep tc358743` should show `tc358743 found`. If not, reseat the
  ribbon and check `dtoverlay=tc358743` in `config.txt`.
- Black bars on the sides mean the target is mirroring a non-16:9 laptop panel.
  Switch Windows to "Show only on 2" or "Extend" to get the full frame.

**Target sees the camera but it's black**
- That's the idle placeholder; the Mac isn't reaching the Pi. Check
  `journalctl -fu kvm-receiver` while `forward.sh` runs. "Mac stream live" means
  frames are arriving. The repeating `Error opening input ... udp://` line is
  normal while idle: the decoder times out every 5 s and respawns.
- Make sure nothing on the Mac's network blocks UDP 1234 to the Pi.

**Mic is silent**
- The target has to have the MeetUp mic open; the gadget only moves audio
  while the host is recording. `aplay -l` on the Pi should list `UAC2Gadget`.

**Keyboard or mouse do nothing**
- `journalctl -fu kvm-bridge` should show `WS client connected` and
  `HID endpoint opened`. If the bridge can't open `/dev/hidg*`, check that
  `/etc/udev/rules.d/99-kvm-hidg.rules` is installed and that the devices are
  group `input`.

---

## Design notes

- **Why `/dev/video50`.** On a Pi 4, `/dev/video10`–`31` are the bcm2835
  codec and ISP. Asking v4l2loopback for `video_nr=10` silently lands
  somewhere else, and every hard-coded path breaks.
- **Why MJPEG into the loopback.** The UVC gadget only advertises MJPEG
  1280×720 (uncompressed 720p30 won't fit in USB 2.0 isochronous bandwidth),
  and uvc-gadget passes the host's requested format straight through to its
  source.
- **Why receiver.py never lets go of the loopback.** See the first
  troubleshooting item. If the producer went away whenever the Mac stopped
  streaming, uvc-gadget would stop, and the target would lose its keyboard and
  mouse along with the camera.
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
  receiver.py          Mac stream → loopback camera + UAC2 mic
  uvc-handler.sh       uvc-gadget launcher
  hdmi-capture.sh      EDID + ustreamer launcher
  edid/1080p50.hex     EDID for the TC358743
  static/index.html    browser UI
  *.service, *.rules   systemd units, udev rule
macforward/mac/        forward.sh: Mac webcam + mic → Pi (used with pi/)
macforward/pi-zero/    earlier standalone Pi Zero 2 W version (camera + mic only)
pico/                  earlier Pico HID bridge (superseded by the Pi 4 USB gadget)
```
