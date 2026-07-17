"""Offline OCR path: brain.ocr() on the golden images must contain the expected
text. Skipped where Tesseract (binary or python binding) is unavailable."""

import json
import os
import shutil

import pytest

pytest.importorskip("pytesseract")
if shutil.which("tesseract") is None:
    pytest.skip("tesseract binary not installed", allow_module_level=True)

import generate_golden  # noqa: E402  (on sys.path: pytest rootdir = tests/)


def test_ocr_reads_golden_images(load):
    generate_golden.generate()
    brain = load("brain")
    with open(os.path.join(generate_golden.GOLDEN_DIR, "expected.json")) as f:
        expected = json.load(f)

    checked = 0
    for name, substrings in expected.items():
        if not substrings:
            continue  # low-contrast / blank pages: existence only
        with open(os.path.join(generate_golden.GOLDEN_DIR, name), "rb") as f:
            jpeg = f.read()
        text = brain.ocr(jpeg).lower()
        for sub in substrings:
            assert sub in text, (
                "%s: expected %r in OCR output %r" % (name, sub, text))
        checked += 1
    assert checked >= 3  # worksheet, menu, sign all exercised
