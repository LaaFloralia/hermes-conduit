#!/usr/bin/env python3
"""Key one generated mascot clip into the app's loop, avatar and hero.

Usage: matte_loop.py <workdir> <id> <clip.mp4>

<workdir> holds cut-<id>.png (the cutout of the adopted still) and bbox.json and
frames.json (its bounds and its placement on the keyed start frame, as used for
the clip). Output goes to <workdir>/out/<id>. See docs/laa/DESIGN.md.
"""
import glob, json, math, os, shutil, subprocess, sys

KEY = {"green": ("0x09AD4B", 0.13, 0.05, "green"), "cfo": ("0x0AA0EA", 0.13, 0.05, "blue"), "cto": ("0xC32984", 0.12, 0.05, None)}
FADE = 10
INSET = 466  # the mascot is drawn this wide inside 512 so the moving silhouette stays within the app circle
PAD = (512 - INSET) // 2


def run(*a):
    subprocess.run(a, check=True)


def ff(*a):
    run("ffmpeg", "-y", "-loglevel", "error", *a)


def build(k, src, crop=(720, 280, 0), cut_scale=None, cut_at=None):
    meta = json.load(open("frames.json"))[k]
    bb = json.load(open("bbox.json"))[k]
    color, sim, blend, spill = KEY.get(k, KEY["green"])
    cw, cx, cy = crop
    S = cut_scale or meta["S"]
    ox, oy = cut_at or (meta["ox"], meta["oy"])
    out = f"out/{k}"
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out + "/fg")
    os.makedirs(out + "/mix")
    f = meta["s"] if cut_scale is None else cut_scale / 1254
    x1, x2, y1, y2 = bb
    shadow_scale = INSET / cw
    scx = (x1 + x2) / 2 * f + ox - cx
    sby = y2 * f + oy - cy
    rx, ry = (x2 - x1) * f * 0.40, 15.0
    # static soft contact shadow, in crop pixels then scaled
    px, py, prx, pry = scx * shadow_scale + PAD, (sby - 4) * shadow_scale + PAD, rx * shadow_scale, ry * shadow_scale
    shadow = f"{out}/shadow.png"
    ff("-f", "lavfi", "-i", "color=c=black:s=512x512,format=rgba", "-vf",
       f"geq=r=0:g=0:b=0:a='min(255,88*exp(-1.6*(pow((X-{px:.1f})/{prx:.1f},2)+pow((Y-{py:.1f})/{pry:.1f},2))))'",
       "-frames:v", "1", shadow)
    vf = (f"[0:v]crop={cw}:{cw}:{cx}:{cy},format=yuva444p,chromakey={color}:{sim}:{blend},split[c][a];"
          "[a]alphaextract,erosion,erosion,gblur=sigma=0.7[m];"
          f"[c][m]alphamerge,format=rgba,scale={INSET}:{INSET}:flags=lanczos,pad=512:512:{PAD}:{PAD}:color=black@0")
    ff("-i", src, "-filter_complex", vf, "-start_number", "0", f"{out}/fg/%03d.png")
    frames = sorted(glob.glob(f"{out}/fg/*.png"))
    n = len(frames) - 1
    for i in range(n):
        p = frames[i]
        q = f"{out}/mix/{i:03d}.png"
        t = max(0, (i - (n - FADE)) + 1) / (FADE + 1)
        if t > 0:
            # ease the tail onto the first frame so the loop never pops
            e = t * t * (3 - 2 * t)
            ff("-i", p, "-i", frames[0], "-filter_complex", f"[0:v]format=rgba[a];[1:v]format=rgba[b];[a][b]blend=all_expr='A*(1-{e:.3f})+B*{e:.3f}'", "-frames:v", "1", q)
        else:
            shutil.copy(p, q)
    seq = f"{out}/comp"
    os.makedirs(seq)
    ff("-loop", "1", "-framerate", "24", "-i", shadow, "-framerate", "24", "-i", f"{out}/mix/%03d.png", "-filter_complex",
       "[0:v]format=rgba[s];[1:v]format=rgba[f];[s][f]overlay=shortest=1:format=rgb,format=rgba", "-start_number", "0", f"{seq}/%03d.png")
    mov = f"{out}/{k}-idle-512.mov"
    ff("-framerate", "24", "-i", f"{seq}/%03d.png", "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "62", "-tag:v", "hvc1", "-pix_fmt", "bgra", mov)
    shutil.copy(f"{seq}/000.png", f"{out}/{k}-avatar-512.png")
    # hero from the original still at full resolution, same framing as the loop
    r = 2 * INSET / cw
    hero_s = round(S * r)
    hx, hy = round((ox - cx) * r) + 2 * PAD, round((oy - cy) * r) + 2 * PAD
    ff("-f", "lavfi", "-i", "color=c=black@0.0:s=1024x1024,format=rgba", "-i", shadow, "-i", f"cut-{k}.png", "-filter_complex",
       f"[1:v]scale=1024:1024:flags=bicubic,format=rgba[s];[2:v]scale={hero_s}:{hero_s}:flags=lanczos,format=rgba[m];[0:v][s]overlay=format=rgb[a];[a][m]overlay={hx}:{hy}:format=rgb,format=rgba",
       "-frames:v", "1", f"{out}/{k}-hero-1024.png")
    print(k, os.path.getsize(mov) // 1024, "KB", n, "frames")


if __name__ == "__main__":
    workdir, k, src = sys.argv[1:4]
    src = os.path.abspath(src)
    os.chdir(workdir)
    if k == "ciel":
        # The first clip, made before the frames were normalised.
        build(k, src, crop=(678, 301, 21), cut_scale=660, cut_at=(310, 34))
    else:
        build(k, src)
