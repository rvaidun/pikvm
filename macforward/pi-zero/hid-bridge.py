#!/usr/bin/env python3
"""TCP -> USB HID bridge for the Pi Zero.

Drop-in replacement for the Pico HID emulator. Listens on TCP 8081,
accepts the same newline-terminated ASCII protocol used by pi/bridge.py,
and writes HID reports to the gadget char devices created by
setup-gadget.sh (hid.usb0 = keyboard, hid.usb1 = mouse).

Protocol (identical to pico/code.py):
  kd <keycode>     Key down   (USB HID usage ID, decimal; 224..231 = modifiers)
  ku <keycode>     Key up
  krel             Release all keys
  mm <dx> <dy>     Mouse move (relative, each -127..127)
  md <buttons>     Mouse buttons down bitmask (1=L, 2=R, 4=M)
  mu <buttons>     Mouse buttons up bitmask
  mw <delta>       Mouse wheel (int8, negative = down)
  ping             Replies "pong\n"

Env vars:
  HID_HOST   Bind host (default 0.0.0.0)
  HID_PORT   Bind port (default 8081)
  HID_KBD    Keyboard device (default /dev/hidg0)
  HID_MOUSE  Mouse device    (default /dev/hidg1)
"""
import asyncio
import logging
import os

HID_HOST = os.environ.get("HID_HOST", "0.0.0.0")
HID_PORT = int(os.environ.get("HID_PORT", "8081"))
HID_KBD = os.environ.get("HID_KBD", "/dev/hidg0")
HID_MOUSE = os.environ.get("HID_MOUSE", "/dev/hidg1")

MOD_BITS = {0xE0: 0x01, 0xE1: 0x02, 0xE2: 0x04, 0xE3: 0x08,
            0xE4: 0x10, 0xE5: 0x20, 0xE6: 0x40, 0xE7: 0x80}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("hid")


class Hid:
    def __init__(self, kbd_path, mouse_path):
        self.kbd = open(kbd_path, "wb", buffering=0)
        self.mouse = open(mouse_path, "wb", buffering=0)
        self.pressed = set()   # non-modifier keycodes currently down
        self.mods = 0          # modifier bitmap
        self.buttons = 0       # mouse button bitmap
        self.lock = asyncio.Lock()

    def _kbd_report(self):
        keys = list(self.pressed)[:6]
        keys += [0] * (6 - len(keys))
        return bytes([self.mods, 0, *keys])

    def _mouse_report(self, dx=0, dy=0, wheel=0):
        def clamp(v):
            return max(-127, min(127, int(v))) & 0xFF
        return bytes([self.buttons & 0x07, clamp(dx), clamp(dy), clamp(wheel)])

    async def _write(self, dev, data):
        async with self.lock:
            try:
                dev.write(data)
            except BlockingIOError:
                # hidg buffer full — drop; host hasn't drained
                log.warning("hidg write would block, dropping report")

    async def key_down(self, k):
        if k in MOD_BITS:
            self.mods |= MOD_BITS[k]
        else:
            self.pressed.add(k & 0xFF)
        await self._write(self.kbd, self._kbd_report())

    async def key_up(self, k):
        if k in MOD_BITS:
            self.mods &= ~MOD_BITS[k]
        else:
            self.pressed.discard(k & 0xFF)
        await self._write(self.kbd, self._kbd_report())

    async def release_all(self):
        self.pressed.clear()
        self.mods = 0
        self.buttons = 0
        await self._write(self.kbd, self._kbd_report())
        await self._write(self.mouse, self._mouse_report())

    async def mouse_move(self, dx, dy):
        await self._write(self.mouse, self._mouse_report(dx=dx, dy=dy))

    async def mouse_down(self, b):
        self.buttons |= b & 0x07
        await self._write(self.mouse, self._mouse_report())

    async def mouse_up(self, b):
        self.buttons &= ~(b & 0x07)
        await self._write(self.mouse, self._mouse_report())

    async def mouse_wheel(self, w):
        await self._write(self.mouse, self._mouse_report(wheel=w))


async def handle_client(reader, writer, hid):
    peer = writer.get_extra_info("peername")
    log.info("client connected: %s", peer)
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            parts = line.decode("ascii", "replace").strip().split()
            if not parts:
                continue
            cmd = parts[0]
            try:
                if cmd == "kd":
                    await hid.key_down(int(parts[1]))
                elif cmd == "ku":
                    await hid.key_up(int(parts[1]))
                elif cmd == "krel":
                    await hid.release_all()
                elif cmd == "mm":
                    await hid.mouse_move(int(parts[1]), int(parts[2]))
                elif cmd == "md":
                    await hid.mouse_down(int(parts[1]))
                elif cmd == "mu":
                    await hid.mouse_up(int(parts[1]))
                elif cmd == "mw":
                    await hid.mouse_wheel(int(parts[1]))
                elif cmd == "ping":
                    writer.write(b"pong\n")
                    await writer.drain()
                else:
                    log.warning("unknown cmd: %r", parts)
            except (IndexError, ValueError) as e:
                log.warning("bad line %r: %s", line, e)
    except ConnectionResetError:
        pass
    finally:
        await hid.release_all()
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass
        log.info("client disconnected: %s", peer)


async def main():
    hid = Hid(HID_KBD, HID_MOUSE)
    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, hid), HID_HOST, HID_PORT
    )
    sockets = ", ".join(str(s.getsockname()) for s in server.sockets)
    log.info("hid-bridge listening on %s (kbd=%s mouse=%s)", sockets, HID_KBD, HID_MOUSE)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
