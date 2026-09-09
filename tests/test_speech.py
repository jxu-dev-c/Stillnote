import hashlib
import io
import json
import socket
import sys
import wave

import pytest
from meeting_app import speech
from meeting_app.storage import Store


def create_model_files(root, model="moss-0.9b"):
    directory = speech._model_path(root, model)
    directory.mkdir(parents=True)
    for name, file in speech.MODELS[model]["files"].items():
        with (directory / name).open("wb") as output:
            output.truncate(file["size"])
    (directory / ".verified").write_text(speech.MODELS[model]["revision"])


def test_status_is_offline_and_missing_tokenizer_is_not_ready(tmp_path, monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Status must not use the network")

    monkeypatch.setattr(socket, "create_connection", forbidden)
    monkeypatch.setattr(speech.urllib.request, "urlopen", forbidden)
    monkeypatch.setattr(speech.importlib.util, "find_spec", lambda name: object())
    assert not speech.speech_status(tmp_path)["ready"]
    monkeypatch.setattr(speech, "_moss_runtime_ready", lambda: True)
    create_model_files(tmp_path)
    assert speech.speech_status(tmp_path)["ready"]
    (speech._model_path(tmp_path, "moss-0.9b") / "tokenizer.json").unlink()
    assert not speech.speech_status(tmp_path)["ready"]


@pytest.mark.parametrize("model", ["../../remote", "https://example.com/model", "tiny", "base", "small"])
def test_model_names_are_allowlisted(tmp_path, model):
    with pytest.raises(ValueError, match="Unsupported"):
        speech.speech_status(tmp_path, model)


def test_catalog_order_and_sizes(tmp_path):
    models = speech.speech_status(tmp_path)["models"]
    assert [m["name"] for m in models] == ["MOSS 0.9B", "VibeVoice 1.5B", "VibeVoice 7B"]
    assert models[0]["download_mb"] < models[1]["download_mb"] < models[2]["download_mb"]
    assert all("ASR-Streaming" in m["url"] for m in models[1:])


@pytest.mark.parametrize("legacy", ["tiny", "base", "small", "tiny.en", "base.en", "small.en"])
def test_migrate_saved_selection_preserves_other_preferences(tmp_path, legacy):
    store = Store(tmp_path)
    settings = store.settings()
    settings["transcription"].update(model=legacy, language="fr", speaker_count=3)
    settings["summary"]["api_key"] = "preserve-me"
    with store.db() as db:
        db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)", (json.dumps(settings),))
    result = store.settings()
    assert result["transcription"] == dict(model="moss-0.9b", language="fr", speaker_count=3)
    assert result["summary"]["api_key"] == "preserve-me"


def test_moss_speakers_and_timestamps():
    rows = speech._parse_moss("[0.48][S01]你好[1.66][2][S02]Hello[4]")
    result = speech._normalize_segments(rows, 3)
    assert [s["text"] for s in result["segments"]] == ["你好", "Hello"]
    assert result["segments"][1]["end"] == 3
    assert len(result["speakers"]) == 2


@pytest.mark.parametrize("text", ["invalid", "[0][S01]unfinished", "[0][S01]ok[1]truncated"])
def test_moss_refuses_partial_output(text):
    with pytest.raises(RuntimeError, match="incomplete"):
        speech._parse_moss(text)


def test_vibevoice_speaker_changes_and_continuations():
    rows, speaker = speech._parse_vibe_chunk("Speaker 0: Hello. Speaker 1: 你好", 0, 2, "unknown")
    following, speaker = speech._parse_vibe_chunk("世界", 2, 4, speaker)
    result = speech._normalize_segments(rows + following, 4)
    assert [s["speaker"] for s in result["segments"]] == ["speaker_1", "speaker_2", "speaker_2"]
    assert result["segments"][-1]["text"] == "世界"
    assert speech._parse_vibe_chunk("", 4, 6, speaker) == ([], speaker)


class DownloadResponse(io.BytesIO):
    def geturl(self):
        return "https://official.example/model"


def test_model_download_verifies_checksum_and_removes_partial_files(tmp_path, monkeypatch):
    content = b"a complete model"
    destination = tmp_path / "model.onnx"
    monkeypatch.setattr(speech.urllib.request, "urlopen", lambda *args, **kwargs: DownloadResponse(content))
    with pytest.raises(RuntimeError, match="verification"):
        speech._download(
            "https://official.example/model", destination, len(content), "0" * 64, lambda p: None
        )
    assert not destination.exists()
    assert not destination.with_name("model.onnx.partial").exists()
    speech._download(
        "https://official.example/model",
        destination,
        len(content),
        hashlib.sha256(content).hexdigest(),
        lambda p: None,
    )
    assert destination.read_bytes() == content


def test_local_inference_never_downloads_or_connects(tmp_path, monkeypatch):
    import numpy as np

    def forbidden(*args, **kwargs):
        raise AssertionError("Inference must remain local")

    monkeypatch.setattr(socket.socket, "connect", forbidden)
    monkeypatch.setattr(speech.urllib.request, "urlopen", forbidden)
    monkeypatch.setattr(speech, "speech_status", lambda *args: {"ready": True})
    monkeypatch.setattr(speech, "_decode_audio", lambda *args: np.ones(32000, dtype=np.float32) * 0.1)
    monkeypatch.setattr(
        speech, "_run_moss", lambda *args: speech._parse_moss("[0][S01]Hello[1][1][S02]there.[2]")
    )
    source = tmp_path / "recording.webm"
    source.write_bytes(b"fake decoded audio")
    result = speech._transcribe_in_process(source, tmp_path, "moss-0.9b", "en", 2, lambda *args: None)
    assert result["duration"] == 2
    assert len(result["speakers"]) == 2


def test_missing_models_refuse_inference_without_downloading(tmp_path, monkeypatch):
    monkeypatch.setattr(speech.urllib.request, "urlopen", lambda *args: pytest.fail("Unexpected download"))
    with pytest.raises(RuntimeError, match="Download the speech models|dependencies"):
        speech.transcribe_audio(
            tmp_path / "sample.wav", tmp_path, "moss-0.9b", "auto", None, lambda *args: None
        )


def test_restricted_decoder_accepts_a_self_contained_wav(tmp_path):
    source = tmp_path / "recording.wav"
    with wave.open(str(source), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8000)
        output.writeframes(b"\x00\x01" * 8000)
    samples = speech._decode_audio(source)
    assert samples.shape == (16000,)


@pytest.mark.parametrize(
    "payload",
    [
        b"#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://example.com/private.wav\n#EXT-X-ENDLIST\n",
        b"ffconcat version 1.0\nfile 'https://example.com/private.wav'\n",
        b"ffconcat version 1.0\nfile '/etc/passwd'\n",
    ],
)
def test_restricted_decoder_refuses_playlists_disguised_as_recordings(tmp_path, payload):
    source = tmp_path / "recording.wav"
    source.write_bytes(payload)
    with pytest.raises(Exception):
        speech._decode_audio(source)


def test_native_worker_exit_is_contained_and_recording_is_preserved(tmp_path, monkeypatch):
    source = tmp_path / "recording.wav"
    source.write_bytes(b"stored recording")
    monkeypatch.setattr(speech, "speech_status", lambda *args: {"ready": True})
    real_popen = speech.subprocess.Popen

    def crashed_worker(command, **kwargs):
        return real_popen([sys.executable, "-c", "import os; os._exit(71)"], **kwargs)

    monkeypatch.setattr(speech.subprocess, "Popen", crashed_worker)
    with pytest.raises(RuntimeError, match="worker stopped unexpectedly"):
        speech.transcribe_audio(source, tmp_path, "moss-0.9b", "auto", None, lambda *args: None)
    assert source.read_bytes() == b"stored recording"


def test_worker_progress_and_result_are_forwarded_with_offline_environment(tmp_path, monkeypatch):
    source = tmp_path / "recording.wav"
    source.write_bytes(b"stored recording")
    monkeypatch.setattr(speech, "speech_status", lambda *args: {"ready": True})
    real_popen = speech.subprocess.Popen
    events = []

    def fake_worker(command, **kwargs):
        assert command[0] == str(speech._moss_python())
        assert kwargs["env"]["TRANSFORMERS_OFFLINE"] == "1"
        assert kwargs["env"]["HF_HUB_OFFLINE"] == "1"
        assert kwargs["env"]["ORT_DISABLE_TELEMETRY"] == "1"
        script = """
print('native diagnostic')
print('STILLNOTE_EVENT {"type":"progress","progress":65,"detail":"Identifying speakers"}')
print('STILLNOTE_EVENT {"type":"result","result":{"duration":2,"language":"en","speakers":{},"segments":[]}}')
"""
        return real_popen([sys.executable, "-c", script], **kwargs)

    monkeypatch.setattr(speech.subprocess, "Popen", fake_worker)
    result = speech.transcribe_audio(
        source, tmp_path, "moss-0.9b", "auto", None, lambda *event: events.append(event)
    )
    assert events == [(65, "Identifying speakers")]
    assert result["duration"] == 2


@pytest.mark.parametrize("count", [0, -1, 21, 2.5, True])
def test_invalid_speaker_counts_rejected_before_loading_models(tmp_path, count):
    with pytest.raises(ValueError, match="Speaker count"):
        speech.transcribe_audio(
            tmp_path / "audio.wav", tmp_path, "moss-0.9b", "auto", count, lambda *args: None
        )


def test_install_verifies_every_file_and_only_marks_complete_at_end(tmp_path, monkeypatch):
    model = "moss-0.9b"
    files = {"config.json": b"{}", "tokenizer.json": b"{}", "model.safetensors": b"weights"}
    spec = {
        **speech.MODELS[model],
        "files": {
            name: {"size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            for name, content in files.items()
        },
    }
    monkeypatch.setitem(speech.MODELS, model, spec)
    monkeypatch.setattr(
        speech.urllib.request,
        "urlopen",
        lambda request, **kwargs: DownloadResponse(files[request.full_url.rsplit("/", 1)[-1]]),
    )
    speech.install_models(tmp_path, model, lambda *args: None)
    assert speech._installed(tmp_path, model)
    (speech._model_path(tmp_path, model) / "model.safetensors").write_bytes(b"broken!")
    speech.install_models(tmp_path, model, lambda *args: None)
    assert (speech._model_path(tmp_path, model) / "model.safetensors").read_bytes() == b"weights"


def test_incomplete_install_does_not_advertise_readiness(tmp_path, monkeypatch):
    def fail(*args):
        raise RuntimeError("network interrupted")

    monkeypatch.setattr(speech, "_download", fail)
    with pytest.raises(RuntimeError):
        speech.install_models(tmp_path, "moss-0.9b", lambda *args: None)
    assert not speech._installed(tmp_path, "moss-0.9b")
    assert not speech.speech_status(tmp_path)["installing"]
    assert speech.speech_status(tmp_path)["error"]


@pytest.mark.parametrize("model_name", ["vibevoice-1.5b", "vibevoice-7b"])
def test_vibevoice_adapter_uses_local_checkpoint_and_trained_chunk_geometry(
    tmp_path, monkeypatch, model_name
):
    from contextlib import nullcontext
    from types import SimpleNamespace

    path = speech._model_path(tmp_path, model_name)
    path.mkdir(parents=True)
    (path / "preprocessor_config.json").write_text(
        json.dumps(
            {
                "target_sample_rate": 24000,
                "speech_tok_compress_ratio": 3200,
                "chunk_frames": 15,
                "lookahead_frames": 4,
            }
        )
    )
    tokenizer = object()

    def processor_load(location, **kwargs):
        assert location == str(path) and kwargs["local_files_only"]
        return SimpleNamespace(tokenizer=tokenizer)

    def stream(**kwargs):
        assert kwargs["tokenizer"] is tokenizer
        assert kwargs["sample_rate"] == 24000
        assert kwargs["chunk_duration"] == 2
        assert kwargs["text_audio_delay"] == pytest.approx(4 * 3200 / 24000)
        yield 0, 2, "Speaker 0: Hello"
        yield 1, 2, "Speaker 1: team."

    model = SimpleNamespace(streaming_generate=stream)
    model.to = lambda device: model
    model.eval = lambda: model

    def model_load(location, **kwargs):
        assert location == str(path) and kwargs["local_files_only"]
        return model

    monkeypatch.setitem(
        sys.modules,
        "torch",
        SimpleNamespace(
            cuda=SimpleNamespace(is_available=lambda: False),
            float32="float32",
            set_num_threads=lambda count: None,
            inference_mode=nullcontext,
            from_numpy=lambda a: a,
        ),
    )
    monkeypatch.setitem(
        sys.modules,
        "vibevoice.modular.modeling_vibevoice_asr",
        SimpleNamespace(VibeVoiceASRForConditionalGeneration=SimpleNamespace(from_pretrained=model_load)),
    )
    monkeypatch.setitem(
        sys.modules,
        "vibevoice.processor.vibevoice_asr_processor",
        SimpleNamespace(VibeVoiceASRProcessor=SimpleNamespace(from_pretrained=processor_load)),
    )
    rows = speech._run_vibevoice(path, [], "en", 2, lambda *args: None)
    assert [row["text"] for row in speech._normalize_segments(rows, 4)["segments"]] == ["Hello", "team."]
    assert rows[1]["start"] == 2


def test_moss_requires_its_own_runtime(tmp_path, monkeypatch):
    create_model_files(tmp_path)
    monkeypatch.setattr(speech.importlib.util, "find_spec", lambda name: object())
    monkeypatch.setattr(speech, "_moss_runtime_ready", lambda: False)
    status = speech.speech_status(tmp_path)
    assert status["transcription_ready"]
    assert not status["ready"]
    assert "MOSS runtime (.venv-moss)" in status["missing_dependencies"]


def test_cancellation_terminates_an_unresponsive_native_worker(tmp_path, monkeypatch):
    import threading
    import time

    source = tmp_path / "recording.wav"
    source.write_bytes(b"keep recording")
    monkeypatch.setattr(speech, "speech_status", lambda *a: {"ready": True})
    real_popen = speech.subprocess.Popen
    processes = []
    cancelled = threading.Event()

    def slow_worker(command, **kwargs):
        p = real_popen([sys.executable, "-c", "import time; time.sleep(60)"], **kwargs)
        processes.append(p)
        cancelled.set()
        return p

    monkeypatch.setattr(speech.subprocess, "Popen", slow_worker)
    start = time.monotonic()
    with pytest.raises(speech.TranscriptionCancelled):
        speech.transcribe_audio(
            source, tmp_path, "moss-0.9b", "en", None, lambda *a: None, cancel_event=cancelled
        )
    assert time.monotonic() - start < 5
    assert processes[0].poll() is not None
    assert source.read_bytes() == b"keep recording"


def test_cancelled_job_never_starts_a_worker(tmp_path, monkeypatch):
    import threading

    event = threading.Event()
    event.set()
    monkeypatch.setattr(speech.subprocess, "Popen", lambda *a, **k: pytest.fail("Unexpected worker"))
    with pytest.raises(speech.TranscriptionCancelled):
        speech.transcribe_audio(
            tmp_path / "recording.wav", tmp_path, "moss-0.9b", "en", None, lambda *a: None, cancel_event=event
        )
