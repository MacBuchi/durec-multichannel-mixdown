#!/usr/bin/env python3
"""Build the Play Store graphics from docs/screenshots/ and the logo.

    tool/store_assets.py [<out-dir>]

Default target is the exchange folder next to the store listing text
(`Claude_exchange/mixstack_store_eintrag/grafiken`). Everything here is
derived — never hand-cropped — so a refreshed screenshot run is one command
away from a refreshed store listing.

Play rejects assets on three counts that are easy to miss because nothing in
the repo enforces them, and all three actually bit us:

* **Aspect ratio at most 2:1.** The phone shots come off the device at
  840x1720, which is 1:2.048 — just over. They are padded (not scaled) to
  9:16 with the app's own background colour, so the padding is invisible.
* **No alpha channel** on screenshots or the feature graphic. Every shot the
  Flutter harness writes carries one. They are composited onto the background
  colour rather than simply dropped, because discarding alpha turns any real
  transparency into black.
* **Feature graphic is exactly 1024x500.** Rendered from `assets/icon/logo.svg`
  plus the wordmark via rsvg-convert, so it stays in step with the app icon.

The app icon is the one asset that *may* keep an alpha channel, and it must
stay under 1 MB.

Needs pillow and rsvg-convert. The venv `tool/make_screenshots.sh` creates is
reused when it is there.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_OUT = pathlib.Path(
    "/Volumes/MacStore/Nextcloud_MSB/Claude_exchange"
    "/mixstack_store_eintrag/grafiken"
)

# The app's window background (AppColors), used for every kind of padding.
BG = (16, 20, 28)  # #10141C

# Play's own limits, kept here so the check below reads as the spec it is.
MIN_SIDE, MAX_SIDE = 320, 3840
MAX_RATIO = 2.0
MAX_SHOT_BYTES = 8 * 1024 * 1024
MAX_ICON_BYTES = 1024 * 1024

# Which screenshot goes to which store slot, in upload order — Play shows
# them exactly like this, and the first is the one most people see alone.
PHONE = [("phone_android.png", "phone-1-mixer.png"),
         ("phone_menu_android.png", "phone-2-menue.png")]
TABLET = [("mixer.png", "tablet-1-mixer.png"),
          ("eq.png", "tablet-2-eq.png"),
          ("mastering.png", "tablet-3-mastering.png"),
          ("browser.png", "tablet-4-browser.png")]

FEATURE_SVG = ROOT / "tool" / "feature-graphic.svg"


def flatten(src: pathlib.Path, dst: pathlib.Path, pad_to_ratio: float | None) -> None:
    """Composite onto [BG], optionally padding sideways to a target ratio."""
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    if pad_to_ratio is not None and h / w > pad_to_ratio:
        w = round(h / pad_to_ratio)
    out = Image.new("RGB", (w, h), BG)
    out.paste(im, ((w - im.width) // 2, (h - im.height) // 2), im)
    out.save(dst, "PNG", optimize=True)


def check(path: pathlib.Path, kind: str = "shot") -> str:
    """Hold one asset against Play's rules. Each `kind` has its own set —
    the 2:1 ceiling is a *screenshot* rule, and applying it to the feature
    graphic would flag its mandatory 1024x500 (which is 2.048:1)."""
    im = Image.open(path)
    w, h = im.size
    size = path.stat().st_size
    problems = []
    if kind == "icon":
        if (w, h) != (512, 512):
            problems.append(f"{w}x{h}, muss 512x512 sein")
        if size > MAX_ICON_BYTES:
            problems.append(f"{size // 1024} KB > 1 MB")
    elif kind == "feature":
        if (w, h) != (1024, 500):
            problems.append(f"{w}x{h}, muss 1024x500 sein")
        if im.mode != "RGB":
            problems.append(f"{im.mode} — Play verbietet den Alphakanal")
    else:
        if im.mode != "RGB":
            problems.append(f"{im.mode} — Play verbietet den Alphakanal")
        if not (MIN_SIDE <= w <= MAX_SIDE and MIN_SIDE <= h <= MAX_SIDE):
            problems.append(f"{w}x{h} ausserhalb {MIN_SIDE}-{MAX_SIDE} px")
        if max(w, h) / min(w, h) > MAX_RATIO:
            problems.append(f"Seitenverhaeltnis {max(w, h) / min(w, h):.3f} > 2:1")
        if size > MAX_SHOT_BYTES:
            problems.append(f"{size // 1024 // 1024} MB > 8 MB")
    status = "FEHL" if problems else "OK  "
    return f"{status} {path.name:24s} {w:5d}x{h:<5d} {im.mode:5s} " \
           f"{size // 1024:5d} KB {'; '.join(problems)}"


def main() -> int:
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.mkdir(parents=True, exist_ok=True)
    shots = ROOT / "docs" / "screenshots"

    # Icon: the 1024 master carries no alpha already, so a resize is enough.
    Image.open(ROOT / "assets" / "icon" / "icon_full.png") \
        .convert("RGB").resize((512, 512), Image.LANCZOS) \
        .save(out / "icon-512.png", "PNG", optimize=True)

    subprocess.run(
        ["rsvg-convert", "-w", "1024", "-h", "500", "-b", "#10141C",
         str(FEATURE_SVG), "-o", str(out / "feature-graphic.png")],
        check=True,
    )
    flatten(out / "feature-graphic.png", out / "feature-graphic.png", None)

    missing = []
    for src, dst in PHONE:
        p = shots / src
        if p.exists():
            flatten(p, out / dst, pad_to_ratio=16 / 9)
        else:
            missing.append(src)
    for src, dst in TABLET:
        p = shots / src
        if p.exists():
            flatten(p, out / dst, pad_to_ratio=None)
        else:
            missing.append(src)

    print(f"→ {out}\n")
    print(check(out / "icon-512.png", "icon"))
    print(check(out / "feature-graphic.png", "feature"))
    for f in sorted(out.glob("*.png")):
        if f.name not in ("icon-512.png", "feature-graphic.png"):
            print(check(f))
    if missing:
        print("\nfehlende Vorlagen (tool/make_screenshots.sh laufen lassen): "
              + ", ".join(missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
