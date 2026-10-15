#!/usr/bin/env python3
"""Type on the target through bridge.py's WebSocket (US layout).

Args are actions run in order:
  text:<string>     type a string
  key:<combo>       press a combo, e.g. key:win+r, key:enter, key:ctrl+shift+esc
  click:            left-click where the pointer is
  move:<dx>,<dy>    move the pointer by a relative amount
  sleep:<seconds>   pause

  python3 kvmtype.py key:win+r sleep:1 "text:notepad" key:enter
"""
import asyncio
import sys

import aiohttp

URL = "ws://127.0.0.1:8082/ws"   # bridge.py; run this on the Pi

KEYS = {"enter": 0x28, "esc": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "f5": 0x3E, "f12": 0x45, "delete": 0x4C, "right": 0x4F, "left": 0x50,
        "down": 0x51, "up": 0x52, "home": 0x4A, "end": 0x4D}
MODS = {"ctrl": 0xE0, "shift": 0xE1, "alt": 0xE2, "win": 0xE3}
for i, c in enumerate("abcdefghijklmnopqrstuvwxyz"):
    KEYS[c] = 0x04 + i
for i, c in enumerate("1234567890"):
    KEYS[c] = 0x1E + i
for i in range(1, 13):
    KEYS[f"f{i}"] = 0x3A + i - 1

PLAIN = {"-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "\\": 0x31, ";": 0x33,
         "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38, " ": 0x2C}
SHIFTED = {"_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33,
           '"': 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
           "!": 0x1E, "@": 0x1F, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23,
           "&": 0x24, "*": 0x25, "(": 0x26, ")": 0x27}


def char_codes(ch):
    if ch.isalpha():
        return KEYS[ch.lower()], ch.isupper()
    if ch.isdigit():
        return KEYS[ch], False
    if ch in PLAIN:
        return PLAIN[ch], False
    if ch in SHIFTED:
        return SHIFTED[ch], True
    raise ValueError(f"can't type {ch!r}")


async def tap(ws, codes):
    for c in codes:
        await ws.send_str(f"kd {c}")
        await asyncio.sleep(0.01)
    await asyncio.sleep(0.02)
    for c in reversed(codes):
        await ws.send_str(f"ku {c}")
        await asyncio.sleep(0.01)
    await asyncio.sleep(0.02)


async def main(actions):
    async with aiohttp.ClientSession() as s, s.ws_connect(URL) as ws:
        for a in actions:
            kind, _, arg = a.partition(":")
            if kind == "text":
                for ch in arg:
                    code, shift = char_codes(ch)
                    await tap(ws, [MODS["shift"], code] if shift else [code])
            elif kind == "key":
                parts = arg.lower().split("+")
                await tap(ws, [MODS[p] if p in MODS else KEYS[p] for p in parts])
            elif kind == "click":
                await ws.send_str("md 1")
                await asyncio.sleep(0.05)
                await ws.send_str("mu 1")
            elif kind == "move":     # move:dx,dy in relative mickeys
                dx, dy = (int(v) for v in arg.split(","))
                while dx or dy:
                    sx, sy = max(-100, min(100, dx)), max(-100, min(100, dy))
                    await ws.send_str(f"mm {sx} {sy}")
                    dx, dy = dx - sx, dy - sy
                    await asyncio.sleep(0.01)
            elif kind == "sleep":
                await asyncio.sleep(float(arg))
        await ws.send_str("krel")
        await asyncio.sleep(0.1)


asyncio.run(main(sys.argv[1:]))
