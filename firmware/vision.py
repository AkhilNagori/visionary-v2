"""Camera lifecycle, capture, preview, and local capture storage.

The camera is started once at boot and kept running: a cold Picamera2
start costs ~1.5s of AE/AWB settling, so paying it once at init keeps
every button-press capture under 300ms.
"""

import io
import os
import threading
import time
from typing import Tuple

from PIL import Image

import state

SIM = os.environ.get("VISIONARY_SIM") == "1"

CAPTURE_SIZE = (1640, 1232)  # full-FoV 2x2 binned mode on the V1.3-style sensor

_picam = None
_camera_lock = threading.Lock()  # captures come from both action threads and the UDS frame handler
_sim_generated = None


def init_camera() -> None:
    global _picam
    if SIM or _picam is not None:
        return
    from picamera2 import Picamera2  # not installed on SIM machines
    cam = Picamera2()
    cam.configure(cam.create_still_configuration(main={"size": CAPTURE_SIZE}))
    cam.start()
    time.sleep(1.5)  # one-time AE/AWB settle
    _picam = cam


def capture_jpeg() -> bytes:
    if SIM:
        return _sim_image_bytes()
    if _picam is None:
        init_camera()
    buf = io.BytesIO()
    with _camera_lock:
        _picam.capture_file(buf, format="jpeg")
    return buf.getvalue()


def capture_preview_jpeg(size: Tuple[int, int] = (640, 480)) -> bytes:
    if SIM:
        img = Image.open(io.BytesIO(_sim_image_bytes())).convert("RGB")
    else:
        if _picam is None:
            init_camera()
        with _camera_lock:
            img = _picam.capture_image("main").convert("RGB")
    img = img.resize(size, Image.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=70)
    return buf.getvalue()


def save_capture(jpeg: bytes) -> str:
    captures = os.path.join(state.HOME, "captures")
    os.makedirs(captures, exist_ok=True)
    ts = int(time.time())
    path = os.path.join(captures, "%d.jpg" % ts)
    n = 1
    while os.path.exists(path):
        path = os.path.join(captures, "%d-%d.jpg" % (ts, n))
        n += 1
    with open(path, "wb") as f:
        f.write(jpeg)
    return path


def _sim_image_bytes() -> bytes:
    override = os.environ.get("VISIONARY_SIM_IMAGE")
    if override and os.path.exists(override):
        with open(override, "rb") as f:
            return f.read()
    return _generate_worksheet_jpeg()


def _load_font(size: int):
    from PIL import ImageFont
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1: no size arg
        return ImageFont.load_default()


def _generate_worksheet_jpeg() -> bytes:
    """Readable worksheet-style test image so SIM demos work with zero setup."""
    global _sim_generated
    if _sim_generated is not None:
        return _sim_generated
    from PIL import ImageDraw
    img = Image.new("RGB", CAPTURE_SIZE, "white")
    draw = ImageDraw.Draw(img)
    title = _load_font(72)
    body = _load_font(52)
    lines = [
        ("Science Worksheet: Photosynthesis", title),
        ("", body),
        ("1. Plants use sunlight, water, and carbon", body),
        ("   dioxide to make their own food.", body),
        ("2. The green pigment in leaves is called", body),
        ("   chlorophyll.", body),
        ("3. Photosynthesis produces the oxygen that", body),
        ("   humans and animals breathe.", body),
        ("", body),
        ("Homework: read chapter four before Friday.", body),
    ]
    y = 90
    for text, font in lines:
        if text:
            draw.text((110, y), text, font=font, fill="black")
        bbox = draw.textbbox((110, y), text or "x", font=font)
        y = bbox[3] + 30
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    _sim_generated = buf.getvalue()
    return _sim_generated
