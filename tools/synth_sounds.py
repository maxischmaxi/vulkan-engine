#!/usr/bin/env python3
"""Generates the grenade sounds into sounds/grenades/.

Every other sound in this project is curated out of a CC0 pack by
fetch_sounds.sh. These are not, for a plain reason: none of the packs it fetches
contains an explosion. kenney_impact has punches, metal and glass; the firearm
library has muzzles and shell casings; there is nothing anywhere in them that a
grenade could borrow.

So they are built. That turns out to be the better deal anyway -- an explosion
is three layered gestures with a handful of numbers each (how deep the thump,
how long the tail, how bright the crack), and having those numbers in a file
beats hunting for a recording that happens to be the right length.

Everything is shaped in the frequency domain rather than with running filters:
one rfft, one magnitude curve, one irfft. A time-varying filter would sound
better on the sweep, but at these lengths the envelope carries the gesture and
the filter only has to set the colour.

    python3 tools/synth_sounds.py

Needs numpy and ffmpeg, both of which the texture and model steps already
assume.
"""

import math
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 48000
OUT = Path(__file__).resolve().parent.parent / "sounds" / "grenades"


# ------------------------------------------------------------------ building


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def noise(seconds, seed):
    return np.random.default_rng(seed).standard_normal(int(SR * seconds))


def lowpass(x, cutoff, order=2):
    """Spectral one-pole to the given order. Gentle -- a brick wall rings."""
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1 / SR)
    with np.errstate(divide="ignore"):
        gain = 1.0 / (1.0 + (freqs / cutoff) ** order)
    return np.fft.irfft(spectrum * gain, len(x))


def highpass(x, cutoff, order=2):
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1 / SR)
    ratio = (freqs / cutoff) ** order
    return np.fft.irfft(spectrum * (ratio / (1.0 + ratio)), len(x))


def env(seconds, attack, decay, curve=1.0):
    """Attack then exponential decay, both in seconds."""
    t = t_axis(seconds)
    rise = 1.0 - np.exp(-t / max(attack, 1e-5))
    fall = np.exp(-t / max(decay, 1e-5)) ** curve
    return rise * fall


def sweep(seconds, f_from, f_to, decay):
    """A sine gliding down. The body of anything that goes bang."""
    t = t_axis(seconds)
    # Exponential glide, integrated to phase so there is no discontinuity.
    k = math.log(f_to / f_from) / seconds
    phase = 2 * math.pi * f_from * (np.exp(k * t) - 1) / k
    return np.sin(phase) * np.exp(-t / decay)


def pad_to(x, seconds):
    n = int(SR * seconds)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def mix(*layers):
    length = max(len(l) for l in layers)
    out = np.zeros(length)
    for l in layers:
        out[: len(l)] += l
    return out


def finish(x, peak=0.92):
    """Soft-clip and normalise. tanh rather than a hard limit: an explosion is
    supposed to be driven, and clipping it squarely adds a buzz that reads as a
    broken file rather than as loudness."""
    x = np.tanh(x * 1.4)
    top = np.max(np.abs(x))
    if top > 0:
        x = x / top * peak
    # A short fade at both ends: a sample that starts or stops on a non-zero
    # value clicks, and the click is the loudest thing in a quiet sound.
    fade = int(SR * 0.004)
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    return x


# ------------------------------------------------------------------- writing


def write_ogg(x, name):
    OUT.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(x, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = Path(tmp.name)
    with wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)  # mono: miniaudio can only spatialise a mono source
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    target = OUT / name
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path),
         "-c:a", "libvorbis", "-q:a", "5", str(target)],
        check=True,
    )
    wav_path.unlink()
    print(f"  {target.relative_to(OUT.parent.parent)}  {len(x) / SR:.2f}s")


# ------------------------------------------------------------------- sounds


def explosion(seed):
    """Three gestures: the crack that arrives, the thump that lands, the tail
    that rolls away. The tail is the longest by far -- what makes a bang read as
    big is not its peak, it is how long the room keeps talking about it."""
    crack = lowpass(noise(0.35, seed), 5200) * env(0.35, 0.0008, 0.055)
    body = sweep(1.2, 95, 32, 0.30) * 1.5
    thud = lowpass(noise(1.2, seed + 1), 260) * env(1.2, 0.004, 0.28)
    tail = lowpass(noise(1.9, seed + 2), 900, order=1) * env(1.9, 0.05, 0.55) * 0.55

    return finish(mix(crack * 0.9, pad_to(body, 1.9), pad_to(thud, 1.9), tail))


def flash_pop(seed):
    """Almost all attack. A flashbang is a charge with no casing to speak of, so
    there is no low end to it at all -- and keeping it out is what stops it
    sounding like a small HE."""
    snap = highpass(noise(0.25, seed), 900) * env(0.25, 0.0004, 0.035)

    # A little metal on top: the canister itself, two partials that ring off.
    t = t_axis(0.25)
    ring = (
        np.sin(2 * math.pi * 3100 * t) * np.exp(-t / 0.045)
        + np.sin(2 * math.pi * 4700 * t) * np.exp(-t / 0.030) * 0.6
    ) * 0.22

    return finish(mix(snap * 1.2, ring))


def flash_ring():
    """The tinnitus after one catches you. Not a sound in the world -- it plays
    flat and local -- so it is a pure tone with just enough movement in it to
    stop the ear filing it away as a test signal."""
    seconds = 3.4
    t = t_axis(seconds)

    vibrato = np.sin(2 * math.pi * 0.7 * t) * 6.0
    tone = np.sin(2 * math.pi * (4180 + vibrato) * t)
    tone += np.sin(2 * math.pi * 6350 * t) * 0.35
    tone += np.sin(2 * math.pi * 2740 * t) * 0.18

    # In fast, out over the whole length: it should be at full strength before
    # the white on screen has finished, and gone by the time vision is back.
    shape = (1.0 - np.exp(-t / 0.04)) * np.exp(-t / 1.5)
    return finish(tone * shape, peak=0.7)


def smoke_hiss():
    """A canister venting: band-passed noise that opens fast and runs down over
    the bloom. Deliberately unpitched -- anything tonal here reads as a leak in
    a pipe rather than as a grenade."""
    seconds = 1.8
    x = highpass(lowpass(noise(seconds, 91), 6000), 1400)
    shape = env(seconds, 0.03, 0.75)
    # A slow wobble, so it breathes instead of sitting there as flat noise.
    t = t_axis(seconds)
    shape *= 0.75 + 0.25 * np.sin(2 * math.pi * 3.1 * t)
    return finish(x * shape, peak=0.8)


def fire_start():
    """Glass, then the pool catching: a bright shatter over a broad whoosh."""
    shatter = highpass(noise(0.35, 77), 2600) * env(0.35, 0.0006, 0.05)
    whoosh = lowpass(noise(0.9, 78), 1800) * env(0.9, 0.05, 0.30)
    body = sweep(0.9, 180, 60, 0.22) * 0.5
    return finish(mix(shatter, whoosh * 1.1, pad_to(body, 0.9)))


def main():
    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg not found -- needed to encode the ogg files")

    print(f"grenade sounds -> {OUT}")
    for i, seed in enumerate((11, 29, 53), start=1):
        write_ogg(explosion(seed), f"explosion_{i:02d}.ogg")
    for i, seed in enumerate((61, 83), start=1):
        write_ogg(flash_pop(seed), f"flash_pop_{i:02d}.ogg")
    write_ogg(flash_ring(), "flash_ring.ogg")
    write_ogg(smoke_hiss(), "smoke_hiss.ogg")
    write_ogg(fire_start(), "fire_start.ogg")


if __name__ == "__main__":
    main()
