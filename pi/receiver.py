#!/usr/bin/env python3
"""Mac stream receiver + USB camera (UVC) and mic (UAC2) driver.

  Mac UDP MPEG-TS --ffmpeg--> MJPEG + YUY2 frames --> this process --> UVC gadget --> host webcam
                         +--> raw PCM (localhost UDP) --> ffmpeg --> ALSA UAC2Gadget --> host mic

This process *is* the UVC userspace daemon: it answers the host's UVC
control requests (format probe/commit, the two image controls the gadget
advertises), and while the host is streaming it copies frames of the
committed format into the gadget's mmap'd buffers. When the Mac isn't
streaming it sends a black placeholder, so the camera always works.

Frames reach this process in clumps: Wi-Fi delivers a few late frames at
once, and the Pi's hardware H.264 decoder released 7-9 at a time around each
keyframe. Sending only the newest frame threw away all but the last of each
clump, so the camera stuttered although no frame was lost. Instead each
mode's frames queue up (FrameStore) and each goes out at its own time slot,
JITTER_MS after an on-time frame would have arrived, so they leave evenly
spaced; the mic is delayed by the same amount to stay in sync.

The camera offers uncompressed YUY2 640x480@30 and 1280x720@10, plus MJPEG
1280x720@30 with UVC_MJPEG=1 (MODES; setup-gadget.sh must declare the same
formats in the same order, so set UVC_MJPEG for both). MJPEG is off by default
because hosts that decode it on the GPU can't be trusted: AMD's hardware MJPEG
decoder (driver 25.10) hangs the GPU after 33 frames whatever the JPEG, and
apps asking for 720p30 would pick MJPEG over YUY2 720p10. USB 2.0 bulk
carries ~18 MB/s of YUY2, hence the small/slow uncompressed modes.

With the patched usb_f_uvc loaded with bulk=1 (pi/kernel/usb_f_uvc), the
camera streams over a bulk endpoint. Bulk has no alternate setting for the
host to select, so streaming starts when the host commits a format rather
than on UVC_EVENT_STREAMON, and dwMaxPayloadTransferSize is the module's
bulk_payload instead of the isochronous packet size.

It has to run all the time: the kernel's UVC function keeps the *whole*
composite gadget (keyboard and mouse included) disconnected from the host
until a process subscribes to UVC events on the gadget's video node.

Audio goes through a separate ffmpeg because the UAC2 gadget's ALSA device
only drains while the host has the mic open; a blocked ALSA write would
otherwise stall video. The localhost UDP hop never blocks.

Env vars:
  PORT            UDP port the Mac streams to          (default 1234)
  UVC_MJPEG       1 = also offer MJPEG 1280x720@30      (default 0; must match setup-gadget.sh)
  MJPEG_QUALITY   ffmpeg -q:v, 2 (best) .. 31 (worst)   (default 7)
  H264_DECODER    ffmpeg decoder for the Mac stream     (default h264 = software; h264_v4l2m2m = hardware)
  JITTER_MS       how far behind the Mac video plays, to smooth out late frames (default 500)
  AUDIO_PORT      localhost port for the PCM hop        (default 1236)
  UAC2_CARD       ALSA device for the gadget mic        (default hw:UAC2Gadget)
  GADGET          configfs gadget name                  (default g1)
"""
import errno
import fcntl
import logging
import math
import mmap
import os
import select
import struct
import subprocess
import threading
import time
from collections import deque
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("receiver")

PORT = int(os.environ.get("PORT", "1234"))
MJPEG_QUALITY = os.environ.get("MJPEG_QUALITY", "7")
# Software, not the Pi 4's h264_v4l2m2m: for the Mac's 640x360 stream the
# whole ffmpeg took 34% of a core with it vs 25% with the hardware decoder,
# but the hardware decoder handed frames over 7-9 at a time around every
# keyframe, which took a ~300 ms jitter buffer to hide. (It only paid off
# when the Mac sent 720p, at ~1/5 the CPU.)
H264_DECODER = os.environ.get("H264_DECODER", "h264")
# Video plays this far behind an on-time frame's arrival, so frames delivered
# late and in clumps still go out evenly. Wi-Fi alone spread frames over
# ~80 ms, with the odd stall of 0.6 s.
JITTER_MS = int(os.environ.get("JITTER_MS", "500"))
DELAY = JITTER_MS / 1000
AUDIO_PORT = int(os.environ.get("AUDIO_PORT", "1236"))
UAC2_CARD = os.environ.get("UAC2_CARD", "hw:UAC2Gadget")
GADGET = os.environ.get("GADGET", "g1")

# Mac stream silent for this long -> switch to the placeholder.
STALE_AFTER = 1.0
PLACEHOLDER_FPS = 5
# ffmpeg exits after this long without UDP data, and we respawn it so each
# new Mac session starts with a fresh demuxer/decoder.
UDP_TIMEOUT_US = 5_000_000

# --- Kernel ABI (64-bit; verified against linux/videodev2.h + g_uvc.h) -------
VIDIOC_S_FMT = 0xC0D05605           # struct v4l2_format, 208 bytes
VIDIOC_REQBUFS = 0xC0145608         # struct v4l2_requestbuffers, 20 bytes
VIDIOC_QUERYBUF = 0xC0585609        # struct v4l2_buffer, 88 bytes
VIDIOC_QBUF = 0xC058560F
VIDIOC_DQBUF = 0xC0585611
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
VIDIOC_DQEVENT = 0x80885659         # struct v4l2_event, 136 bytes, union at +8
VIDIOC_SUBSCRIBE_EVENT = 0x4020565A  # struct v4l2_event_subscription, 32 bytes
UVCIOC_SEND_RESPONSE = 0x40405501   # struct uvc_request_data: s32 length + 60 bytes

V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_MEMORY_MMAP = 1
V4L2_FIELD_NONE = 1
V4L2_PIX_FMT_MJPEG = 0x47504A4D     # 'MJPG'
V4L2_PIX_FMT_YUYV = 0x56595559      # 'YUYV' (UVC's YUY2)
V4L2_COLORSPACE_REC709 = 3
V4L2_COLORSPACE_JPEG = 7
BUF_SIZE = 88

UVC_EVENT_CONNECT = 0x08000000
UVC_EVENT_DISCONNECT = 0x08000001
UVC_EVENT_STREAMON = 0x08000002
UVC_EVENT_STREAMOFF = 0x08000003
UVC_EVENT_SETUP = 0x08000004
UVC_EVENT_DATA = 0x08000005

UVC_SET_CUR, UVC_GET_CUR, UVC_GET_MIN, UVC_GET_MAX = 0x01, 0x81, 0x82, 0x83
UVC_GET_RES, UVC_GET_LEN, UVC_GET_INFO, UVC_GET_DEF = 0x84, 0x85, 0x86, 0x87
UVC_VS_PROBE_CONTROL, UVC_VS_COMMIT_CONTROL = 0x01, 0x02
# f_uvc rewrites wIndex's interface byte for userspace: 0 = control, 1 = streaming.
UVC_INTF_CONTROL, UVC_INTF_STREAMING = 0, 1

class Mode:
    """One UVC format/frame the gadget advertises, and the frames that feed it."""

    def __init__(self, source: str, fourcc: int, width: int, height: int, fps: int):
        self.source, self.fourcc = source, fourcc
        self.width, self.height, self.fps = width, height, fps
        self.interval = 10_000_000 // fps     # 100 ns units
        self.frame_size = width * height * 2  # YUY2 size; also the MJPEG buffer size

    @property
    def raw(self) -> bool:
        return self.fourcc == V4L2_PIX_FMT_YUYV


def build_modes(mjpeg: bool) -> dict[tuple[int, int], Mode]:
    """(bFormatIndex, bFrameIndex) -> Mode, numbered like setup-gadget.sh
    declares them: the uncompressed format first (frames in creation order),
    then MJPEG when UVC_MJPEG=1."""
    modes = {
        (1, 1): Mode("yuy2-480", V4L2_PIX_FMT_YUYV, 640, 480, 30),
        (1, 2): Mode("yuy2-720", V4L2_PIX_FMT_YUYV, 1280, 720, 10),
    }
    if mjpeg:
        modes[(2, 1)] = Mode("mjpeg", V4L2_PIX_FMT_MJPEG, 1280, 720, 30)
    return modes


MODES = build_modes(os.environ.get("UVC_MJPEG", "0") == "1")
DEFAULT_MODE = (1, 1)

# struct uvc_streaming_control (UVC 1.1, 34 bytes, packed little-endian)
STREAMING_CTRL = struct.Struct("<HBBIHHHHHIIIBBBB")


def streaming_ctrl(key: tuple[int, int], max_payload: int) -> bytes:
    mode = MODES[key]
    return STREAMING_CTRL.pack(
        1,                      # bmHint: dwFrameInterval is fixed
        key[0], key[1],         # bFormatIndex, bFrameIndex
        mode.interval,
        0, 0, 0, 0, 0,          # wKeyFrameRate .. wDelay
        mode.frame_size,        # dwMaxVideoFrameSize, matches dwMaxVideoFrameBufferSize
        max_payload,            # dwMaxPayloadTransferSize
        48_000_000,             # dwClockFrequency: the gadget's PTS/SCR clock
        3, 1, 1, 1)             # bmFramingInfo (FID+EOF), preferred/min/max payload version


# Image controls the gadget's default descriptors advertise (read-only in
# configfs, so we have to answer for them): camera terminal (entity 1)
# auto-exposure mode, processing unit (entity 2) brightness, plus the
# interface's request error code. (entity, selector) -> spec.
CONTROLS = {
    (0, 0x02): dict(fmt="<B", info=0x01, cur=0, mn=0, mx=0, res=0, df=0),        # VC_REQUEST_ERROR_CODE
    (1, 0x02): dict(fmt="<B", info=0x03, cur=2, mn=2, mx=2, res=2, df=2),        # CT_AE_MODE: auto only
    (2, 0x02): dict(fmt="<h", info=0x03, cur=128, mn=0, mx=255, res=1, df=128),  # PU_BRIGHTNESS
}


def make_placeholder(mode: Mode) -> bytes:
    if mode.raw:
        return b"\x10\x80" * (mode.width * mode.height)   # black, limited range
    return subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
         "-f", "lavfi", "-i", f"color=c=black:s={mode.width}x{mode.height}",
         "-frames:v", "1", "-pix_fmt", "yuvj422p", "-huffman", "default", "-f", "mjpeg", "-"],
        check=True, capture_output=True).stdout


class FrameStore:
    """One mode's decoded Mac frames, oldest first, each sent at its slot.

    ffmpeg's fps filter makes the stream exactly 1/fps per frame, so frame n
    of a session "should" arrive n periods after frame 0. How late it really
    is (arrival - n * period) varies with Wi-Fi and the decoder; the least
    lateness seen lately is what an on-time frame looks like, and every frame
    is due DELAY after that. Frames then leave evenly spaced however they
    arrived, and at a fixed delay the mic can match.

    The receiver thread pushes; the UVC loop takes. Both run under a lock.
    """

    WINDOW = 5.0   # s; "lately" means the last 5-10 s, so clock drift and
                   # changes in network delay are followed

    def __init__(self, mode: Mode):
        self.period = 1 / mode.fps
        # The mode the host isn't streaming keeps filling too: keep at most
        # one second more than the delay (~28 MB for 480p, the same for 720p).
        self.cap = round((DELAY + 1) * mode.fps)
        self.lock = threading.Lock()
        self.frames: deque[tuple[int, bytes]] = deque()   # (n, frame)
        self.last_push = 0.0
        self.n = 0
        self.mins = [math.inf, math.inf]   # least lateness, previous and current window
        self.window_at = 0.0
        self.late = 0                      # frames sent over a period after their slot, or dropped
        self.count_from = 0.0              # ...except ffmpeg's startup backlog

    def push(self, frame: bytes):
        now = time.monotonic()
        with self.lock:
            if now - self.last_push > STALE_AFTER:
                # A new Mac session (ffmpeg was respawned): numbering and
                # lateness start over, and leftovers would never come due.
                self.frames.clear()
                self.n, self.mins, self.window_at = 0, [math.inf, math.inf], now
                # A new ffmpeg first decodes the ~5 s it buffered while
                # probing the stream, all at once; dropping that isn't news.
                self.count_from = now + 2.0
            self.last_push = now
            if now - self.window_at > self.WINDOW:
                self.mins, self.window_at = [self.mins[1], math.inf], now
            self.mins[1] = min(self.mins[1], now - self.n * self.period)
            self.frames.append((self.n, frame))
            self.n += 1
            while len(self.frames) > self.cap:
                self.frames.popleft()

    def _due(self, n: int) -> float:
        return min(self.mins) + n * self.period + DELAY

    def next_due(self) -> float | None:
        with self.lock:
            return self._due(self.frames[0][0]) if self.frames else None

    def take(self, now: float) -> bytes | None:
        """The newest frame whose slot has come, or None if none has. Older
        due frames are dropped: they arrived too late (or the host wasn't
        reading), and sending them now would bunch them up again."""
        frame = due = None
        dropped = 0
        with self.lock:
            while self.frames and (d := self._due(self.frames[0][0])) <= now:
                if frame is not None:
                    dropped += 1
                frame, due = self.frames.popleft()[1], d
            if now >= self.count_from:
                self.late += dropped + (due is not None and now - due > self.period)
        return frame

    def clear(self):
        with self.lock:
            self.frames.clear()


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


def read_mpjpeg(stream, store: FrameStore):
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
        store.push(data)


def read_raw(stream, size: int, store: FrameStore):
    """Split ffmpeg's rawvideo output into fixed-size frames."""
    while True:
        frame = bytearray(size)
        view, got = memoryview(frame), 0
        while got < size:
            n = stream.readinto(view[got:])
            if not n:
                return
            got += n
        store.push(bytes(frame))


# swscale's default bicubic costs ~1.5x fast_bilinear here; at webcam sizes
# the difference isn't visible.
SWS_FLAGS = "fast_bilinear"


def fit(mode: Mode) -> str:
    """Scale filter that letterboxes the 16:9 Mac picture into the mode's frame."""
    return (f"scale={mode.width}:{mode.height}:force_original_aspect_ratio=decrease"
            f":flags={SWS_FLAGS},pad={mode.width}:{mode.height}:(ow-iw)/2:(oh-ih)/2,"
            f"scale=flags={SWS_FLAGS}")


class Decoder:
    """Runs one UDP -> frames ffmpeg that feeds every mode at once.

    Each mode gets its own pipe and reader thread, and its FrameStore always
    holds recent frames, so when the host switches modes (Chrome opens
    480p, then moves to 720p) the next frame is already there. Restarting
    ffmpeg per mode instead left a second of black frames on every switch.
    With the Mac sending 640x360 this is cheap: 480p only pads, and 720p
    upscales at 10 fps. ffmpeg also carries the mic audio.
    """

    def __init__(self, stores: dict[str, FrameStore]):
        self.stores = stores

    @staticmethod
    def command(outputs: list[tuple[Mode, int]]) -> list[str]:
        """ffmpeg arguments writing each (mode, pipe fd) pair's frames to its fd."""
        # h264_v4l2m2m's frames live in the V4L2 capture buffers, which are
        # slow to read (uncached); swscale reads each line several times and
        # ran ~3x slower on them than on the software decoder's frames. One
        # sequential copy to ordinary memory first halves ffmpeg's CPU.
        graph = [f"[0:v]copy,split={len(outputs)}" + "".join(f"[s{i}]" for i in range(len(outputs)))]
        args = []
        for i, (mode, fd) in enumerate(outputs):
            if mode.raw:
                graph.append(f"[s{i}]fps={mode.fps},{fit(mode)},format=yuyv422[o{i}]")
                args += ["-map", f"[o{i}]", "-f", "rawvideo", f"pipe:{fd}"]
            else:
                graph.append(f"[s{i}]fps={mode.fps},{fit(mode)},format=yuvj422p[o{i}]")
                args += ["-map", f"[o{i}]", "-c:v", "mjpeg", "-huffman", "default",
                         "-q:v", MJPEG_QUALITY, "-f", "mpjpeg", f"pipe:{fd}"]
        return ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                "-fflags", "+nobuffer+discardcorrupt", "-flags", "low_delay",
                "-c:v", H264_DECODER,
                "-i", f"udp://0.0.0.0:{PORT}?overrun_nonfatal=1&fifo_size=1000000&timeout={UDP_TIMEOUT_US}",
                "-filter_complex", ";".join(graph), *args,
                # Hold the mic back as long as the video's jitter buffer.
                "-map", "0:a", "-af", f"adelay={JITTER_MS}:all=1",
                "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
                "-f", "s16le", f"udp://127.0.0.1:{AUDIO_PORT}?pkt_size=1024"]

    def run(self):
        """Respawn ffmpeg whenever it exits (the Mac went quiet)."""
        modes = list({m.source: m for m in MODES.values()}.values())
        while True:
            pipes = [os.pipe() for _ in modes]
            proc = subprocess.Popen(self.command([(m, w) for m, (_, w) in zip(modes, pipes)]),
                                    pass_fds=[w for _, w in pipes])
            readers = []
            for mode, (r, w) in zip(modes, pipes):
                os.close(w)
                readers.append(threading.Thread(target=self.read, args=(r, mode), daemon=True))
            for t in readers:
                t.start()
            proc.wait()
            for t in readers:
                t.join()
            time.sleep(0.5)

    def read(self, fd: int, mode: Mode):
        store = self.stores[mode.source]
        # read_raw copes with short reads; read_mpjpeg needs a buffered stream.
        with open(fd, "rb", buffering=0 if mode.raw else -1) as stream:
            if mode.raw:
                read_raw(stream, mode.frame_size, store)
            else:
                read_mpjpeg(stream, store)


# --- UVC gadget --------------------------------------------------------------
def find_uvc_node() -> str:
    """The gadget's video node is named after the UDC it's bound to."""
    udc_file = Path(f"/sys/kernel/config/usb_gadget/{GADGET}/UDC")
    for _ in range(60):
        udc = udc_file.read_text().strip() if udc_file.exists() else ""
        if udc:
            for node in Path("/sys/class/video4linux").glob("video*"):
                if (node / "name").read_text().strip() == udc:
                    return f"/dev/{node.name}"
        time.sleep(1)
    raise SystemExit(f"no UVC gadget video node for {GADGET}; is kvm-gadget running?")


class UvcCamera:
    NBUFS = 4

    def __init__(self, path: str, decoder: Decoder, placeholders: dict[str, bytes]):
        self.decoder = decoder
        self.stores = decoder.stores
        self.placeholders = placeholders
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        params = Path("/sys/module/usb_f_uvc/parameters")
        self.bulk = (params / "bulk").exists() and (params / "bulk").read_text().strip() == "Y"
        if self.bulk:
            max_payload = int((params / "bulk_payload").read_text())
        else:
            max_payload = int(Path(f"/sys/kernel/config/usb_gadget/{GADGET}/functions/uvc.usb0/streaming_maxpacket").read_text())
        self.max_payload = max_payload
        self.probe = DEFAULT_MODE     # what the host last proposed (PROBE)
        self.mode = DEFAULT_MODE      # what it committed (COMMIT), i.e. what we stream
        self.values = {k: v["cur"] for k, v in CONTROLS.items()}
        self.pending_set = None       # (interface, entity, selector) awaiting its DATA stage
        self.maps: list[mmap.mmap] = []
        self.free: list[int] = []
        self.streaming = False
        self.queue_on = False         # VIDIOC_STREAMON done; DQBUF is only valid after it
        self.sent_at = 0.0
        self.live = False
        self.stats_at = time.monotonic()
        # Subscribing to SETUP is what lets the gadget connect to the host.
        for ev in (UVC_EVENT_CONNECT, UVC_EVENT_DISCONNECT, UVC_EVENT_STREAMON,
                   UVC_EVENT_STREAMOFF, UVC_EVENT_SETUP, UVC_EVENT_DATA):
            fcntl.ioctl(self.fd, VIDIOC_SUBSCRIBE_EVENT, struct.pack("<III20x", ev, 0, 0))
        log.info("UVC gadget %s ready (%s, max payload %d)", path,
                 "bulk" if self.bulk else "isochronous", max_payload)

    # -- control requests --
    def respond(self, data: bytes | None):
        """data=None stalls the request."""
        if data is None:
            buf = struct.pack("<i60x", -errno.EL2HLT)
        else:
            buf = struct.pack("<i", len(data)) + data.ljust(60, b"\0")
        fcntl.ioctl(self.fd, UVCIOC_SEND_RESPONSE, buf)

    def on_setup(self, raw: bytes):
        req_type, req, value, index, length = struct.unpack("<BBHHH", raw)
        intf, entity, cs = index & 0xFF, index >> 8, value >> 8
        if (req_type & 0x60) != 0x20 or (req_type & 0x1F) != 0x01:   # class, interface
            return self.respond(None)

        if intf == UVC_INTF_STREAMING:
            if cs not in (UVC_VS_PROBE_CONTROL, UVC_VS_COMMIT_CONTROL):
                return self.respond(None)
            if req == UVC_SET_CUR:
                self.pending_set = (intf, entity, cs)
                return self.respond(bytes(min(length, STREAMING_CTRL.size)))
            if req == UVC_GET_DEF:
                return self.respond(streaming_ctrl(DEFAULT_MODE, self.max_payload)[:length])
            if req in (UVC_GET_CUR, UVC_GET_MIN, UVC_GET_MAX):
                # Each frame has a single interval, so the probed format/frame
                # pins every negotiable field: min = max = cur.
                key = self.probe if cs == UVC_VS_PROBE_CONTROL else self.mode
                return self.respond(streaming_ctrl(key, self.max_payload)[:length])
            if req == UVC_GET_RES:
                return self.respond(bytes(min(length, STREAMING_CTRL.size)))
            if req == UVC_GET_LEN:
                return self.respond(struct.pack("<H", STREAMING_CTRL.size))
            if req == UVC_GET_INFO:
                return self.respond(b"\x03")
            return self.respond(None)

        spec = CONTROLS.get((entity, cs))
        if intf != UVC_INTF_CONTROL or spec is None:
            return self.respond(None)
        pack = lambda v: struct.pack(spec["fmt"], v)
        if req == UVC_SET_CUR:
            self.pending_set = (intf, entity, cs)
            return self.respond(bytes(struct.calcsize(spec["fmt"])))
        answer = {
            UVC_GET_CUR: lambda: pack(self.values[(entity, cs)]),
            UVC_GET_MIN: lambda: pack(spec["mn"]),
            UVC_GET_MAX: lambda: pack(spec["mx"]),
            UVC_GET_RES: lambda: pack(spec["res"]),
            UVC_GET_DEF: lambda: pack(spec["df"]),
            UVC_GET_INFO: lambda: bytes([spec["info"]]),
            UVC_GET_LEN: lambda: struct.pack("<H", struct.calcsize(spec["fmt"])),
        }.get(req)
        self.respond(answer() if answer else None)

    def on_data(self, payload: bytes):
        target, self.pending_set = self.pending_set, None
        if target is None:
            return
        intf, entity, cs = target
        if intf == UVC_INTF_STREAMING:
            # bFormatIndex/bFrameIndex follow the 2-byte bmHint. An unknown
            # pair falls back to the default; dwFrameInterval is ignored since
            # each frame has exactly one.
            key = tuple(payload[2:4]) if len(payload) >= 4 else DEFAULT_MODE
            key = key if key in MODES else DEFAULT_MODE
            if cs == UVC_VS_PROBE_CONTROL:
                self.probe = key
            elif cs == UVC_VS_COMMIT_CONTROL:
                self.mode = self.probe = key
                mode = MODES[key]
                log.info("Host committed %s %dx%d @ %d fps", "YUY2" if mode.raw else "MJPEG",
                         mode.width, mode.height, mode.fps)
                if self.bulk:
                    # No alt setting to select with bulk: a commit is the start
                    # signal. The host never says when it stops, so a new
                    # commit restarts the stream (flushing what it never read).
                    self.stream_on()
            return
        spec = CONTROLS[(entity, cs)]
        self.values[(entity, cs)] = struct.unpack_from(spec["fmt"], payload.ljust(4, b"\0"))[0]

    # -- streaming --
    def stream_on(self):
        if self.streaming:
            self.stream_off()
        mode = MODES[self.mode]
        fmt = bytearray(208)
        struct.pack_into("<I", fmt, 0, V4L2_BUF_TYPE_VIDEO_OUTPUT)
        struct.pack_into("<12I", fmt, 8, mode.width, mode.height, mode.fourcc, V4L2_FIELD_NONE,
                         mode.width * 2 if mode.raw else 0, mode.frame_size,
                         V4L2_COLORSPACE_REC709 if mode.raw else V4L2_COLORSPACE_JPEG,
                         0, 0, 0, 0, 0)
        fcntl.ioctl(self.fd, VIDIOC_S_FMT, fmt)
        rb = bytearray(struct.pack("<IIII4x", self.NBUFS, V4L2_BUF_TYPE_VIDEO_OUTPUT, V4L2_MEMORY_MMAP, 0))
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS, rb)
        count = struct.unpack_from("<I", rb, 0)[0]
        for i in range(count):
            b = self._buf(i)
            fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, b)
            offset, length = struct.unpack_from("<I", b, 64)[0], struct.unpack_from("<I", b, 72)[0]
            self.maps.append(mmap.mmap(self.fd, length, mmap.MAP_SHARED,
                                       mmap.PROT_READ | mmap.PROT_WRITE, offset=offset))
        self.free = list(range(count))
        self.sent_at = 0.0
        self.streaming = True
        self.pump(reclaim=False)          # have a frame queued before the host's first poll
        for store in self.stores.values():
            store.late = 0                # catching up on a mode not streamed until now
        fcntl.ioctl(self.fd, VIDIOC_STREAMON, struct.pack("<i", V4L2_BUF_TYPE_VIDEO_OUTPUT))
        self.queue_on = True
        log.info("Host started streaming (%d buffers)", count)

    def stream_off(self):
        if not self.streaming:
            return
        self.streaming = self.queue_on = False
        try:
            fcntl.ioctl(self.fd, VIDIOC_STREAMOFF, struct.pack("<i", V4L2_BUF_TYPE_VIDEO_OUTPUT))
        except OSError as e:
            log.warning("STREAMOFF: %s", e)
        for m in self.maps:
            m.close()
        self.maps, self.free = [], []
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS,
                    bytearray(struct.pack("<IIII4x", 0, V4L2_BUF_TYPE_VIDEO_OUTPUT, V4L2_MEMORY_MMAP, 0)))
        log.info("Host stopped streaming")

    @staticmethod
    def _buf(index: int, bytesused: int = 0, timestamp: float = 0.0) -> bytearray:
        b = bytearray(BUF_SIZE)
        struct.pack_into("<IIIII", b, 0, index, V4L2_BUF_TYPE_VIDEO_OUTPUT, bytesused, 0, V4L2_FIELD_NONE)
        # struct timeval at 24. The gadget copies it into the payload header
        # as the PTS (48 MHz, CLOCK_MONOTONIC like its SCR); a zero timestamp
        # leaves the PTS out.
        usec = int(timestamp * 1_000_000)
        struct.pack_into("<qq", b, 24, usec // 1_000_000, usec % 1_000_000)
        struct.pack_into("<I", b, 60, V4L2_MEMORY_MMAP)
        return b

    def pump(self, reclaim: bool = True):
        """Reclaim sent buffers and queue the next frame if one is due."""
        if not self.streaming:
            return
        while reclaim and self.queue_on:
            b = self._buf(0)
            try:
                fcntl.ioctl(self.fd, VIDIOC_DQBUF, b)
            except BlockingIOError:
                break
            self.free.append(struct.unpack_from("<I", b, 0)[0])
        if not self.free:
            return

        now = time.monotonic()
        mode = MODES[self.mode]
        store = self.stores[mode.source]
        # When the Mac stops, play out what's buffered before going black.
        live = now - store.last_push < STALE_AFTER + DELAY
        if live != self.live:
            log.info("Mac stream %s", "live" if live else "idle; sending placeholder")
            self.live = live
        if live:
            frame = store.take(now)
            if frame is None:
                return
        else:
            store.clear()
            if now - self.sent_at < 1 / PLACEHOLDER_FPS:
                return
            frame = self.placeholders[mode.source]

        idx = self.free.pop()
        m = self.maps[idx]
        if len(frame) > len(m):
            log.warning("frame of %d bytes exceeds buffer (%d); dropped", len(frame), len(m))
            self.free.append(idx)
            return
        m[:len(frame)] = frame
        fcntl.ioctl(self.fd, VIDIOC_QBUF, self._buf(idx, len(frame), time.monotonic()))
        self.sent_at = now

    def log_stats(self):
        """Once a minute, say if frames arrived too late for JITTER_MS."""
        now = time.monotonic()
        if now - self.stats_at < 60:
            return
        late = sum(s.late for s in self.stores.values())
        if late:
            log.info("Camera: %d frames missed their slot in the last %d s; raise JITTER_MS"
                     " (now %d) if this keeps happening", late, now - self.stats_at, JITTER_MS)
        for s in self.stores.values():
            s.late = 0
        self.stats_at = now

    def handle_events(self):
        ev = bytearray(136)
        while True:
            try:
                fcntl.ioctl(self.fd, VIDIOC_DQEVENT, ev)
            except OSError as e:
                if e.errno == errno.ENOENT:
                    return
                raise
            etype = struct.unpack_from("<I", ev, 0)[0]
            u = bytes(ev[8:72])
            if etype == UVC_EVENT_SETUP:
                self.on_setup(u[:8])
            elif etype == UVC_EVENT_DATA:
                n = struct.unpack_from("<i", u, 0)[0]
                self.on_data(u[4:4 + max(0, n)])
            elif etype == UVC_EVENT_STREAMON:
                self.stream_on()
            elif etype == UVC_EVENT_STREAMOFF:
                self.stream_off()
            elif etype == UVC_EVENT_CONNECT:
                log.info("Host connected")
            elif etype == UVC_EVENT_DISCONNECT:
                log.info("Host disconnected")
                self.stream_off()

    def run(self):
        # select(), not poll(): the gadget reports POLLERR whenever it isn't
        # streaming, which poll() always returns but select()'s except-set
        # (POLLPRI only) ignores.
        while True:
            writers = [self.fd] if self.streaming else []
            timeout = 1 / (MODES[self.mode].fps * 2)
            due = self.stores[MODES[self.mode].source].next_due()
            if self.streaming and self.live and self.free and due is not None:
                # Wake when the next frame is due. With no free buffer, the
                # gadget handing one back wakes us instead.
                timeout = min(timeout, max(0.0, due - time.monotonic()))
            select.select([], writers, [self.fd], timeout)
            self.handle_events()
            self.pump()
            self.log_stats()


def main():
    sources = {m.source: m for m in MODES.values()}
    placeholders = {name: make_placeholder(m) for name, m in sources.items()}
    decoder = Decoder({name: FrameStore(m) for name, m in sources.items()})
    threading.Thread(target=audio_sink_loop, daemon=True).start()
    threading.Thread(target=decoder.run, daemon=True).start()
    log.info("Listening for the Mac stream on udp://0.0.0.0:%d", PORT)
    UvcCamera(find_uvc_node(), decoder, placeholders).run()


if __name__ == "__main__":
    main()
