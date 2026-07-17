#!/usr/bin/env python3
"""Render the deterministic golden image set used by the offline-OCR test.

Five PIL-rendered scenes cover the reading cases that matter: a multi-line
worksheet, a menu, a big-text sign, a low-contrast page, and a blank page.
``expected.json`` maps each filename to the lowercase substrings its OCR output
must contain (empty for the low-contrast/blank pages, which exist to prove the
pipeline degrades gracefully rather than to assert exact text).

Font strategy is deliberately path-independent: PIL's built-in default font,
scaled — no reliance on any particular TTF being installed, so this renders the
same on a Pi, a Mac, or CI.
"""

import json
import os

from PIL import Image, ImageDraw, ImageFont

GOLDEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden")

EXPECTED = {
    "worksheet.png": ["spelling", "cat", "dog", "read"],
    "menu.png": ["menu", "pizza", "salad"],
    "sign.png": ["exit"],
    "lowcontrast.png": [],
    "blank.png": [],
}


def _font(size):
    try:
        return ImageFont.load_default(size=size)   # Pillow >= 10.1: scalable
    except TypeError:
        base = ImageFont.load_default()
        try:
            return base.font_variant(size=size)
        except Exception:
            return base


def _render_lines(path, lines, title=None, size=(1000, 720),
                  bg="white", fg="black", font_size=52, title_size=68, margin=70):
    img = Image.new("RGB", size, bg)
    draw = ImageDraw.Draw(img)
    y = margin
    if title:
        tf = _font(title_size)
        draw.text((margin, y), title, font=tf, fill=fg)
        y = draw.textbbox((margin, y), title, font=tf)[3] + 34
    font = _font(font_size)
    for line in lines:
        if line:
            draw.text((margin, y), line, font=font, fill=fg)
        y = draw.textbbox((margin, y), line or "Ag", font=font)[3] + 22
    img.save(path, format="PNG")


def _render_sign(path, text="EXIT", size=(820, 420)):
    img = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(img)
    font = _font(230)
    bbox = draw.textbbox((0, 0), text, font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size[0] - w) / 2 - bbox[0], (size[1] - h) / 2 - bbox[1]),
              text, font=font, fill="black")
    img.save(path, format="PNG")


def _render_lowcontrast(path, size=(1000, 500)):
    img = Image.new("RGB", size, (208, 208, 208))
    draw = ImageDraw.Draw(img)
    font = _font(48)
    y = 90
    for line in ("Low contrast reading test.", "The quick brown fox jumps."):
        draw.text((70, y), line, font=font, fill=(150, 150, 150))
        y = draw.textbbox((70, y), line, font=font)[3] + 26
    img.save(path, format="PNG")


def generate(out_dir=None):
    """Render every golden image + expected.json into ``out_dir``.

    Returns the expected-substrings mapping.
    """
    out_dir = out_dir or GOLDEN_DIR
    os.makedirs(out_dir, exist_ok=True)

    _render_lines(
        os.path.join(out_dir, "worksheet.png"),
        title="Spelling List",
        lines=[
            "1. cat",
            "2. dog",
            "3. sun",
            "",
            "Read each word aloud.",
        ],
    )
    _render_lines(
        os.path.join(out_dir, "menu.png"),
        title="Lunch Menu",
        lines=[
            "Cheese Pizza",
            "Garden Salad",
            "Apple Juice",
        ],
    )
    _render_sign(os.path.join(out_dir, "sign.png"))
    _render_lowcontrast(os.path.join(out_dir, "lowcontrast.png"))
    Image.new("RGB", (800, 600), "white").save(
        os.path.join(out_dir, "blank.png"), format="PNG")

    with open(os.path.join(out_dir, "expected.json"), "w") as f:
        json.dump(EXPECTED, f, indent=2)
        f.write("\n")
    return EXPECTED


def main():
    generate()
    print("wrote %d golden images + expected.json to %s"
          % (len(EXPECTED), GOLDEN_DIR))


if __name__ == "__main__":
    main()
