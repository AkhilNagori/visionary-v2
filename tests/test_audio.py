"""audio.py contract in SIM: SentenceSpeaker sentence splitting + ordering,
the Recorder sim path, and record_until_silence returning a real WAV."""

import os
import wave

import pytest


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
