"""audio.py contract in SIM: SentenceSpeaker sentence splitting + ordering,
the Recorder sim path, and record_until_silence returning a real WAV."""

import math
import os
import shutil
import struct
import subprocess
import wave

import pytest


def _stereo_s32(left, right, frames=480):
    return struct.pack("<ii", left, right) * frames


def _tone_s32(frequency, level=0.01, seconds=0.25):
    frames = int(48000 * seconds)
    scale = level * (1 << 31)
    return b"".join(
        struct.pack("<ii", int(scale * math.sin(2.0 * math.pi * frequency
                                                * index / 48000.0)), 0)
        for index in range(frames)
    )


def _wav_rms(path):
    with wave.open(str(path), "rb") as reader:
        frames = reader.readframes(reader.getnframes())
        samples = struct.unpack("<%dh" % (len(frames) // 2), frames)
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


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


def test_beep_can_finish_before_capture_starts(load, monkeypatch, tmp_path):
    audio = load("audio")
    monkeypatch.setattr(audio, "SIM", False)
    sound_dir = tmp_path / "sounds"
    sound_dir.mkdir()
    sound = sound_dir / "rec_start.wav"
    sound.write_bytes(b"RIFF")
    monkeypatch.setattr(audio.state, "HOME", str(tmp_path))
    calls = []
    monkeypatch.setattr(
        audio, "play", lambda path, wait=False: calls.append((path, wait)))

    audio.beep("rec_start", wait=True)

    assert calls == [(str(sound), True)]


def test_hold_to_ask_finishes_start_cue_before_opening_mic(load, monkeypatch):
    ask = load("modes.ask")
    events = []
    monkeypatch.setattr(
        ask.audio, "beep",
        lambda name, wait=False: events.append(("beep", name, wait)))
    monkeypatch.setattr(ask._rec, "start", lambda: events.append(("start",)))

    ask.ask_begin()

    assert events == [("beep", "rec_start", True), ("start",)]


def test_recorder_finishes_start_cue_before_opening_mic(load, monkeypatch):
    recorder = load("modes.recorder")
    events = []
    monkeypatch.setattr(recorder._rec, "recording", False)
    monkeypatch.setattr(
        recorder.audio, "beep",
        lambda name, wait=False: events.append(("beep", name, wait)))
    monkeypatch.setattr(
        recorder._rec, "start", lambda: events.append(("start",)))

    recorder.toggle()

    assert events == [("beep", "rec_start", True), ("start",)]


def test_recorder_closes_mic_before_stop_cue(load, monkeypatch):
    recorder = load("modes.recorder")
    events = []

    class StopAfterCue(Exception):
        pass

    monkeypatch.setattr(
        recorder._rec, "stop", lambda: events.append(("stop",)) or "/tmp/test.wav")
    monkeypatch.setattr(
        recorder.audio, "beep",
        lambda name, wait=False: events.append(("beep", name, wait)))

    def stop_after_cue(text, wait=True):
        events.append(("speak", text))
        raise StopAfterCue

    monkeypatch.setattr(recorder.audio, "speak", stop_after_cue)

    with pytest.raises(StopAfterCue):
        recorder._stop()

    assert events[:2] == [("stop",), ("beep", "rec_stop", False)]


@pytest.mark.parametrize("pipeline_name", ["_run_ask", "_run_listen"])
def test_pack_pipeline_finishes_start_cue_before_opening_mic(
        load, monkeypatch, pipeline_name):
    packs = load("packs")
    events = []
    monkeypatch.setattr(packs.brain, "is_online", lambda: True)
    monkeypatch.setattr(
        packs.audio, "beep",
        lambda name, wait=False: events.append(("beep", name, wait)))
    monkeypatch.setattr(
        packs.audio, "record_until_silence",
        lambda **kwargs: events.append(("record", kwargs)) or None)
    monkeypatch.setattr(packs.audio, "speak", lambda *args, **kwargs: None)

    getattr(packs, pipeline_name)({"name": "Test", "prompt": "Test"})

    assert events[:2] == [
        ("beep", "rec_start", True),
        ("record", {"preserve_ambiguous": True}),
    ]


def test_captions_finishes_mode_cue_before_opening_mic(load, monkeypatch):
    captions = load("modes.captions")
    events = []

    class StopAfterFirstCapture:
        def __init__(self):
            self.calls = 0

        def is_set(self):
            self.calls += 1
            return self.calls > 1

    monkeypatch.setattr(
        captions.audio, "beep",
        lambda name, wait=False: events.append(("beep", name, wait)))
    monkeypatch.setattr(
        captions.audio, "record_until_silence",
        lambda **kwargs: events.append(("record", kwargs)) or None)

    captions._loop(StopAfterFirstCapture())

    assert events == [
        ("beep", "ok", True),
        ("record", {"preserve_ambiguous": False}),
    ]


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


def test_rms_uses_only_configured_live_i2s_channel(load, monkeypatch):
    audio = load("audio")
    level = 0.01
    sample = int(level * (1 << 31))
    data = _stereo_s32(sample, 0)

    assert audio._rms_level(data) == pytest.approx(level, rel=0.001)

    monkeypatch.setenv("VISIONARY_MIC_CHANNEL", "2")
    assert audio._rms_level(data) == 0.0


def test_sox_pipeline_selects_filters_resamples_gains_and_limits(
        load, monkeypatch, tmp_path):
    audio = load("audio")
    raw = tmp_path / "capture.raw"
    wav = tmp_path / "capture.wav"
    raw.write_bytes(_stereo_s32(1, 0))
    calls = []

    def fake_run(command, **kwargs):
        calls.append(command)
        wav.write_bytes(b"RIFF")
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(audio.subprocess, "run", fake_run)

    assert audio._convert_raw(str(raw), str(wav)) is True
    assert calls[0][1:8] == [
        "-t", "raw", "-L", "-r", "48000", "-e", "signed-integer"]
    assert calls[0][-12:] == [
        "remix", "1", "highpass", "100", "rate", "-v", "16000",
        "gain", "-l", "24", "gain", "-1",
    ]


def test_sox_failure_is_visible_instead_of_using_different_processing(
        load, monkeypatch, tmp_path, capsys):
    audio = load("audio")
    raw = tmp_path / "capture.raw"
    wav = tmp_path / "capture.wav"
    raw.write_bytes(_stereo_s32(1, 0))

    def fake_run(command, **kwargs):
        return subprocess.CompletedProcess(
            command, 2, stderr=b"sox FAIL formats: test failure")

    monkeypatch.setattr(audio.subprocess, "run", fake_run)

    assert audio._convert_raw(str(raw), str(wav)) is False
    assert "sox FAIL formats: test failure" in capsys.readouterr().err


@pytest.mark.skipif(shutil.which("sox") is None, reason="SoX is not installed")
def test_real_sox_pipeline_filters_gains_and_writes_mono_16k(
        load, monkeypatch, tmp_path):
    audio = load("audio")
    low_raw = tmp_path / "rumble.raw"
    voice_raw = tmp_path / "voice.raw"
    low_wav = tmp_path / "rumble.wav"
    voice_unity_wav = tmp_path / "voice-unity.wav"
    voice_gain_wav = tmp_path / "voice-gain.wav"
    low_raw.write_bytes(_tone_s32(30))
    voice_raw.write_bytes(_tone_s32(1000))
    monkeypatch.setenv("VISIONARY_MIC_CHANNEL", "1")
    monkeypatch.setenv("VISIONARY_MIC_HIGHPASS_HZ", "100")

    monkeypatch.setenv("VISIONARY_MIC_GAIN_DB", "0")
    assert audio._convert_raw(str(low_raw), str(low_wav)) is True
    assert audio._convert_raw(str(voice_raw), str(voice_unity_wav)) is True

    monkeypatch.setenv("VISIONARY_MIC_GAIN_DB", "24")
    assert audio._convert_raw(str(voice_raw), str(voice_gain_wav)) is True

    with wave.open(str(voice_gain_wav), "rb") as reader:
        assert reader.getnchannels() == 1
        assert reader.getsampwidth() == 2
        assert reader.getframerate() == 16000
    assert _wav_rms(voice_unity_wav) > _wav_rms(low_wav) * 2.5
    assert _wav_rms(voice_gain_wav) / _wav_rms(voice_unity_wav) == pytest.approx(
        10.0 ** (24.0 / 20.0), rel=0.04)


def test_vad_meter_highpass_reduces_frame_rumble(load, monkeypatch):
    audio = load("audio")
    monkeypatch.setenv("VISIONARY_MIC_CHANNEL", "1")
    monkeypatch.setenv("VISIONARY_MIC_HIGHPASS_HZ", "100")

    rumble = audio._VadLevelMeter().level(_tone_s32(30))
    voice_band = audio._VadLevelMeter().level(_tone_s32(1000))

    assert voice_band > rumble * 2.5


def test_adaptive_vad_detects_measured_speech_and_tolerates_transient(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    speech = 10.0 ** (-51.06 / 20.0)
    transient = 10.0 ** (-49.0 / 20.0)
    vad = audio._AdaptiveVad(chunk_s=0.1, trailing_s=1.5)

    assert all(vad.update(noise) == (False, False) for _ in range(5))
    assert vad.update(speech) == (False, False)
    assert vad.update(speech) == (False, False)
    confirmed, stopped = vad.update(speech)
    assert confirmed is True
    assert stopped is False

    stopped = False
    for level in ([noise] * 5 + [transient] + [noise] * 10):
        _, stopped = vad.update(level)
        if stopped:
            break
    assert stopped is True


def test_adaptive_vad_does_not_confirm_one_frame_click(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    click = 10.0 ** (-33.0 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(5):
        vad.update(noise)
    vad.update(click)
    vad.update(noise)

    assert vad.heard is False
    assert vad.possible_speech is True  # preserve ambiguous audio; never gate it
    assert vad.finish() is True


def test_adaptive_vad_ignores_two_chunk_handling_bump(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    bump = 10.0 ** (-33.0 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(5):
        vad.update(noise)
    vad.update(bump)
    vad.update(bump)
    for _ in range(5):
        vad.update(noise)

    assert vad.heard is False
    assert vad.finish() is True  # retain the uncertain audio for cloud STT


def test_adaptive_vad_sustained_weak_speech_is_not_learned_as_noise(load):
    audio = load("audio")
    noise_db = -56.70
    noise = 10.0 ** (noise_db / 20.0)
    weak_speech = 10.0 ** ((noise_db + 2.5) / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(5):
        vad.update(noise)
    for _ in range(4):
        assert vad.update(weak_speech) == (False, False)
    confirmed, stopped = vad.update(weak_speech)

    assert confirmed is True
    assert stopped is False
    assert vad.heard is True
    assert vad.noise_db == pytest.approx(noise_db, abs=0.2)


def test_adaptive_vad_does_not_timeout_when_speech_starts_at_quiet_boundary(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    speech = 10.0 ** (-51.06 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(49):
        vad.update(noise)
    assert vad.update(speech) == (False, False)
    assert vad.no_speech_timed_out(captured_s=5.0, max_s=15.0) is False
    assert vad.update(speech) == (False, False)
    confirmed, _ = vad.update(speech)

    assert confirmed is True
    assert vad.heard is True


def test_adaptive_vad_single_dropout_does_not_lower_floor_and_false_trigger(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    dropout = 10.0 ** (-90.0 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(5):
        vad.update(noise)
    vad.update(dropout)
    for _ in range(10):
        vad.update(noise)

    assert vad.heard is False
    assert vad.noise_db == pytest.approx(-56.70, abs=0.2)


def test_adaptive_vad_quiet_room_times_out_without_upload(load):
    audio = load("audio")
    noise = 10.0 ** (-56.70 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(50):
        vad.update(noise)

    assert vad.no_speech_timed_out(captured_s=5.0, max_s=15.0) is True
    assert vad.finish() is False


def test_adaptive_vad_loud_steady_calibration_is_ambiguous_not_speech(load):
    audio = load("audio")
    steady_noise = 10.0 ** (-50.0 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(15):
        vad.update(steady_noise)

    assert vad.heard is False
    assert vad.possible_speech is False
    assert vad.awaiting_calibration_drop is True
    assert vad.finish() is False  # no dynamics: do not repeatedly upload room noise
    assert vad.finish(preserve_unresolved=True) is True  # deliberate one-shot


def test_adaptive_vad_rechecks_immediate_speech_during_calibration(load):
    audio = load("audio")
    speech = 10.0 ** (-51.06 / 20.0)
    quiet = 10.0 ** (-56.70 / 20.0)
    vad = audio._AdaptiveVad()

    results = [vad.update(speech) for _ in range(5)]

    assert results[-1][0] is False
    assert vad.heard is False
    assert vad.awaiting_calibration_drop is True

    # More than the ordinary five-second no-speech window must not truncate an
    # utterance that began during calibration. Its eventual drop confirms it.
    for _ in range(55):
        assert vad.update(speech) == (False, False)
        assert vad.awaiting_calibration_drop is True
    assert vad.no_speech_timed_out(captured_s=6.0, max_s=15.0) is False
    assert vad.finish(preserve_unresolved=True) is True
    assert vad.update(quiet) == (False, False)
    confirmed, stopped = vad.update(quiet)
    assert confirmed is True
    assert stopped is False
    assert vad.heard is True
    assert vad.awaiting_calibration_drop is False
    assert vad.noise_db == pytest.approx(-56.70, abs=0.2)
    for _ in range(20):
        _, stopped = vad.update(speech)
        assert stopped is False
    assert vad.finish() is True


def test_adaptive_vad_quiet_constant_initial_voice_is_preserved_only_on_demand(load):
    audio = load("audio")
    quiet_voice = 10.0 ** (-53.5 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(60):
        vad.update(quiet_voice)

    assert vad.heard is False
    assert vad.awaiting_calibration_drop is True
    assert vad.no_speech_timed_out(captured_s=6.0, max_s=15.0) is False
    assert vad.finish() is False
    assert vad.finish(preserve_unresolved=True) is True


def test_adaptive_vad_loud_calibration_dynamics_cannot_false_stop_voice(load):
    audio = load("audio")
    baseline_voice = 10.0 ** (-51.0 / 20.0)
    louder_syllable = 10.0 ** (-47.0 / 20.0)
    vad = audio._AdaptiveVad()

    for _ in range(5):
        vad.update(baseline_voice)
    for _ in range(3):
        vad.update(louder_syllable)
    assert vad.heard is True

    for _ in range(20):
        _, stopped = vad.update(baseline_voice)
        assert stopped is False
    assert vad.finish() is True


def test_adaptive_vad_in_calibration_dynamics_cannot_false_stop_voice(load):
    audio = load("audio")
    vad = audio._AdaptiveVad()

    for level_db in (-54.0, -54.0, -50.0, -50.0, -50.0):
        vad.update(10.0 ** (level_db / 20.0))
    assert vad.heard is True

    baseline_voice = 10.0 ** (-54.0 / 20.0)
    for _ in range(20):
        _, stopped = vad.update(baseline_voice)
        assert stopped is False
    assert vad.finish() is True


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
