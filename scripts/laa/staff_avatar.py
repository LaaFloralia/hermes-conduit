#!/usr/bin/env python3
"""Build one employee's avatar set from a generated portrait (docs/laa/DESIGN.md, "社員3Dの制作手順").

Inputs: the open-eyed portrait, the same portrait with eyes closed (an image_gen edit),
and a cutout of the open portrait (any matting tool; only its alpha is used).
Outputs in --out: hero-1024.png (transparent still), avatar-512.png (loop frame 0),
loop/idle-NNN.png (2.0 s at 30 fps). Encode the HEVC-with-alpha loop with the ffmpeg
line in DESIGN.md. Needs Pillow and numpy (not part of the app build).

Motion: one breath, a small head sway around the neck and one hard-cut blink, all
periodic over the loop, so the last frame runs into the first.
"""
import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--open", required=True, help="portrait, eyes open")
    p.add_argument("--closed", required=True, help="same portrait, eyes closed")
    p.add_argument("--cutout", required=True, help="RGBA cutout of --open")
    p.add_argument("--out", required=True)
    p.add_argument("--eyes", required=True, help="lx,ly,rx,ry eye centres in portrait px")
    p.add_argument("--pivot", required=True, help="x,y base of the neck")
    p.add_argument("--chin", type=float, required=True, help="y where the head weight starts to fade")
    p.add_argument("--crop", required=True, help="x,y,size square crop for the avatar loop")
    p.add_argument("--blink-at", type=float, default=1.10)
    return p.parse_args()


def floats(s):
    return [float(v) for v in s.split(",")]


def main():
    a = parse_args()
    opened = Image.open(a.open).convert("RGB")
    W, H = opened.size
    closed_src = Image.open(a.closed).convert("RGB").resize((W, H), Image.LANCZOS)
    cut = Image.open(a.cutout).convert("RGBA").resize((W, H), Image.LANCZOS)

    # Closed frame: take only the eyes from the edit, so the glasses and face stay pixel-identical.
    lx, ly, rx, ry = floats(a.eyes)
    s = W / 1254.0
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    for cx, cy in ((lx, ly), (rx, ry)):
        d.ellipse((cx - 72 * s, cy - 48 * s, cx + 72 * s, cy + 44 * s), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(10 * s))
    closed = Image.composite(closed_src, opened, mask)

    alpha = np.asarray(cut)[..., 3].astype(np.float32) / 255.0

    def rgba(img):
        # Remove the flat background colour from semi-transparent hair edges.
        rgb = np.asarray(img).astype(np.float32)
        bg = np.median(rgb[:40, :40].reshape(-1, 3), axis=0)
        al = alpha[..., None]
        fg = np.where(al > 0.02, (rgb - (1 - al) * bg) / np.maximum(al, 0.02), rgb)
        return np.dstack([np.clip(fg, 0, 255), alpha * 255])

    src_open, src_closed = rgba(opened), rgba(closed)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    px, py = floats(a.pivot)
    fade = 140 * s
    head_w = np.clip((a.chin - yy) / fade, 0, 1)
    head_w = head_w * head_w * (3 - 2 * head_w)
    body_w = np.clip((yy - 0.48 * H) / (0.48 * H), 0, 1)

    def sample(src, sx, sy):
        x0 = np.clip(np.floor(sx).astype(int), 0, W - 2)
        y0 = np.clip(np.floor(sy).astype(int), 0, H - 2)
        fx = np.clip(sx - x0, 0, 1)[..., None]
        fy = np.clip(sy - y0, 0, 1)[..., None]
        top = src[y0, x0] * (1 - fx) + src[y0, x0 + 1] * fx
        bot = src[y0 + 1, x0] * (1 - fx) + src[y0 + 1, x0 + 1] * fx
        out = top * (1 - fy) + bot * fy
        out[(sx < 0) | (sx > W - 1) | (sy < 0) | (sy > H - 1)] = 0
        return out

    def frame(t, T=2.0):
        ph = 2 * math.pi * t / T
        roll = math.radians(0.9) * math.sin(ph + 0.6)
        nod = 2.2 * s * math.sin(2 * ph)
        lift = 2.0 * s * math.sin(ph)
        th = -roll * head_w
        dx, dy = xx - px, yy - py
        sx = px + dx * np.cos(th) - dy * np.sin(th)
        sy = py + dx * np.sin(th) + dy * np.cos(th)
        sy = sy + nod * head_w + lift * np.maximum(body_w, head_w)
        # Hard cut: a cross-fade ghosts the eyes at header size.
        src = src_closed if 0 <= t - a.blink_at < 0.125 else src_open
        return sample(src, sx, sy)

    def img(arr):
        return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")

    os.makedirs(os.path.join(a.out, "loop"), exist_ok=True)
    img(src_open).resize((1024, 1024), Image.LANCZOS).save(os.path.join(a.out, "hero-1024.png"), optimize=True)
    cx, cy, size = floats(a.crop)
    box = (int(cx), int(cy), int(cx + size), int(cy + size))
    fps, T = 30, 2.0
    for i in range(int(fps * T)):
        im = img(frame(i / fps, T)).crop(box).resize((512, 512), Image.LANCZOS)
        im.save(os.path.join(a.out, "loop", f"idle-{i:03d}.png"))
        if i == 0:
            im.save(os.path.join(a.out, "avatar-512.png"), optimize=True)


if __name__ == "__main__":
    main()
