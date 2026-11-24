#!/usr/bin/env python3
"""Generates every platform's app icon from assets/icons/courier_dark.png.

Usage:  python3 tool/generate_icons.py        (requires Pillow: pip install pillow)

Outputs
  macOS   macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png
          (Big Sur style: rounded tile on a transparent canvas with standard padding)
  Windows windows/runner/resources/app_icon.ico  (16–256 px, rounded tile)
  Linux   packaging/linux/icons/hicolor/<n>x<n>/apps/courier.png  (rounded tile)
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "icons" / "courier_dark.png"


def rounded_mask(size: int, radius: int) -> Image.Image:
    # Draw at 4x and downsample for smooth anti-aliased corners.
    big = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=radius * 4, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def tile(src: Image.Image, size: int, radius_ratio: float) -> Image.Image:
    img = src.resize((size, size), Image.LANCZOS).convert("RGBA")
    img.putalpha(rounded_mask(size, round(size * radius_ratio)))
    return img


def macos_icon(src: Image.Image, size: int) -> Image.Image:
    # Apple's template: 824/1024 content tile, ~185/1024 corner radius, centered.
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = max(1, round(size * 824 / 1024))
    t = tile(src, inner, 185 / 824)
    off = (size - inner) // 2
    canvas.alpha_composite(t, (off, off))
    return canvas


def main() -> None:
    src = Image.open(SOURCE).convert("RGBA")
    if src.size[0] < 1024:
        print(f"note: source is {src.size[0]}px; a 1024px source gives sharper large icons")

    mac_dir = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for n in (16, 32, 64, 128, 256, 512, 1024):
        macos_icon(src, n).save(mac_dir / f"app_icon_{n}.png")

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    base = tile(src, 256, 0.18)
    base.save(ROOT / "windows" / "runner" / "resources" / "app_icon.ico", sizes=[(n, n) for n in ico_sizes])

    for n in (32, 48, 64, 128, 256, 512):
        out = ROOT / "packaging" / "linux" / "icons" / "hicolor" / f"{n}x{n}" / "apps"
        out.mkdir(parents=True, exist_ok=True)
        tile(src, n, 0.18).save(out / "courier.png")

    print("icons generated")


if __name__ == "__main__":
    main()
