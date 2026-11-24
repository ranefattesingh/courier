#!/usr/bin/env python3
"""Converts the screenshots rendered by screenshots_test.dart (build/screenshots/*.png)
into compressed WebP files for the website (website/img/*.webp). Needs Pillow."""
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parents[2]
src, dst = root / "build" / "screenshots", root / "website" / "img"
dst.mkdir(parents=True, exist_ok=True)
for png in sorted(src.glob("*.png")):
    out = dst / (png.stem + ".webp")
    Image.open(png).save(out, "WEBP", quality=88, method=6)
    print(f"{out.relative_to(root)}  {out.stat().st_size // 1024} KB")
