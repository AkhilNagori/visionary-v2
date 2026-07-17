#!/usr/bin/env python3
"""
Visionary AI Glasses — main firmware
Pi Zero 2 W + CSI camera + MAX98357A I2S amp

Button (GPIO17):
  single press  -> READ: OCR the page in view, speak it
  double press  -> DESCRIBE: AI describes the scene
  hold 3s       -> safe shutdown

Cloud (Claude vision) is primary; offline Tesseract+Piper is the fallback
when there's no internet. Set ANTHROPIC_API_KEY in /etc/visionary.env
"""

import base64
import io
import os
import socket
import subprocess
import threading
import time

import requests
from gpiozero import Button
from picamera2 import Picamera2

# ---------------- config ----------------
BUTTON_PIN = 17
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
MODEL = os.environ.get("VISIONARY_MODEL", "claude-haiku-4-5")
PIPER_VOICE = "/opt/visionary/voices/en_US-lessac-low.onnx"
SOUNDS = "/opt/visionary/sounds"
CAPTURE_SIZE = (1640, 1232)  # full FoV binned mode on the V1.3-style sensor

READ_PROMPT = (
    "You are the voice of assistive smart glasses for a visually impaired "
    "student. Read ALL printed/handwritten text in this image aloud, in "
    "natural reading order. Output ONLY the text content, cleaned up for "
    "text-to-speech (expand obvious abbreviations, skip page furniture). "
    "If there is no readable text, say what the object is instead, in one "
    "short sentence."
)
DESCRIBE_PROMPT = (
    "You are the voice of assistive smart glasses. Describe this scene for "
    "a visually impaired person in 2-3 short, concrete sentences: main "
    "objects, people, obstacles, and any visible text. Be direct."
)

# ---------------- state ----------------
picam = None
busy = threading.Lock()
last_press = 0.0
press_timer = None


# ---------------- audio ----------------
def play(path, wait=False):
    cmd = ["aplay", "-q", path]
    if wait:
        subprocess.run(cmd, check=False)
    else:
        subprocess.Popen(cmd)


def beep(name):  # capture.wav / ok.wav / err.wav / offline.wav
    p = f"{SOUNDS}/{name}.wav"
    if os.path.exists(p):
        play(p)


def speak(text):
    """Piper TTS -> aplay. Falls back to espeak-ng."""
    text = text.strip()
    if not text:
        return
    try:
        piper = subprocess.Popen(
            ["piper", "--model", PIPER_VOICE, "--output-raw"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        aplay = subprocess.Popen(
            ["aplay", "-q", "-r", "16000", "-f", "S16_LE", "-t", "raw", "-"],
            stdin=piper.stdout,
        )
        piper.stdin.write(text.encode())
        piper.stdin.close()
        aplay.wait()
    except Exception:
        subprocess.run(["espeak-ng", "-s", "160", text], check=False)


# ---------------- camera ----------------
def init_camera():
    global picam
    picam = Picamera2()
    cfg = picam.create_still_configuration(main={"size": CAPTURE_SIZE})
    picam.configure(cfg)
    picam.start()
    time.sleep(1.5)  # AE/AWB settle


def capture_jpeg():
    buf = io.BytesIO()
    picam.capture_file(buf, format="jpeg")
    return buf.getvalue()


# ---------------- pipelines ----------------
def online():
    try:
        socket.create_connection(("api.anthropic.com", 443), timeout=2).close()
        return bool(API_KEY)
    except OSError:
        return False


def ask_claude(jpeg, prompt):
    r = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={
            "model": MODEL,
            "max_tokens": 1024,
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "image", "source": {
                        "type": "base64", "media_type": "image/jpeg",
                        "data": base64.b64encode(jpeg).decode()}},
                    {"type": "text", "text": prompt},
                ],
            }],
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["content"][0]["text"]


def ocr_offline(jpeg):
    from PIL import Image, ImageOps
    img = Image.open(io.BytesIO(jpeg)).convert("L")
    img = ImageOps.autocontrast(img)
    import pytesseract
    return pytesseract.image_to_string(img)


def run(mode):
    if not busy.acquire(blocking=False):
        return
    try:
        beep("capture")
        jpeg = capture_jpeg()
        if online():
            prompt = READ_PROMPT if mode == "read" else DESCRIBE_PROMPT
            try:
                text = ask_claude(jpeg, prompt)
                beep("ok")
                speak(text)
                return
            except Exception:
                beep("err")
        # offline fallback
        beep("offline")
        if mode == "read":
            text = ocr_offline(jpeg)
            speak(text if text.strip() else "I couldn't find any text.")
        else:
            speak("Scene description needs internet. Reading any text instead.")
            speak(ocr_offline(jpeg) or "No text found.")
    finally:
        busy.release()


# ---------------- button: single / double / hold ----------------
def on_press():
    global last_press, press_timer
    now = time.monotonic()
    if now - last_press < 0.45:  # double press
        if press_timer:
            press_timer.cancel()
        threading.Thread(target=run, args=("describe",), daemon=True).start()
    else:
        press_timer = threading.Timer(
            0.45, lambda: threading.Thread(
                target=run, args=("read",), daemon=True).start())
        press_timer.start()
    last_press = now


def on_hold():
    speak("Shutting down. Goodbye.")
    subprocess.run(["sudo", "shutdown", "-h", "now"])


def main():
    init_camera()
    btn = Button(BUTTON_PIN, pull_up=True, hold_time=3.0, bounce_time=0.05)
    btn.when_pressed = on_press
    btn.when_held = on_hold
    speak("Visionary ready." + ("" if online() else " Offline mode."))
    threading.Event().wait()  # sleep forever; callbacks do the work


if __name__ == "__main__":
    main()
