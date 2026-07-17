#!/usr/bin/env python3
"""End-to-end SIM smoke test for `make demo`.

Fakes a single button press through the real read pipeline in SIM mode, with a
generated golden worksheet as the "camera" image, and asserts that *something*
was spoken. It forces the offline path (no API key), so on a machine without
Tesseract the graceful spoken failure ("I can't read right now...") still
counts as a pass — the point is that the device never fails silently.

Prints PASS/FAIL and exits 0/1 so it can gate a demo build.
"""

import os
import sys
import tempfile


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    os.environ["VISIONARY_SIM"] = "1"
    os.environ["VISIONARY_HOME"] = tempfile.mkdtemp(prefix="visionary_demo_")
    # Force offline: the demo must run with no key and no network.
    os.environ.pop("ANTHROPIC_API_KEY", None)
    os.environ.pop("OPENAI_API_KEY", None)

    firmware = os.path.join(root, "firmware")
    for path in (firmware, here):
        if path not in sys.path:
            sys.path.insert(0, path)

    import generate_golden
    golden_dir = os.path.join(here, "golden")
    generate_golden.generate(golden_dir)
    os.environ["VISIONARY_SIM_IMAGE"] = os.path.join(golden_dir, "worksheet.png")

    import audio
    spoken = []
    # Capture every spoken utterance, whether it comes through speak() directly
    # (offline path) or the streaming SentenceSpeaker (online path).
    audio.speak = lambda text, wait=True: spoken.append(text)

    class _CaptureSpeaker:
        first_audio_ts = None

        def feed(self, chunk):
            spoken.append(chunk)

        def close(self):
            pass

    audio.SentenceSpeaker = _CaptureSpeaker

    from modes import read
    read.run_read()

    ok = any(s and s.strip() for s in spoken)
    print("spoken output:")
    for utterance in spoken:
        print("  " + repr(utterance))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
