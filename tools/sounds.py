#!/usr/bin/env python3
"""Synthesise RareNet's own alert sounds (original, no third-party audio).

Writes RareNet/Media/<name>.ogg via ffmpeg:
  sonar   - radar ping with a soft echo (the RareNet sound)
  chime   - rising three-note bell
  horn    - short low horn call
"""
import os
import subprocess
import tempfile
import wave

import numpy as np

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "RareNet", "Media")


def env(n, attack, decay):
    t = np.arange(n) / RATE
    a = np.clip(t / attack, 0, 1)
    return a * np.exp(-t / decay)


def bell(freq, dur, decay=0.35, partials=((1, 1.0), (2.76, 0.4), (5.4, 0.15))):
    n = int(dur * RATE)
    t = np.arange(n) / RATE
    tone = sum(amp * np.sin(2 * np.pi * freq * mult * t) for mult, amp in partials)
    return tone * env(n, 0.004, decay)


def place(buf, sound, at):
    i = int(at * RATE)
    buf[i:i + len(sound)] += sound[: len(buf) - i]


def sonar():
    buf = np.zeros(int(1.6 * RATE))
    ping = bell(1250, 1.2, decay=0.28, partials=((1, 1.0), (2.0, 0.12)))
    n = len(ping)
    sweep = np.sin(2 * np.pi * np.cumsum(np.linspace(1500, 1100, n)) / RATE) * env(n, 0.003, 0.25)
    place(buf, 0.6 * ping + 0.4 * sweep, 0.0)
    place(buf, 0.25 * ping, 0.38)      # echo
    place(buf, 0.10 * ping, 0.76)
    return buf


def chime():
    buf = np.zeros(int(1.5 * RATE))
    for k, f in enumerate((784, 988, 1319)):       # G5, B5, E6
        place(buf, bell(f, 1.0, decay=0.4), k * 0.11)
    return buf


def horn():
    n = int(0.9 * RATE)
    t = np.arange(n) / RATE
    f = 196 * (1 + 0.012 * np.sin(2 * np.pi * 5.5 * t))         # G3 with vibrato
    phase = 2 * np.pi * np.cumsum(f) / RATE
    tone = sum(np.sin(k * phase) / k ** 1.1 for k in range(1, 9))
    shape = np.clip(t / 0.06, 0, 1) * np.clip((0.9 - t) / 0.2, 0, 1)
    return tone * shape


def write(name, data):
    data = data / (np.max(np.abs(data)) + 1e-9) * 0.85
    pcm = (data * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = tmp.name
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    out = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c:a", "libvorbis", "-q:a", "5", out], check=True)
    os.remove(path)
    print(out)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    write("sonar", sonar())
    write("chime", chime())
    write("horn", horn())
