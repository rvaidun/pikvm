# rahKVM MacForward

Forward the Mac's webcam + microphone to a Windows PC via a Raspberry Pi Zero 2 W
acting as a USB gadget. Windows sees a plug-and-play **USB Camera** + **USB
Microphone** with no drivers.

```
Mac (webcam + mic)
   │  H.264/AAC MPEG-TS over UDP
   ▼
Pi Zero 2 W
   ├─ ffmpeg: UDP → v4l2loopback /dev/video10 (video) + ALSA UAC2Gadget (audio)
   └─ uvc-gadget: /dev/video10 → UVC function → USB
   │  USB-C data cable (Pi Zero's "USB" port, NOT "PWR IN")
   ▼
Windows PC
   └─ sees "rahKVM MacForward" camera + microphone
```

## Hardware

- **Pi Zero 2 W** (the W or 2 W, not plain Zero — ARMv6 is too weak for 720p)
- **Micro-USB cable, data-capable** connecting Pi Zero's `USB` port to a Windows USB port
- **Separate power** for the Pi Zero (either via `PWR IN` micro-USB from a wall adapter, or via GPIO 5V/GND if you prefer)

## Setup (one time)

### On the Pi Zero
1. Flash Raspberry Pi OS Lite (64-bit, Bookworm or newer) to an SD card
2. Boot, SSH in, clone this repo
3. `cd pikvm/macforward/pi-zero && sudo bash install.sh`
4. `sudo reboot`
5. Plug the Pi Zero's `USB` micro-USB (not `PWR IN`) into the Windows target
6. Windows should enumerate "rahKVM MacForward" camera + mic

### On the Mac
Nothing to install — ffmpeg is the only dep. If you don't have it: `brew install ffmpeg`.

## Daily use

```
cd ~/GitProjects/pikvm/macforward/mac
./forward.sh pizero.local         # or ./forward.sh 192.168.1.XX
```

Press Ctrl-C to stop streaming.

Env knobs:
- `WIDTH=640 HEIGHT=480 FPS=15 ./forward.sh pizero.local` — lower quality
- `VBITRATE=8M ./forward.sh pizero.local` — crank video bitrate
- `VIDEO_IDX=0 ./forward.sh pizero.local` — use a different AVFoundation camera

To list cameras + mics on the Mac:
```
ffmpeg -f avfoundation -list_devices true -i ""
```

## Menubar preview + controls

`mac/preview/` is a small menubar app, **MacForward Preview**, that shows the
picture forward.sh is sending and works its keys (live / fallback, clips 1-9,
mic, sync, stop) with buttons.

```
cd ~/GitProjects/pikvm/macforward/mac/preview
./build.sh --install     # builds, copies to ~/Applications, launches
```

Click the menubar icon for the preview; right-click for a menu with
**Open Window** (a resizable window that stays on top, pin to toggle).
Double-clicking the popover's picture opens the window too. Needs only the
Xcode command line tools (`swiftc`).

forward.sh writes a small JPEG of the outgoing picture and a status file to
`/tmp/macforward.<uid>.lock/` while it runs (`PREVIEW=0` turns that off),
and takes keys from the app as lines in `requests` there plus a USR1.

## Troubleshooting

- **Windows doesn't see the camera**: check `dmesg | grep dwc2` on the Pi — if it says "mode: host", the OTG overlay isn't active. Confirm `dtoverlay=dwc2` is in `/boot/firmware/config.txt` and reboot.
- **Camera appears but no video**: Pi receiver may not be getting the stream. `sudo journalctl -fu macforward-receiver` while running the Mac forwarder.
- **Audio but no video (or vice versa)**: check `v4l2-ctl --list-devices` on the Pi for `/dev/video10` and `arecord -L` for `UAC2Gadget`.
- **Latency too high**: drop FPS/resolution on the Mac side; a few seconds of latency is normal with UDP MPEG-TS buffering.

## Known limitations (v1)

- No encryption on the Mac→Pi UDP hop. Only use on trusted LANs.
- Only 1 resolution advertised to Windows (1280x720 @ 30fps). Add more frames to `setup-gadget.sh` if needed.
- Mac must be running the forwarder script continuously; no auto-reconnect in UI.
