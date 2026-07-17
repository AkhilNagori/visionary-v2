#!/usr/bin/env python3
"""End-to-end SIM smoke test for `make demo`.

Fakes a single button press through the real read pipeline in SIM mode, with a
generated golden worksheet as the "camera" image, and asserts that *something*
was spoken. With OPENAI_API_KEY set it exercises the real cloud path. Without a
key it injects a deterministic model reply, so the smoke test stays free and
network-independent while still exercising capture, streaming, and speech.

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
    # Capture every spoken utterance from direct or streaming speech paths.
    audio.speak = lambda text, wait=True: spoken.append(text)

    class _CaptureSpeaker:
        first_audio_ts = None

        def feed(self, chunk):
            spoken.append(chunk)

        def close(self):
            pass

    audio.SentenceSpeaker = _CaptureSpeaker

    if not os.environ.get("OPENAI_API_KEY"):
        import brain
        brain.is_online = lambda force=False: True

        def fake_see(jpeg, prompt, on_text=None, **kwargs):
            text = "Science worksheet about photosynthesis."
            if on_text:
                on_text(text)
            return text

        brain.see = fake_see

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
