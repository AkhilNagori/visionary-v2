"""audio.py contract in SIM: SentenceSpeaker sentence splitting + ordering,
the Recorder sim path, and record_until_silence returning a real WAV."""

import os
import subprocess
import wave

import pytest


def test_speak_uses_openai_tts_and_aplay(load, monkeypatch):
    audio = load("audio")
    monkeypatch.setattr(audio, "SIM", False)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    request = {}
    playback = {}

    class Response:
        status_code = 200
        content = b"RIFFfake-wav"

    def fake_post(url, **kwargs):
        request["url"] = url
        request.update(kwargs)
        return Response()

    def fake_run(cmd, **kwargs):
        playback["cmd"] = cmd
        playback.update(kwargs)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(audio.requests, "post", fake_post)
    monkeypatch.setattr(audio.subprocess, "run", fake_run)
    audio.speak("Hello from Visionary.")

    assert request["url"].endswith("/v1/audio/speech")
    assert request["headers"]["Authorization"] == "Bearer sk-test"
    assert request["json"] == {
        "model": "gpt-4o-mini-tts-2025-12-15",
        "voice": "marin",
        "input": "Hello from Visionary.",
        "response_format": "wav",
        "speed": 1.0,
    }
    assert playback["cmd"] == ["aplay", "-q", "-"]
    assert playback["input"] == Response.content


def test_tts_chunks_stay_below_api_limit(load):
    audio = load("audio")
    text = ("word " * 2100).strip()
    chunks = list(audio._tts_chunks(text))
    assert len(chunks) > 1
    assert all(0 < len(chunk) <= audio._TTS_MAX_CHARS for chunk in chunks)
    assert " ".join(chunks) == text


def test_speak_api_failure_logs_and_beeps(load, monkeypatch, capsys):
    audio = load("audio")
    monkeypatch.setattr(audio, "SIM", False)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-bad")
    beeps = []

    class Response:
        status_code = 401
        text = ""

        @staticmethod
        def json():
            return {"error": {"message": "invalid key"}}

    monkeypatch.setattr(audio.requests, "post", lambda *a, **k: Response())
    monkeypatch.setattr(audio, "beep", beeps.append)
    audio.speak("This will fail safely.")

    assert beeps == ["err"]
    assert "invalid key" in capsys.readouterr().err


def test_sentence_speaker_splits_in_order(load, monkeypatch):
    audio = load("audio")
    spoken = []
    # The worker thread looks up `speak` as a module global at call time, so
    # patching the module attribute captures exactly what it would voice.
    monkeypatch.setattr(audio, "speak", lambda text, wait=True: spoken.append(text))

    sp = audio.SentenceSpeaker()
    # Sentences arrive split across chunks, mid-word.
    sp.feed("Hello world. How ")
    sp.feed("are you? Last ")
    sp.feed("one here.")
    sp.close()  # flushes remainder, blocks until the queue drains

    assert spoken == ["Hello world.", "How are you?", "Last one here."]
    assert sp.first_audio_ts is not None  # set once speech starts


def test_sentence_speaker_skips_bare_punctuation(load, monkeypatch):
    audio = load("audio")
    spoken = []
    monkeypatch.setattr(audio, "speak", lambda text, wait=True: spoken.append(text))
    sp = audio.SentenceSpeaker()
    sp.feed("...")         # no word characters -> nothing to say
    sp.feed("   \n")       # whitespace only
    sp.close()
    assert spoken == []
    assert sp.first_audio_ts is None  # nothing was ever spoken


def test_recorder_sim_path_returns_wav(load):
    audio = load("audio")
    rec = audio.Recorder()
    assert rec.recording is False
    rec.start()
    assert rec.recording is True
    path = rec.stop()
    assert rec.recording is False
    assert path.endswith(".wav")
    assert os.path.exists(path)
    with wave.open(path, "rb") as w:  # a valid, readable WAV
        assert w.getnchannels() == 1
        assert w.getframerate() == audio.TARGET_RATE


def test_record_until_silence_sim_returns_wav(load):
    audio = load("audio")
    path = audio.record_until_silence(max_s=1.0, silence_s=0.2)
    assert path is not None
    assert path.endswith(".wav")
    assert os.path.exists(path)


def test_record_until_silence_uses_sim_wav_fixture(load, monkeypatch, tmp_path):
    # A provided fixture WAV is COPIED (never handed back verbatim): callers
    # delete/move the returned wav, and the shared fixture must survive reuse.
    fixture = tmp_path / "utt.wav"
    with wave.open(str(fixture), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x00\x00" * 16000)
    expected = fixture.read_bytes()
    monkeypatch.setenv("VISIONARY_SIM_WAV", str(fixture))
    audio = load("audio")

    first = audio.record_until_silence()
    assert first != str(fixture)          # a copy, not the fixture itself
    assert open(first, "rb").read() == expected
    os.remove(first)                      # simulate a caller discarding the wav

    second = audio.record_until_silence()  # fixture still intact for the next call
    assert second != str(fixture)
    assert open(second, "rb").read() == expected


def test_capture_in_use_false_at_rest(load):
    audio = load("audio")
    assert audio.capture_in_use() is False


def test_recorder_releases_mic_after_arecord_stops(load, monkeypatch, tmp_path):
    audio = load("audio")
    monkeypatch.setattr(audio, "SIM", False)
    order = []
    raw = tmp_path / "capture.raw"
    raw.write_bytes(b"raw")

    rec = audio.Recorder()
    rec.recording = True
    rec._proc = object()
    rec._raw_path = str(raw)
    monkeypatch.setattr(audio, "_stop_proc", lambda proc: order.append("stopped"))
    monkeypatch.setattr(audio, "_release_capture", lambda: order.append("released"))
    monkeypatch.setattr(audio, "_convert_raw", lambda src, dst: True)

    rec.stop()
    assert order == ["stopped", "released"]
