#!/usr/bin/env python3
"""Draw numbered callouts onto documentation screenshots.

Input: a directory of `<name>.png` + `<name>.json` pairs as produced by the
integration test's SCREENSHOTS mode. Every JSON entry is a marker
{n, label, x, y, w, h} in PNG pixel coordinates (taken live from the widget
tree, so they track layout changes).

Output: `<name>_annotated.png` with an accent outline around each control
and a numbered badge — the numbers match the legends in docs/GUIDE.md
(labels are also printed to stdout as a markdown list for pasting).

Usage: annotate_screenshots.py <shots_dir> [out_dir]
Requires pillow (`pip install pillow`).
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ACCENT = (79, 195, 247, 255)  # light blue, matches the app accent
BADGE_TEXT = (0, 0, 0, 255)


def font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in (
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def annotate(png: Path, out_dir: Path) -> None:
    markers = json.loads(png.with_suffix(".json").read_text())
    img = Image.open(png).convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    badge_font = font(26)
    r = 20  # badge radius

    for m in markers:
        x, y, w, h = m["x"], m["y"], m["w"], m["h"]
        pad = 6
        draw.rounded_rectangle(
            [x - pad, y - pad, x + w + pad, y + h + pad],
            radius=10,
            outline=ACCENT,
            width=4,
        )
        # Badge at the top-left corner, nudged inside the image.
        cx = max(r + 2, min(img.width - r - 2, x - pad))
        cy = max(r + 2, min(img.height - r - 2, y - pad))
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT)
        label = str(m["n"])
        tw = draw.textlength(label, font=badge_font)
        draw.text((cx - tw / 2, cy - 15), label, font=badge_font, fill=BADGE_TEXT)

    out = Image.alpha_composite(img, overlay).convert("RGB")
    out_path = out_dir / f"{png.stem}_annotated.png"
    out.save(out_path, optimize=True)
    print(f"\n### {png.stem} → {out_path.name}")
    for m in markers:
        print(f"{m['n']}. {m['label']}")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    shots = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else shots
    out_dir.mkdir(parents=True, exist_ok=True)
    pairs = sorted(p for p in shots.glob("*.png") if p.with_suffix(".json").exists())
    if not pairs:
        sys.exit(f"no png+json pairs in {shots}")
    for png in pairs:
        annotate(png, out_dir)


if __name__ == "__main__":
    main()
