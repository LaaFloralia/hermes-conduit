#!/usr/bin/env python3
"""turn_frames.py <work> <id> <clip.mp4> <key colour> <sim> [--reverse] [--despill] [--fill] [--count N]

Key an orbit clip into evenly turned alpha frames and pack them with pack_turn.swift.
Run matte_loop.py first: the turn stands on the same shadow as the loop.
"""
import glob, os, shutil, subprocess, sys
import numpy as np
from PIL import Image
from scipy import ndimage

SIZE, INSET = 768, 699
PAD = (SIZE - INSET) // 2
HERE = os.path.dirname(os.path.abspath(__file__))


def ff(*a):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *a], check=True)


def evenly_turned(src, count):
    w = 270
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", src, "-vf", f"crop=1080:1080:420:0,scale={w}:{w}",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    g = np.frombuffer(raw, np.uint8).reshape(-1, w, w).astype(np.float32)
    step = np.abs(g[1:] - g[:-1]).mean(axis=(1, 2))
    step = np.maximum(step - 0.25, 0.02)  # ignore codec noise while the clip eases in and out
    total = np.concatenate([[0], np.cumsum(step)])
    wanted = np.linspace(0, total[-1], count, endpoint=False)
    return np.searchsorted(total, wanted).clip(0, len(g) - 1).tolist(), step


def clean(path, despill, fill):
    """Clamp the key colour out of the toy, and close keyed-out specks inside a solid toy."""
    a = np.array(Image.open(path).convert("RGBA")).astype(np.float32)
    if despill:
        a[..., 1] = np.minimum(a[..., 1], np.maximum(a[..., 0], a[..., 2]) * 1.02)
    if fill:
        a[..., 3] = np.where(ndimage.binary_fill_holes(a[..., 3] > 128), 255, a[..., 3])
    Image.fromarray(a.astype(np.uint8), "RGBA").save(path)


def build(work, k, src, key, sim, reverse, count, despill, fill):
    out = f"{work}/turn/{k}"
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out + "/all"); os.makedirs(out + "/fg")
    chosen, step = evenly_turned(src, count)
    vf = (f"[0:v]crop=1080:1080:420:0,format=yuva444p,chromakey={key}:{sim}:0.05,split[c][a];"
          "[a]alphaextract,erosion,erosion,erosion,gblur=sigma=1.0[m];"
          f"[c][m]alphamerge,format=rgba,scale={INSET}:{INSET}:flags=lanczos,pad={SIZE}:{SIZE}:{PAD}:{PAD}:color=black@0")
    ff("-i", src, "-filter_complex", vf, "-start_number", "0", f"{out}/all/%03d.png")
    frames = sorted(glob.glob(f"{out}/all/*.png"))
    order = list(range(count)) if not reverse else [0] + list(range(count - 1, 0, -1))
    shadow = f"{work}/out/{k}/shadow.png"
    for i, o in enumerate(order):
        p = frames[chosen[o]]
        clean(p, despill, fill)
        q = f"{out}/fg/{i:03d}.png"
        ff("-i", shadow, "-i", p, "-filter_complex",
           f"[0:v]scale={SIZE}:{SIZE}:flags=bicubic,format=rgba[s];[1:v]format=rgba[f];[s][f]overlay=format=rgb,format=rgba", "-frames:v", "1", q)
    shutil.rmtree(out + "/all")
    subprocess.run(["swift", f"{HERE}/pack_turn.swift", f"{out}/fg", f"{out}/{k}-turn.heic", "0.72"], check=True)
    print(k, os.path.getsize(f"{out}/{k}-turn.heic") // 1024, "KB; steps", np.round(step[::20], 1).tolist())


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    n = int(sys.argv[sys.argv.index("--count") + 1]) if "--count" in sys.argv else 60
    args = [a for a in args if a != str(n)]
    build(args[0], args[1], args[2], args[3], float(args[4]), "--reverse" in sys.argv, n, "--despill" in sys.argv, "--fill" in sys.argv)
