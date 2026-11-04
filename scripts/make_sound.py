#!/usr/bin/env python3
"""Writes Resources/Saved.wav: the "da-ding" played when a clip is saved.
Two bell-like notes (E5, then a ringing A5) with harmonics and exponential decay."""
import math
import pathlib
import struct
import wave

RATE = 44_100
OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Saved.wav"


def bell(freq, start, length, decay):
    """(sample offset, samples) for one struck note: fundamental + soft overtones, fast attack."""
    n = int(length * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 0.004) * math.exp(-t / decay)
        v = (math.sin(2 * math.pi * freq * t)
             + 0.45 * math.sin(2 * math.pi * freq * 2 * t)
             + 0.18 * math.sin(2 * math.pi * freq * 3.01 * t))
        out.append(v * env)
    return int(start * RATE), out


notes = [bell(659.25, 0.0, 0.25, 0.07),    # "da"  (E5, short)
         bell(880.00, 0.11, 0.55, 0.16)]   # "ding" (A5, rings out)
total = max(off + len(s) for off, s in notes)
mix = [0.0] * total
for off, s in notes:
    for i, v in enumerate(s):
        mix[off + i] += v
peak = max(abs(v) for v in mix)
fade = int(0.02 * RATE)  # avoid a click at the very end
pcm = b"".join(
    struct.pack("<h", int(v / peak * 0.95 * min(1.0, (total - i) / fade) * 32767))
    for i, v in enumerate(mix))

with wave.open(str(OUT), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(pcm)
print("wrote", OUT, f"{total / RATE:.2f}s")
