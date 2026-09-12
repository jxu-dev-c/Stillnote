"""Exercise native capture with a real subprocess and synthetic media, without OS permissions."""

import os
import sys
import time
import wave
from fractions import Fraction

import av
import numpy as np
import pytest
from fastapi.testclient import TestClient
from meeting_app import main, recording
from meeting_app.schemas import RecordingRequest
from meeting_app.storage import Store


def pcm(path, samples):
    with wave.open(str(path), "wb") as target:
        target.setparams((1, 2, recording.RATE, 0, "NONE", "not compressed"))
        target.writeframes(np.asarray(samples, dtype="<i2").tobytes())


def screen(path):
    with av.open(str(path), "w") as output:
        stream = output.add_stream("libx264", rate=15)
        stream.width = 64
        stream.height = 48
        stream.pix_fmt = "yuv420p"
        for index in range(15):
            frame = av.VideoFrame.from_ndarray(np.full((48, 64, 3), index * 12, dtype=np.uint8), format="rgb24")
            frame.pts = index
            frame.time_base = Fraction(1, 15)
            for packet in stream.encode(frame):
                output.mux(packet)
        for packet in stream.encode():
            output.mux(packet)


@pytest.fixture
def fake_capture(tmp_path, monkeypatch):
    helper = tmp_path / "capture-helper"
    helper.write_text(f"#!{sys.executable}\n" + '''
import json, pathlib, sys, wave
folder = pathlib.Path(sys.argv[2])
options = json.loads((folder / "options.json").read_text())
def event(status, **extra):
    print(json.dumps({"event": "state", "status": status, **extra}), flush=True)
if options["title"] == "denied":
    event("stopped", error="Microphone permission denied")
    sys.exit(1)
for name in (["microphone.wav", "system.wav"] if options["system_audio"] else ["microphone.wav"]):
    with wave.open(str(folder / name), "wb") as output:
        output.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
        output.writeframes(b"\\x00\\x20" * 48000)
event("recording")
print(json.dumps({"event": "levels", "elapsed": 1, "levels": {"microphone": {"rms": 0.25, "peak": 0.25}}}), flush=True)
if options["title"] == "crash":
    sys.exit(2)
for line in sys.stdin:
    command = line.strip()
    if command == "stop": break
    if command == "pause": event("paused", elapsed=1)
    if command == "resume": event("recording", elapsed=1)
event("stopped", elapsed=1)
''')
    helper.chmod(0o700)
    monkeypatch.setattr(recording, "HELPER", helper)
    monkeypatch.setattr(recording, "capabilities", lambda: {
        "available": True, "reason": None, "microphones": [{"id": "mic", "name": "Test microphone"}],
        "displays": [{"id": 1, "name": "Test display"}], "default_display_id": 1,
    })
    return helper


@pytest.fixture
def client(tmp_path, monkeypatch, fake_capture):
    monkeypatch.setattr(main.speech, "speech_status", lambda *args: {"ready": False})
    with TestClient(main.create_app(tmp_path / "data", tmp_path / "models"), base_url="http://127.0.0.1") as client:
        yield client


def wait_status(manager, status):
    for _ in range(200):
        session = manager.current()
        if session and session["status"] == status:
            return session
        time.sleep(0.01)
    pytest.fail(f"Recording never became {status}: {manager.current()}")


def start(client, **options):
    response = client.post("/api/recordings", json={"title": "Planning", **options})
    assert response.status_code == 201, response.text
    wait_status(client.app.state.capture, "recording")
    return response.json()["id"]


def test_capture_pause_resume_save_retry_and_delete(client):
    assert client.get("/api/recordings/capabilities").json()["microphones"][0]["id"] == "mic"
    session_id = start(client)
    manager = client.app.state.capture
    assert client.post("/api/recordings", json={}).status_code == 409
    assert client.post(f"/api/recordings/{session_id}/pause").status_code == 200
    assert wait_status(manager, "paused")["elapsed"] == 1
    assert client.post(f"/api/recordings/{session_id}/resume").status_code == 200
    wait_status(manager, "recording")
    process = manager.process
    response = client.post(f"/api/recordings/{session_id}/stop")
    assert response.status_code == 200, response.text
    meeting = response.json()
    assert meeting["duration"] == 1
    assert meeting["status"] == "ready"
    assert meeting["title"] == "Planning"
    assert meeting["video_url"] is None
    assert process.poll() == 0
    assert client.get("/api/recordings/current").json() is None
    assert client.post(f"/api/recordings/{session_id}/stop").json() == meeting
    assert len(client.get("/api/meetings").json()) == 1
    assert client.get(meeting["audio_url"]).content[:4] == b"RIFF"
    assert client.get(f"/api/meetings/{session_id}/video").status_code == 404
    assert not (manager.directory / session_id).exists()
    audio_path = manager.store.audio_dir / session_id
    assert os.stat(audio_path).st_mode & 0o777 == 0o600
    assert client.delete(f"/api/meetings/{session_id}").status_code == 204
    assert not audio_path.exists()


def test_video_contains_mixed_audio_playback_range_and_delete(client):
    session_id = start(client, screen_video=True)
    manager = client.app.state.capture
    screen(manager.directory / session_id / "screen.mp4")
    response = client.post(f"/api/recordings/{session_id}/stop")
    assert response.status_code == 200, response.text
    meeting = response.json()
    assert meeting["video_url"]
    with av.open(str(manager.store.video_dir / session_id)) as movie:
        assert len(movie.streams.video) == len(movie.streams.audio) == 1
        assert len(list(movie.decode(video=0))) == 15
    with av.open(str(manager.store.video_dir / session_id)) as movie:
        samples = np.concatenate([frame.to_ndarray().flatten() for frame in movie.decode(audio=0)])
        assert np.mean(np.abs(samples)) > 0.15
    video_response = client.get(meeting["video_url"], headers={"Range": "bytes=0-99"})
    assert video_response.status_code == 206
    assert len(video_response.content) == 100
    assert video_response.headers["content-type"] == "video/mp4"
    client.delete(f"/api/meetings/{session_id}")
    assert not (manager.store.video_dir / session_id).exists()


def test_invalid_screen_preserves_audio_with_visible_warning(client):
    session_id = start(client, screen_video=True)
    meeting = client.post(f"/api/recordings/{session_id}/stop").json()
    assert meeting["video_url"] is None
    assert "video could not be recovered" in meeting["error"]
    assert client.get(meeting["audio_url"]).status_code == 200


def test_discard_stops_process_and_removes_unsaved_media(client):
    session_id = start(client)
    manager = client.app.state.capture
    process = manager.process
    assert client.delete(f"/api/recordings/{session_id}").status_code == 204
    assert process.poll() == 0
    assert not (manager.directory / session_id).exists()
    assert client.get("/api/meetings").json() == []


def test_permission_denial_can_be_discarded_and_retried(client):
    response = client.post("/api/recordings", json={"title": "denied"})
    session_id = response.json()["id"]
    session = wait_status(client.app.state.capture, "stopped")
    assert "permission denied" in session["error"]
    assert client.post(f"/api/recordings/{session_id}/stop").status_code == 422
    assert client.get("/api/recordings/current").json()["id"] == session_id
    assert client.delete(f"/api/recordings/{session_id}").status_code == 204
    start(client)


def test_unexpected_exit_retains_audio_and_status(client):
    response = client.post("/api/recordings", json={"title": "crash"})
    session_id = response.json()["id"]
    session = wait_status(client.app.state.capture, "stopped")
    assert "unexpectedly" in session["error"]
    meeting = client.post(f"/api/recordings/{session_id}/stop").json()
    assert meeting["duration"] == 1
    assert "unexpectedly" in meeting["error"]


def test_shutdown_and_restart_recovers_recording(tmp_path, fake_capture):
    store = Store(tmp_path / "data")
    manager = recording.RecordingManager(store)
    options = RecordingRequest(title="Restart").model_dump()
    session = manager.start(options)
    wait_status(manager, "recording")
    process = manager.process
    manager.close()
    assert process.poll() == 0
    recovered = recording.RecordingManager(Store(tmp_path / "data"))
    assert recovered.current()["id"] == session["id"]
    assert recovered.current()["status"] == "stopped"
    assert recovered.finish(session["id"])["duration"] == 1


def test_failed_save_can_retry_without_losing_sources(client, monkeypatch):
    session_id = start(client)
    manager = client.app.state.capture
    original = manager.store.create
    monkeypatch.setattr(manager.store, "create", lambda *args, **kw: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError, match="disk full"):
        manager.finish(session_id)
    assert (manager.directory / session_id / "microphone.wav").exists()
    assert manager.current()["id"] == session_id
    monkeypatch.setattr(manager.store, "create", original)
    assert manager.finish(session_id)["id"] == session_id


def test_sources_are_aligned_and_mix_does_not_clip(tmp_path):
    pcm(tmp_path / "microphone.wav", [32767] * 48000 + [0] * 48000)
    pcm(tmp_path / "system.wav", [32767] * 24000 + [0] * 48000 + [-32768] * 24000)
    result = tmp_path / "mixed.wav"
    assert recording.mix_audio(tmp_path, result) == 2
    with wave.open(str(result)) as audio:
        samples = np.frombuffer(audio.readframes(96000), dtype="<i2")
    assert samples[0] == 32767
    assert samples[30000] == 16383
    assert samples[60000] == 0
    assert samples[80000] == -16384


def test_single_source_keeps_volume_and_missing_audio_is_rejected(tmp_path):
    with pytest.raises(recording.RecordingError, match="No audio"):
        recording.mix_audio(tmp_path, tmp_path / "mix.wav")
    pcm(tmp_path / "microphone.wav", [2000] * 600)
    recording.mix_audio(tmp_path, tmp_path / "mix.wav")
    with wave.open(str(tmp_path / "mix.wav")) as audio:
        assert np.frombuffer(audio.readframes(600), dtype="<i2").tolist() == [2000] * 600


def test_invalid_device_and_cross_site_capture_are_rejected(client):
    assert client.post("/api/recordings", json={"microphone_id": "gone"}).status_code == 422
    assert client.post("/api/recordings", json={"display_id": 999}).status_code == 422
    assert client.post("/api/recordings", json={"title": " "}).status_code == 422
    assert client.post("/api/recordings", json={}, headers={"Origin": "https://evil.test"}).status_code == 403
    assert client.get("/api/recordings/current").json() is None
    assert client.post("/api/recordings/unknown/stop").status_code == 404


def test_unavailable_platform_and_missing_helper(monkeypatch):
    monkeypatch.setattr(recording.platform, "system", lambda: "Linux")
    assert not recording.capabilities()["available"]
    monkeypatch.setattr(recording.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(recording.platform, "mac_ver", lambda: ("14.0", "", ""))
    assert "macOS 15" in recording.capabilities()["reason"]
