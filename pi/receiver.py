#!/usr/bin/env python3
"""Mac stream receiver + always-on camera feeder.

Owns the v4l2loopback device for the lifetime of the service and keeps it
fed with MJPEG frames, so the UVC gadget always has a live source:

  Mac UDP MPEG-TS --ffmpeg--> MJPEG frames  --> /dev/video50 --> uvc-gadget
                         +--> raw PCM (localhost UDP) --> ffmpeg --> ALSA UAC2Gadget

When the Mac isn't streaming, a black placeholder frame is written instead.
This matters because the kernel's UVC function holds the *whole* composite
gadget (keyboard and mouse included) disconnected from the host until
uvc-gadget is running, and uvc-gadget needs a capture-capable source to
start. If the feeder came and went with the Mac stream, the target PC would
lose its keyboard and mouse every time the stream stopped.

Audio goes through a separate ffmpeg process because the UAC2 gadget's ALSA
device only drains while the host has the mic open; a blocked ALSA write
would otherwise stall video too. The localhost UDP hop never blocks.

Env vars:
  PORT            UDP port the Mac streams to          (default 1234)
  WIDTH/HEIGHT    Frame size advertised by the gadget  (default 1280x720)
  FPS             Output frame rate                     (default 30)
  MJPEG_QUALITY   ffmpeg -q:v, 2 (best) .. 31 (worst)   (default 5)
  LOOPBACK        v4l2loopback device                   (default /dev/video50)
  AUDIO_PORT      localhost port for the PCM hop        (default 1236)
  UAC2_CARD       ALSA device for the gadget mic        (default hw:UAC2Gadget)
"""
import fcntl
import logging
import os
import queue
import struct
import subprocess
import threading
import time

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("receiver")

PORT = int(os.environ.get("PORT", "1234"))
WIDTH = int(os.environ.get("WIDTH", "1280"))
HEIGHT = int(os.environ.get("HEIGHT", "720"))
FPS = int(os.environ.get("FPS", "30"))
MJPEG_QUALITY = os.environ.get("MJPEG_QUALITY", "5")
LOOPBACK = os.environ.get("LOOPBACK", "/dev/video50")
AUDIO_PORT = int(os.environ.get("AUDIO_PORT", "1236"))
UAC2_CARD = os.environ.get("UAC2_CARD", "hw:UAC2Gadget")

# Mac stream silent for this long -> switch to the placeholder.
STALE_AFTER = 1.0
PLACEHOLDER_FPS = 5
# ffmpeg exits after this long without UDP data, and we respawn it so each
# new Mac session starts with a fresh demuxer/decoder.
UDP_TIMEOUT_US = 5_000_000

# --- V4L2 output setup -------------------------------------------------------
# struct v4l2_format on 64-bit: u32 type, 4 bytes pad, 200-byte union. We only
# fill the v4l2_pix_format head (12 x u32).
VIDIOC_S_FMT = 0xC0D05605
V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_PIX_FMT_MJPEG = 0x47504A4D  # 'MJPG'
V4L2_FIELD_NONE = 1
V4L2_COLORSPACE_JPEG = 7


def open_loopback() -> int:
    fd = os.open(LOOPBACK, os.O_WRONLY)
    sizeimage = WIDTH * HEIGHT * 2  # worst case for MJPEG; matches the gadget's dwMaxVideoFrameBufferSize
    pix = struct.pack("12I", WIDTH, HEIGHT, V4L2_PIX_FMT_MJPEG, V4L2_FIELD_NONE,
                      0, sizeimage, V4L2_COLORSPACE_JPEG, 0, 0, 0, 0, 0)
    fmt = struct.pack("I4x", V4L2_BUF_TYPE_VIDEO_OUTPUT) + pix
    fmt += b"\0" * (208 - len(fmt))
    fcntl.ioctl(fd, VIDIOC_S_FMT, bytearray(fmt))
    log.info("Loopback %s configured: MJPEG %dx%d", LOOPBACK, WIDTH, HEIGHT)
    return fd


def make_placeholder() -> bytes:
    return subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
         "-f", "lavfi", "-i", f"color=c=black:s={WIDTH}x{HEIGHT}",
         "-frames:v", "1", "-pix_fmt", "yuvj422p", "-f", "mjpeg", "-"],
        check=True, capture_output=True).stdout


# --- ffmpeg children ---------------------------------------------------------
def audio_sink_loop():
    """Keep the PCM -> ALSA sink running forever."""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
           "-f", "s16le", "-ar", "48000", "-ac", "2",
           "-i", f"udp://127.0.0.1:{AUDIO_PORT}?overrun_nonfatal=1&fifo_size=100000",
           "-f", "alsa", UAC2_CARD]
    while True:
        rc = subprocess.run(cmd).returncode
        log.warning("audio sink exited (%s); restarting", rc)
        time.sleep(2)


def read_mpjpeg(stream, frames: "queue.Queue[bytes]"):
    """Parse ffmpeg's multipart MJPEG (-f mpjpeg) output into JPEG frames."""
    while True:
        length = None
        while True:
            line = stream.readline()
            if not line:
                return
            line = line.strip()
            if not line:
                if length is not None:
                    break
                continue
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1])
        data = stream.read(length)
        if len(data) < length:
            return
        try:
            frames.put_nowait(data)
        except queue.Full:
            pass  # writer is behind; drop rather than add latency


def receiver_loop(frames: "queue.Queue[bytes]"):
    """Run the UDP -> MJPEG decoder, respawning it whenever it exits."""
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
           "-fflags", "+nobuffer+discardcorrupt", "-flags", "low_delay",
           "-i", f"udp://0.0.0.0:{PORT}?overrun_nonfatal=1&fifo_size=1000000&timeout={UDP_TIMEOUT_US}",
           "-map", "0:v",
           "-vf", f"scale={WIDTH}:{HEIGHT},fps={FPS},format=yuvj422p",
           "-c:v", "mjpeg", "-q:v", MJPEG_QUALITY, "-f", "mpjpeg", "pipe:1",
           "-map", "0:a", "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
           "-f", "s16le", f"udp://127.0.0.1:{AUDIO_PORT}?pkt_size=1024"]
    while True:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        read_mpjpeg(proc.stdout, frames)
        proc.wait()
        time.sleep(0.5)


def main():
    placeholder = make_placeholder()
    fd = open_loopback()
    frames: "queue.Queue[bytes]" = queue.Queue(maxsize=4)

    threading.Thread(target=audio_sink_loop, daemon=True).start()
    threading.Thread(target=receiver_loop, args=(frames,), daemon=True).start()
    log.info("Listening for the Mac stream on udp://0.0.0.0:%d", PORT)

    last_live = 0.0
    live = False
    while True:
        try:
            frame = frames.get(timeout=1 / PLACEHOLDER_FPS)
            if not live:
                log.info("Mac stream live")
                live = True
            last_live = time.monotonic()
        except queue.Empty:
            if time.monotonic() - last_live < STALE_AFTER:
                continue
            if live:
                log.info("Mac stream idle; sending placeholder")
                live = False
            frame = placeholder
        os.write(fd, frame)


if __name__ == "__main__":
    main()
