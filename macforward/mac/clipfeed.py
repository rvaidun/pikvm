#!/usr/bin/env python3
"""Feed forward.sh's clip input: the base clip on a loop, with one-shot clips
played over it on request, as video and the clips' own audio in step.

    clipfeed.py WIDTH HEIGHT FPS CONTROL STATE AUDIO BASE [CLIP ...]

Writes raw yuv420p WIDTHxHEIGHT frames to stdout at FPS, and the clip's
audio as raw s16le 48 kHz stereo to the AUDIO FIFO, forever. Each clip is
decoded by its own ffmpeg, scaled and cropped to the output size. Lines read
from the CONTROL FIFO:

    play N [HOLD]
             play CLIP number N (1-based) once from its first frame, then
             go back to the base clip where it left off. HOLD repeats the
             first frame for that many extra frames, to cover the delay
             before ffmpeg shows the clip input when switching from live.
    stop     abandon the clip that's playing and go back to the base clip

The current source ("base" or "clip N") is written to the STATE file
whenever it changes, for forward.sh's status line.

Audio is taken frame by frame with the video: every frame written takes the
next 1/FPS s of that clip's audio, so the two can't drift. A clip without
audio (or one whose audio ends first) is silent; audio left over when the
video ends is dropped. A repeated frame (a held first frame, or a decoder
running behind) gets silence, so the audio never runs ahead of the picture.

A decoder for every clip is started up front and holds its first frames, so
a clip starts on the next frame after "play"; once it has played, a fresh
decoder is started for next time (replaying a clip at once waits a few
frames for it). The base clip loops the same way: the next pass is primed
while this one plays, and each pass restarts its audio with its video. If a
decoder ever falls behind, the last frame is repeated so the output never
stalls (the main ffmpeg's streamselect would stall the camera with it).
"""

import os
import queue
import subprocess
import sys
import threading
import time

W, H, FPS = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
CONTROL, STATE, AUDIO, BASE = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
CLIPS = sys.argv[8:]
FRAME = W * H * 3 // 2
RATE, BYTES_PER_SAMPLE = 48000, 4          # s16le stereo
FIT = (f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},"
       f"setsar=1,fps={FPS},format=yuv420p")

_has_audio = {}


def has_audio(path):
    if path not in _has_audio:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=codec_type", "-of", "csv=p=0", path],
            capture_output=True, text=True)
        _has_audio[path] = "audio" in r.stdout
    return _has_audio[path]


class Decoder:
    """An ffmpeg decoding one pass of a file: frames into a small queue
    (None marks the end), and its audio, if any, into a byte buffer."""

    AUDIO_MAX = RATE * BYTES_PER_SAMPLE * 4    # 4 s ahead is plenty

    def __init__(self, path):
        self.audio = has_audio(path)
        cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
               "-i", path, "-map", "0:v:0", "-vf", FIT, "-f", "rawvideo",
               "-pix_fmt", "yuv420p", "pipe:1"]
        fds = ()
        if self.audio:
            ar, aw = os.pipe()
            cmd += ["-map", "0:a:0", "-ar", str(RATE), "-ac", "2",
                    "-f", "s16le", f"pipe:{aw}"]
            fds = (aw,)
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, pass_fds=fds)
        self.frames = queue.Queue(maxsize=8)
        threading.Thread(target=self._read, daemon=True).start()
        self.abuf = bytearray()
        self.aended = not self.audio
        self.alock = threading.Condition()
        if self.audio:
            os.close(aw)
            threading.Thread(target=self._read_audio, args=(ar,),
                             daemon=True).start()

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

    def _read_audio(self, fd):
        with os.fdopen(fd, "rb", buffering=0) as f:
            while True:
                chunk = f.read(65536)
                with self.alock:
                    if not chunk:
                        self.aended = True
                        self.alock.notify_all()
                        return
                    while len(self.abuf) > self.AUDIO_MAX:
                        self.alock.wait()
                    self.abuf += chunk
                    self.alock.notify_all()

    def next(self):
        """The next frame, False if none is ready yet, None at the end."""
        try:
            return self.frames.get_nowait()
        except queue.Empty:
            return False

    def take_audio(self, nbytes):
        """The audio that goes with the frame just taken, padded with
        silence if it isn't there (yet, or at all)."""
        with self.alock:
            deadline = time.monotonic() + 0.02
            while len(self.abuf) < nbytes and not self.aended:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.alock.wait(left)
            out = bytes(self.abuf[:nbytes])
            del self.abuf[:nbytes]
            self.alock.notify_all()
        return out + bytes(nbytes - len(out))

    def close(self):
        self.proc.kill()
        self.proc.wait()
        with self.alock:   # unblock the audio reader so it can see EOF
            self.abuf.clear()
            self.alock.notify_all()


class Writer:
    """Writes one output from its own thread. ffmpeg reads its inputs in
    timestamp order: it stops reading the video while it waits for the
    audio to catch up (and the other way round), so a single thread that
    blocked writing one would never get to write the other. Opening the
    audio FIFO also blocks until ffmpeg opens it, which it may not do until
    it has read video; the audio queues up meanwhile, in step with the
    frames."""

    def __init__(self, path=None, f=None):
        self.q = queue.Queue()
        threading.Thread(target=self._run, args=(path, f), daemon=True).start()

    def _run(self, path, f):
        try:
            if f is None:
                f = open(path, "wb", buffering=0)
            while True:
                f.write(self.q.get())
                f.flush()
        except (BrokenPipeError, OSError):
            os._exit(0)            # the main ffmpeg is gone

    def write(self, data):
        self.q.put(data)

    def backlog(self):
        return self.q.qsize()


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
    base = Decoder(BASE)
    base_next = Decoder(BASE)             # the next pass of the loop, primed
    ready = [Decoder(p) for p in CLIPS]   # primed decoder per clip
    playing = None                        # (index, Decoder) or None
    hold = 0                              # frames left to hold the first one
    started = False                       # has the clip's first frame shown
    threading.Thread(target=read_control, daemon=True).start()
    write_state("base")
    video_out = Writer(f=sys.stdout.buffer)
    audio_out = Writer(AUDIO)

    # Don't start the clock until the base clip has a frame to show.
    last = base.frames.get()
    period = 1.0 / FPS
    t = time.monotonic()
    n = 0                                 # frames written

    def finish():
        nonlocal playing, hold
        hold = 0
        i, dec = playing
        dec.close()
        ready[i] = Decoder(CLIPS[i])
        playing = None
        write_state("base")

    first = True
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

        # Samples for this frame; exact over time even if FPS doesn't
        # divide 48000.
        nbytes = ((n + 1) * RATE // FPS - n * RATE // FPS) * BYTES_PER_SAMPLE
        frame, src = False, None
        if first:                  # the base frame already taken above
            frame, src, first = last, base, False
        elif playing and started and hold:
            hold -= 1
            frame = last           # a repeat: silence
        elif playing:
            # Until the clip's decoder has a frame (only a clip replayed
            # straight away has to wait), the last frame repeats.
            frame = playing[1].next()
            if frame is None:      # clip over: back to the base clip
                finish()
                frame = False
            elif frame:
                started = True
                src = playing[1]
        if not playing and frame is False:
            frame = base.next()
            if frame is None:      # end of this pass: on to the primed next
                base.close()
                base, base_next = base_next, Decoder(BASE)
                frame = base.next()
            if frame:
                src = base
        if frame:
            last = frame

        sound = src.take_audio(nbytes) if src else bytes(nbytes)
        # If ffmpeg stops reading (it never should for long), drop frames
        # rather than queue them without end; video and audio go together,
        # so they stay in step.
        if video_out.backlog() < 2 * FPS:
            video_out.write(last)
            audio_out.write(sound)
        n += 1

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
