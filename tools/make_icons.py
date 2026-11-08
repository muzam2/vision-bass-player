#!/usr/bin/env python3
"""Generate Bass Player's app icons (visionOS layered icon, tvOS layered icon + top shelf).

Pure Pillow, no font dependency, so it runs anywhere:
  python3 tools/make_icons.py
writes BassPlayer/Assets.xcassets (visionOS) and BassPlayer/Assets-tvOS.xcassets (tvOS).

Design: a deep navy radial gradient (back), concentric cyan bass rings (middle), and a white
play triangle (front). visionOS masks the icon to a circle and gives each layer parallax;
tvOS does the same with its 400x240 layered icon.
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1] / "BassPlayer"
NAVY_CENTER = (26, 52, 104)
NAVY_EDGE = (5, 8, 18)
CYAN = (56, 214, 255)
WHITE = (255, 255, 255)


def info():
    return {"info": {"author": "xcode", "version": 1}}


def write_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


# ---------------------------------------------------------------- drawing

def back_layer(w: int, h: int) -> Image.Image:
    """Radial gradient, brighter at the centre, with a soft highlight top-left."""
    # Per-pixel Python is slow; a gradient upsamples perfectly, so render at <= 384 px.
    if max(w, h) > 384:
        k = 384 / max(w, h)
        return back_layer(max(1, round(w * k)), max(1, round(h * k))).resize((w, h), Image.BICUBIC)
    img = Image.new("RGBA", (w, h), NAVY_EDGE + (255,))
    px = img.load()
    cx, cy = w / 2, h / 2
    rmax = math.hypot(cx, cy)
    for y in range(h):
        for x in range(w):
            t = min(1.0, math.hypot(x - cx, y - cy) / rmax)
            t = t ** 1.4
            px[x, y] = tuple(int(NAVY_CENTER[i] * (1 - t) + NAVY_EDGE[i] * t) for i in range(3)) + (255,)
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    r = int(min(w, h) * 0.55)
    d.ellipse([cx - r * 1.1, cy - r * 1.3, cx + r * 0.3, cy + r * 0.1], fill=(120, 170, 255, 48))
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.12))
    return Image.alpha_composite(img, glow)


def middle_layer(w: int, h: int, scale: float) -> Image.Image:
    """Concentric bass rings, fading outwards, with a glow."""
    ss = 3
    W, H = w * ss, h * ss
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = W / 2, H / 2
    unit = min(W, H) * scale
    for i, (rad, alpha) in enumerate([(0.235, 235), (0.325, 170), (0.415, 105)]):
        r = unit * rad
        width = int(unit * 0.028)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=CYAN + (alpha,), width=width)
    glow = img.filter(ImageFilter.GaussianBlur(unit * 0.02))
    out = Image.alpha_composite(glow, img)
    return out.resize((w, h), Image.LANCZOS)


def front_layer(w: int, h: int, scale: float) -> Image.Image:
    """White play triangle with rounded corners and a soft shadow, optically centred."""
    ss = 4
    W, H = w * ss, h * ss
    unit = min(W, H) * scale
    cx, cy = W / 2 + unit * 0.03, H / 2
    half = unit * 0.16
    pts = [(cx - half * 0.9, cy - half * 1.15), (cx - half * 0.9, cy + half * 1.15), (cx + half * 1.1, cy)]
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    # Round the corners: blur then threshold.
    mask = mask.filter(ImageFilter.GaussianBlur(unit * 0.02)).point(lambda v: 255 if v > 128 else 0)
    mask = mask.filter(ImageFilter.GaussianBlur(ss * 0.6))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 140), (0, int(unit * 0.02)), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(unit * 0.03))
    tri = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    tri.paste(WHITE + (255,), (0, 0), mask)
    out = Image.alpha_composite(shadow, tri)
    return out.resize((w, h), Image.LANCZOS)


def flatten(w: int, h: int, scale: float) -> Image.Image:
    return Image.alpha_composite(Image.alpha_composite(back_layer(w, h), middle_layer(w, h, scale)), front_layer(w, h, scale))


# ---------------------------------------------------------------- visionOS

def write_visionos():
    base = ROOT / "Assets.xcassets"
    write_json(base / "Contents.json", info())
    stack = base / "AppIcon.solidimagestack"
    layers = [("Front", front_layer), ("Middle", middle_layer), ("Back", None)]
    write_json(stack / "Contents.json", {**info(), "layers": [{"filename": f"{n}.solidimagestacklayer"} for n, _ in layers]})
    size = 1024
    for name, fn in layers:
        layer = stack / f"{name}.solidimagestacklayer"
        write_json(layer / "Contents.json", info())
        imgset = layer / "Content.imageset"
        img = back_layer(size, size) if fn is None else fn(size, size, 1.0)
        imgset.mkdir(parents=True, exist_ok=True)
        img.save(imgset / f"{name.lower()}.png")
        write_json(imgset / "Contents.json", {**info(), "images": [{"filename": f"{name.lower()}.png", "idiom": "vision", "scale": "2x"}]})
    print(f"visionOS icon → {stack}")


# ---------------------------------------------------------------- tvOS

def tv_layer_images(name: str, sizes: list[tuple[int, int, str]], out: Path, scale: float):
    out.mkdir(parents=True, exist_ok=True)
    images = []
    for w, h, tag in sizes:
        fn = {"Front": front_layer, "Middle": middle_layer}.get(name)
        img = back_layer(w, h) if fn is None else fn(w, h, scale)
        fname = f"{name.lower()}{tag}.png"
        img.save(out / fname)
        images.append({"filename": fname, "idiom": "tv", "scale": "2x" if "@2x" in tag else "1x"})
    write_json(out / "Contents.json", {**info(), "images": images})


def write_tvos():
    base = ROOT / "Assets-tvOS.xcassets"
    write_json(base / "Contents.json", info())
    brand = base / "App Icon & Top Shelf Image.brandassets"
    write_json(brand / "Contents.json", {**info(), "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})
    for stack_name, sizes in [("App Icon.imagestack", [(400, 240, "@1x"), (800, 480, "@2x")]),
                              ("App Icon - App Store.imagestack", [(1280, 768, "")])]:
        stack = brand / stack_name
        write_json(stack / "Contents.json", {**info(), "layers": [{"filename": f"{n}.imagestacklayer"} for n in ["Front", "Middle", "Back"]]})
        for name in ["Front", "Middle", "Back"]:
            layer = stack / f"{name}.imagestacklayer"
            write_json(layer / "Contents.json", info())
            tv_layer_images(name, sizes, layer / "Content.imageset", scale=1.0)
    for set_name, sizes in [("Top Shelf Image.imageset", [(1920, 720, "@1x"), (3840, 1440, "@2x")]),
                            ("Top Shelf Image Wide.imageset", [(2320, 720, "@1x"), (4640, 1440, "@2x")])]:
        imgset = brand / set_name
        imgset.mkdir(parents=True, exist_ok=True)
        images = []
        for w, h, tag in sizes:
            fname = f"shelf{tag}.png"
            flatten(w, h, 1.0).save(imgset / fname)
            images.append({"filename": fname, "idiom": "tv", "scale": "2x" if "@2x" in tag else "1x"})
        write_json(imgset / "Contents.json", {**info(), "images": images})
    print(f"tvOS icon → {brand}")


if __name__ == "__main__":
    write_visionos()
    write_tvos()
    # A flat preview for humans.
    preview = ROOT.parent / "docs" / "icon-preview.png"
    preview.parent.mkdir(exist_ok=True)
    flatten(512, 512, 1.0).save(preview)
    print(f"preview → {preview}")
