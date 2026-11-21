#!/usr/bin/env python3
"""Make the two bass sync calibration videos (black picture, a click and a 50 Hz thump).

The click (2 kHz, 12 ms) has nothing below the sub's 120 Hz low-pass, so it is heard only on the
headset or TV. The thump (50 Hz, decaying) is what the sub plays. Both are in both stereo
channels, so the app's bass tap picks the thump up like any film soundtrack.

  bass-sync-sweep.mp4   The thump comes N ms before the click, N = 0 to 300 in steps of 20, four
                        beats per step, N on screen. With Bass lead and Receiver delay at 0, the
                        step where click and thump land together is your Bass lead.
  bass-sync-steady.mp4  Click and thump at the same instant, once a second, to check the result.

Needs numpy and an ffmpeg with libx264, AAC and drawtext on the PATH.

  python3 tools/make_bass_sync_videos.py --out ~/Videos/BassPlayerCalibration
"""
import argparse
import os
import subprocess
import tempfile
import wave

import numpy as np

SR = 48000
FONTS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]


def click():
    n = int(0.012 * SR)
    t = np.arange(n) / SR
    return 0.6 * np.sin(2 * np.pi * 2000 * t) * np.hanning(n)


def thump():
    # Starts at zero phase with a 4 ms fade-in, so it makes no click of its own; decays over ~80 ms.
    n = int(0.10 * SR)
    t = np.arange(n) / SR
    env = np.minimum(t / 0.004, 1.0) * np.exp(-t / 0.035)
    tail = int(0.01 * SR)
    env[-tail:] *= np.linspace(1, 0, tail)
    return 0.9 * np.sin(2 * np.pi * 50 * t) * env


def add(buf, sig, at):
    i = int(round(at * SR))
    buf[i:i + len(sig)] += sig


def write_wav(path, buf):
    pcm = (np.clip(buf, -1, 1) * 32767).astype("<i2")
    stereo = np.repeat(pcm[:, None], 2, axis=1)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(stereo.tobytes())


def escape(s):
    return s.replace(":", "\\:").replace(",", "\\,").replace("'", "’")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=".", help="folder for the two .mp4 files (default: current folder)")
    ap.add_argument("--font", help="a bold TrueType font for the on-screen text")
    args = ap.parse_args()

    font = args.font or next((f for f in FONTS if os.path.exists(f)), None)
    if not font:
        ap.error("no font found; pass one with --font /path/to/font.ttf")
    out_dir = os.path.expanduser(args.out)
    os.makedirs(out_dir, exist_ok=True)

    def text(s, size, y, start=None, end=None):
        f = (f"drawtext=fontfile='{escape(font)}':text='{escape(s)}':fontcolor=white:"
             f"fontsize={size}:x=(w-text_w)/2:y={y}")
        if start is not None:
            f += f":enable='between(t,{start},{end - 0.001})'"
        return f

    def encode(name, buf, dur, filters):
        out = os.path.join(out_dir, name)
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "audio.wav")
            write_wav(wav, buf[:int(dur * SR)])
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-f", "lavfi", "-i", f"color=c=black:s=1920x1080:r=60:d={dur}", "-i", wav,
                 "-vf", ",".join(filters),
                 "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-g", "60",
                 "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", out],
                check=True)
        print(out)

    # Sweep: the thump comes N ms before the click; N is on screen.
    intro, beats, steps = 6, 4, list(range(0, 301, 20))
    end = intro + len(steps) * beats
    dur = end + 2
    buf = np.zeros(int(dur * SR) + SR)
    filters = [
        text("Bass sync sweep", 64, 120),
        text("Set Bass lead to 0 first. Each step plays four beats.", 40, 860),
        text("Remember the number where click and thump land together. That is your Bass lead.", 40, 920),
        text("Starting…", 120, 430, 0, intro),
        text("End", 120, 430, end, dur),
    ]
    for i, n in enumerate(steps):
        start = intro + i * beats
        filters.append(text(f"Thump {n} ms early", 120, 430, start, start + beats))
        for j in range(beats):
            at = start + 0.5 + j
            add(buf, click(), at)
            add(buf, thump(), at - n / 1000)
    # A white square flashes for 50 ms at each click.
    filters.append("drawbox=x=(iw-240)/2:y=640:w=240:h=120:color=white:t=fill:"
                   f"enable='gte(t,{intro})*lt(t,{end})*lt(mod(t+0.5,1),0.05)'")
    encode("bass-sync-sweep.mp4", buf, dur, filters)

    # Steady: click and thump at the same instant, once a second.
    dur = 92
    buf = np.zeros(int(dur * SR) + SR)
    for k in range(2, dur - 2):
        add(buf, click(), k + 0.5)
        add(buf, thump(), k + 0.5)
    filters = [
        text("Bass sync check", 64, 120),
        text("Click and thump are at the same instant in this file.", 40, 860),
        text("Thump after the click: raise Bass lead. Thump before: raise Receiver delay.", 40, 920),
        "drawbox=x=(iw-240)/2:y=480:w=240:h=120:color=white:t=fill:"
        f"enable='gte(t,2)*lt(t,{dur - 2})*lt(mod(t+0.5,1),0.05)'",
    ]
    encode("bass-sync-steady.mp4", buf, dur, filters)


if __name__ == "__main__":
    main()
