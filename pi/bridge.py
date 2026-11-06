#!/usr/bin/env python3
"""KVM web bridge.

Serves a web UI that captures keyboard/mouse events and forwards them
over WebSocket -> raw HID reports written to the Pi 4's USB gadget
endpoints (/dev/hidg0 keyboard, /dev/hidg1 mouse).

Env vars:
  HIDG_KBD     Keyboard HID device   (default /dev/hidg0)
  HIDG_MOUSE   Mouse HID device      (default /dev/hidg1)
  LISTEN       Bind host:port        (default 0.0.0.0:8082)

Wire protocol (unchanged from the Pico era, newline-terminated ASCII):
  kd <keycode>   kbd key down (USB HID usage ID, decimal)
  ku <keycode>   kbd key up
  krel           release all keys
  mm <dx> <dy>   mouse move, int8 each
  md <buttons>   mouse button down bitmask (1=L, 2=R, 4=M)
  mu <buttons>   mouse button up bitmask
  mw <delta>     wheel, int8
  ping           no-op (kept for parity)
"""
import asyncio
import errno
import logging
import os
import time
from pathlib import Path

from aiohttp import WSMsgType, web

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("kvm")

HIDG_KBD = os.environ.get("HIDG_KBD", "/dev/hidg0")
HIDG_MOUSE = os.environ.get("HIDG_MOUSE", "/dev/hidg1")
LISTEN = os.environ.get("LISTEN", "0.0.0.0:8082")
STATIC_DIR = Path(__file__).parent / "static"

# HID usage IDs 0xE0..0xE7 are modifier keys. Their position in that range
# is also their bit position in the keyboard report's modifier byte.
MOD_FIRST, MOD_LAST = 0xE0, 0xE7


class Waker:
    """Wakes a sleeping target the way a real keyboard does: USB remote wakeup,
    sent by the dwc2_wakeup module (pi/kernel/dwc2_wakeup). Called when the host
    stops polling, i.e. it has suspended the bus. The write blocks for up to
    ~0.5 s in the kernel, so it runs in a thread and at most every RETRY_S."""

    PATH = os.environ.get("WAKE_PATH", "/sys/module/dwc2_wakeup/parameters/wake")
    RETRY_S = 3.0

    def __init__(self):
        self.last = 0.0
        self.task: asyncio.Task | None = None
        self.warned = False

    def kick(self):
        now = time.monotonic()
        if (self.task and not self.task.done()) or now - self.last < self.RETRY_S:
            return
        self.last = now
        self.task = asyncio.get_running_loop().create_task(asyncio.to_thread(self._wake))

    def _wake(self):
        try:
            fd = os.open(self.PATH, os.O_WRONLY)
            try:
                os.write(fd, b"1")
            finally:
                os.close(fd)
            log.info("target was asleep; sent USB remote wakeup")
        except OSError as e:
            if e.errno == errno.EALREADY:
                pass  # bus is awake; the host is just slow to poll
            elif e.errno == errno.ETIMEDOUT:
                log.warning("sent USB remote wakeup, but the target didn't resume (off or hibernating?)")
            elif not self.warned:
                self.warned = True
                log.warning("can't wake the target via %s: %s", self.PATH, e)


waker = Waker()


class HidWriter:
    """Owns an open fd to a /dev/hidg* endpoint. Reopens on EIO/ENODEV/ESHUTDOWN
    (host port cycled, gadget rebound)."""

    # f_hid holds one report in flight; a non-blocking write returns EAGAIN
    # until the host has polled the previous one (every ~1 ms when healthy).
    # Retry briefly instead of dropping it, so a fast key-up isn't lost.
    BUSY_RETRY_S = 0.002
    BUSY_TIMEOUT_S = 0.25

    def __init__(self, path: str, report_len: int):
        self.path = path
        self.report_len = report_len
        self.fd: int | None = None
        self.lock = asyncio.Lock()

    def _open(self):
        self.fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
        log.info("HID endpoint opened: %s", self.path)

    def _close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = None

    async def write(self, report: bytes):
        assert len(report) == self.report_len, (len(report), self.report_len)
        async with self.lock:
            for _ in range(2):
                if self.fd is None:
                    try:
                        self._open()
                    except OSError as e:
                        log.warning("open %s failed: %s", self.path, e)
                        return
                deadline = time.monotonic() + self.BUSY_TIMEOUT_S
                try:
                    while True:
                        try:
                            os.write(self.fd, report)
                            return
                        except BlockingIOError:
                            if time.monotonic() > deadline:
                                log.warning("%s: host isn't polling; dropped report", self.path)
                                waker.kick()
                                return
                            await asyncio.sleep(self.BUSY_RETRY_S)
                except OSError as e:
                    log.warning("write %s failed: %s — reopening", self.path, e)
                    self._close()


class Keyboard:
    """Maintains the 8-byte boot keyboard report state."""

    def __init__(self, writer: HidWriter):
        self.w = writer
        self.modifiers = 0            # byte 0 bitmask
        self.keys: list[int] = []     # up to 6 non-modifier HID codes

    def _report(self) -> bytes:
        buf = bytearray(8)
        buf[0] = self.modifiers
        for i, k in enumerate(self.keys[:6]):
            buf[2 + i] = k
        return bytes(buf)

    async def down(self, code: int):
        if MOD_FIRST <= code <= MOD_LAST:
            self.modifiers |= 1 << (code - MOD_FIRST)
        elif code not in self.keys and len(self.keys) < 6:
            self.keys.append(code)
        await self.w.write(self._report())

    async def up(self, code: int):
        if MOD_FIRST <= code <= MOD_LAST:
            self.modifiers &= ~(1 << (code - MOD_FIRST))
        elif code in self.keys:
            self.keys.remove(code)
        await self.w.write(self._report())

    async def release_all(self):
        self.modifiers = 0
        self.keys.clear()
        await self.w.write(self._report())


class MouseState:
    """Maintains the 4-byte mouse report state (buttons sticky, motion/wheel one-shot)."""

    def __init__(self, writer: HidWriter):
        self.w = writer
        self.buttons = 0

    @staticmethod
    def _clamp(v: int) -> int:
        return max(-127, min(127, v)) & 0xFF  # two's complement int8

    async def _send(self, dx: int = 0, dy: int = 0, wheel: int = 0):
        await self.w.write(bytes([self.buttons & 0x07, self._clamp(dx),
                                  self._clamp(dy), self._clamp(wheel)]))

    async def move(self, dx: int, dy: int):
        await self._send(dx=dx, dy=dy)

    async def wheel(self, delta: int):
        await self._send(wheel=delta)

    async def press(self, mask: int):
        self.buttons |= mask & 0x07
        await self._send()

    async def release(self, mask: int):
        self.buttons &= ~(mask & 0x07)
        await self._send()


kbd_w = HidWriter(HIDG_KBD, 8)
mouse_w = HidWriter(HIDG_MOUSE, 4)
kbd = Keyboard(kbd_w)
mouse = MouseState(mouse_w)


async def handle_line(line: str):
    parts = line.strip().split()
    if not parts:
        return
    cmd = parts[0]
    try:
        if cmd == "kd":
            await kbd.down(int(parts[1]))
        elif cmd == "ku":
            await kbd.up(int(parts[1]))
        elif cmd == "krel":
            await kbd.release_all()
        elif cmd == "mm":
            await mouse.move(int(parts[1]), int(parts[2]))
        elif cmd == "md":
            await mouse.press(int(parts[1]))
        elif cmd == "mu":
            await mouse.release(int(parts[1]))
        elif cmd == "mw":
            await mouse.wheel(int(parts[1]))
        elif cmd == "ping":
            pass
    except (ValueError, IndexError) as e:
        log.warning("bad command %r: %s", line, e)


async def ws_handler(request):
    ws = web.WebSocketResponse(heartbeat=10)
    await ws.prepare(request)
    log.info("WS client connected: %s", request.remote)
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                await handle_line(msg.data)
    finally:
        # Safety: release everything when the browser disconnects so a
        # stuck key doesn't leave the target OS typing forever.
        await kbd.release_all()
        await mouse.release(0x07)
        log.info("WS client disconnected")
    return ws


async def index(_request):
    return web.FileResponse(STATIC_DIR / "index.html")


def main():
    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static", STATIC_DIR)

    host, port = LISTEN.rsplit(":", 1)
    web.run_app(app, host=host, port=int(port))


if __name__ == "__main__":
    main()
