#!/usr/bin/env python3
"""Feed forward.sh's clip input: the base clip on a loop, with one-shot clips
played over it on request.

    clipfeed.py WIDTH HEIGHT FPS CONTROL STATE BASE [CLIP ...]

Writes raw yuv420p WIDTHxHEIGHT frames to stdout at FPS, forever. Each clip
is decoded by its own ffmpeg, scaled and cropped to the output size. Lines
read from the CONTROL FIFO:

    play N [HOLD]
             play CLIP number N (1-based) once from its first frame, then
             go back to the base clip where it left off. HOLD repeats the
             first frame for that many extra frames, to cover the delay
             before ffmpeg shows the clip input when switching from live.
    stop     abandon the clip that's playing and go back to the base clip

The current source ("base" or "clip N") is written to the STATE file
whenever it changes, for forward.sh's status line.

A decoder for every clip is started up front and holds its first frames, so
a clip starts on the next frame after "play"; once it has played, a fresh
decoder is started for next time (replaying a clip at once waits a few
frames for it). If a decoder ever falls behind, the last
frame is repeated so the output never stalls (the main ffmpeg's
streamselect would stall the camera with it).
"""

import os
import queue
import subprocess
import sys
import threading
import time

W, H, FPS = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
CONTROL, STATE, BASE = sys.argv[4], sys.argv[5], sys.argv[6]
CLIPS = sys.argv[7:]
FRAME = W * H * 3 // 2
FIT = (f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},"
       f"setsar=1,fps={FPS},format=yuv420p")


class Decoder:
    """An ffmpeg decoding one file into a small queue of frames.
    A None in the queue marks the end of the file."""

    def __init__(self, path, loop=False):
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
        if loop:
            cmd += ["-stream_loop", "-1"]
        cmd += ["-i", path, "-an", "-vf", FIT, "-f", "rawvideo",
                "-pix_fmt", "yuv420p", "-"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        self.frames = queue.Queue(maxsize=8)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        out = self.proc.stdout
        while True:
            buf = bytearray()
            while len(buf) < FRAME:
                chunk = out.read(FRAME - len(buf))
                if not chunk:
                    self.frames.put(None)
                    return
                buf += chunk
            self.frames.put(bytes(buf))

    def next(self):
        """The next frame, False if none is ready yet, None at the end."""
        try:
            return self.frames.get_nowait()
        except queue.Empty:
            return False

    def close(self):
        self.proc.kill()
        self.proc.wait()


commands = queue.Queue()


def read_control():
    while True:  # reopen after every writer closes
        with open(CONTROL) as f:
            for line in f:
                commands.put(line.split())


def write_state(text):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        f.write(text + "\n")
    os.replace(tmp, STATE)


def main():
    base = Decoder(BASE, loop=True)
    ready = [Decoder(p) for p in CLIPS]   # primed decoder per clip
    playing = None                        # (index, Decoder) or None
    hold = 0                              # frames left to hold the first one
    started = False                       # has the clip's first frame shown
    threading.Thread(target=read_control, daemon=True).start()
    write_state("base")

    # Don't start the clock until the base clip has a frame to show.
    last = base.frames.get()
    out = sys.stdout.buffer
    period = 1.0 / FPS
    t = time.monotonic()

    def finish():
        nonlocal playing, hold
        hold = 0
        i, dec = playing
        dec.close()
        ready[i] = Decoder(CLIPS[i])
        playing = None
        write_state("base")

    while True:
        while not commands.empty():
            cmd = commands.get()
            if cmd[:1] == ["stop"] and playing:
                finish()
            elif (cmd[:1] == ["play"] and len(cmd) in (2, 3)
                  and all(c.isdigit() for c in cmd[1:])):
                i = int(cmd[1]) - 1
                if 0 <= i < len(CLIPS):
                    if playing:
                        finish()
                    playing = (i, ready[i])
                    started = False
                    hold = int(cmd[2]) if len(cmd) == 3 else 0
                    write_state(f"clip {i + 1}")

        frame = False
        if playing and started and hold:
            hold -= 1
            frame = last
        elif playing:
            # Until the clip's decoder has a frame (only a clip replayed
            # straight away has to wait), the last frame repeats.
            frame = playing[1].next()
            if frame is None:      # clip over: back to the base clip
                finish()
                frame = False
            elif frame:
                started = True
        if not playing:
            frame = base.next()
            if frame is None:      # a looping decoder never ends; restart it
                base.close()
                base = Decoder(BASE, loop=True)
                frame = False
        if frame:
            last = frame

        out.write(last)
        out.flush()

        t += period
        delay = t - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        elif delay < -0.5:         # fell far behind (e.g. a stall): resync
            t = time.monotonic()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
