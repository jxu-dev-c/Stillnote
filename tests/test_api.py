import io
import json
import time
import wave

import pytest
from fastapi.testclient import TestClient
from meeting_app import main
from meeting_app.storage import Store


def wav_bytes():
    result = io.BytesIO()
    with wave.open(result, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b"\0\0" * 16000)
    return result.getvalue()


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(main.speech, "speech_status", lambda *a: {"ready": True, "detail": "Ready"})
    app = main.create_app(tmp_path / "data", tmp_path / "models")
    with TestClient(app, base_url="http://127.0.0.1") as session:
        yield session


def upload(client):
    response = client.post(
        "/api/meetings",
        files={"file": ("meeting.wav", wav_bytes(), "audio/wav")},
        data={"title": "Planning / next steps"},
    )
    assert response.status_code == 201, response.text
    return response.json()


def wait_done(client, meeting_id):
    for _ in range(100):
        meeting = client.get(f"/api/meetings/{meeting_id}").json()
        if meeting["status"] not in {"transcribing", "summarizing"}:
            return meeting
        time.sleep(0.01)
    pytest.fail("Job did not finish")


def transcript():
    return [
        {
            "id": "one",
            "start": 0,
            "end": 0.5,
            "speaker": "speaker_0",
            "text": "We decided to release on Friday.",
        },
        {
            "id": "two",
            "start": 0.5,
            "end": 1,
            "speaker": "speaker_1",
            "text": "I will review the release checklist tomorrow.",
        },
    ]


def test_upload_persistence_audio_edit_and_exports(client):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    assert meeting["duration"] == 1
    assert client.get("/api/meetings").json()[0]["id"] == meeting["id"]
    assert client.get(base + "/audio").content == wav_bytes()
    response = client.patch(
        base,
        json={
            "segments": transcript(),
            "speakers": {"speaker_0": "Alex", "speaker_1": "Sam"},
            "notes": "Review before sharing.",
        },
    )
    assert response.status_code == 200
    assert response.json()["status"] == "transcribed"
    for format in ["md", "txt", "json", "srt"]:
        exported = client.get(base + "/export", params={"format": format})
        assert exported.status_code == 200
        assert "Alex" in exported.text and "Sam" in exported.text
        assert "attachment" in exported.headers["content-disposition"]
    assert "00:00:00,000 --> 00:00:00,500" in client.get(base + "/export?format=srt").text
    assert client.delete(base).status_code == 204
    assert client.get(base).status_code == 404
    assert client.get(base + "/audio").status_code == 404
    assert not list(client.app.state.store.audio_dir.iterdir())


def test_invalid_audio_is_removed(client):
    response = client.post("/api/meetings", files={"file": ("bad.wav", b"not real audio")})
    assert response.status_code == 415
    assert client.get("/api/meetings").json() == []
    assert not list(client.app.state.store.audio_dir.iterdir())


def test_cross_site_requests_and_dns_rebinding_are_rejected(client):
    for method in ["get", "post"]:
        response = getattr(client, method)("/api/meetings", headers={"Origin": "https://attacker.example"})
        assert response.status_code == 403
    assert client.get("/api/meetings", headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
    assert client.get("/api/health", headers={"Host": "attacker.example"}).status_code == 400
    assert client.get("/api/health", headers={"Origin": "http://127.0.0.1"}).status_code == 200


def test_agent_settings_preserve_partial_updates_and_reset_model_on_provider_change(client):
    initial = client.get("/api/settings").json()
    assert initial["summary"] == {"provider": "codex", "model": "gpt-5.6-luna", "reasoning_effort": "high"}
    assert set(initial["agents"]) == {"codex", "claude-code"}
    response = client.put("/api/settings", json={"summary": {"model": "custom-model", "reasoning_effort": "medium"}})
    assert response.status_code == 200
    client.put("/api/settings", json={"summary": {"reasoning_effort": "low"}})
    assert client.get("/api/settings").json()["summary"]["model"] == "custom-model"
    switched = client.put("/api/settings", json={"summary": {"provider": "claude-code"}}).json()
    assert switched["summary"] == {"provider": "claude-code", "model": "claude-sonnet-5", "reasoning_effort": "low"}
    client.put("/api/settings", json={"summary": {"model": "custom-claude"}})
    reset = client.put("/api/settings", json={"summary": {"model": "  "}}).json()
    assert reset["summary"]["model"] == "claude-sonnet-5"
    assert "api_key" not in str(reset) and "base_url" not in str(reset)
    client.put("/api/settings", json={"transcription": {"speaker_count": 2}})
    client.put("/api/settings", json={"transcription": {"speaker_count": None}})
    assert client.get("/api/settings").json()["transcription"]["speaker_count"] is None


@pytest.mark.parametrize("provider", ["codex", "claude-code"])
def test_summary_requires_transcript_and_remote_consent(client, monkeypatch, provider):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    assert client.post(base + "/summary", json={}).status_code == 409
    client.patch(base, json={"segments": transcript(), "speakers": {"speaker_0": "Alex", "speaker_1": "Sam"}})
    client.put("/api/settings", json={"summary": {"provider": provider, "model": "model"}})
    called = []

    def fake_summary(meeting, settings, allow_remote=False, *, video_path=None):
        assert video_path is None
        called.append(allow_remote)
        return {
            "overview": "Done",
            "key_points": [],
            "decisions": [],
            "action_items": [],
            "provider": settings["provider"],
            "model": settings["model"],
            "generated_at": "now",
        }

    monkeypatch.setattr(main.summarization, "summarize", fake_summary)
    assert client.post(base + "/summary", json={}).status_code == 403
    assert not called
    assert client.post(base + "/summary", json={"allow_remote": True}).status_code == 202
    assert wait_done(client, meeting["id"])["status"] == "complete"
    assert called == [True]
    # Transcript correction must not leave a stale summary presented as current.
    changed = client.patch(base, json={"speakers": {"speaker_0": "Pat", "speaker_1": "Sam"}}).json()
    assert changed["summary"] is None and changed["status"] == "transcribed"


@pytest.mark.parametrize("provider", ["codex", "claude-code"])
def test_video_path_preference_persists_per_meeting_and_controls_summary(client, monkeypatch, provider):
    meeting = upload(client)
    other = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    store = client.app.state.store
    assert meeting["summary_include_video_path"] is False
    video_path = store.video_dir / meeting["id"]
    video_path.write_bytes(b"PRIVATE VIDEO CONTENT")
    store.update(meeting["id"], video_url=base + "/video")
    client.patch(base, json={"segments": transcript()})
    client.put("/api/settings", json={"summary": {"provider": provider}})
    prompts = []

    def request(provider, model, effort, instructions, prompt, schema):
        prompts.append(prompt)
        return json.dumps({"overview": "Done", "key_points": [], "decisions": [], "action_items": []})

    monkeypatch.setattr(main.summarization, "request_json", request)
    for enabled in [False, True, False]:
        response = client.patch(base, json={"summary_include_video_path": enabled})
        assert response.status_code == 200
        assert Store(store.directory).get(meeting["id"])["summary_include_video_path"] is enabled
        assert client.get(f"/api/meetings/{other['id']}").json()["summary_include_video_path"] is False
        previous_calls = len(prompts)
        assert client.post(base + "/summary", json={}).status_code == 403
        assert len(prompts) == previous_calls
        assert client.post(base + "/summary", json={"allow_remote": True}).status_code == 202
        assert wait_done(client, meeting["id"])["status"] == "complete"
        assert (str(video_path.resolve()) in prompts[-1]) is enabled
        assert "PRIVATE VIDEO CONTENT" not in prompts[-1]


def test_video_path_preference_requires_saved_video_and_can_disable_after_loss(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    store = client.app.state.store
    monkeypatch.setattr(main.summarization, "request_json", lambda *args: pytest.fail("CLI must not start"))
    assert client.patch(base, json={"summary_include_video_path": True}).status_code == 409
    assert client.patch(base, json={"video_path": "/arbitrary/file"}).status_code == 422
    video_path = store.video_dir / meeting["id"]
    video_path.write_bytes(b"video")
    store.update(meeting["id"], video_url=base + "/video")
    assert client.patch(base, json={"summary_include_video_path": True, "segments": transcript()}).status_code == 200
    video_path.unlink()
    response = client.post(base + "/summary", json={"allow_remote": True})
    assert response.status_code == 409 and "Turn off" in response.json()["detail"]
    assert client.get(base).json()["status"] == "transcribed"
    assert client.patch(base, json={"summary_include_video_path": False}).status_code == 200


def test_legacy_meetings_default_to_no_video_path(client):
    meeting = upload(client)
    store = client.app.state.store
    del meeting["summary_include_video_path"]
    with store.db() as db:
        db.execute("UPDATE meetings SET data=? WHERE id=?", (json.dumps(meeting), meeting["id"]))
    assert client.get(f"/api/meetings/{meeting['id']}").json()["summary_include_video_path"] is False
    assert client.get("/api/meetings").json()[0]["summary_include_video_path"] is False


def test_agent_failure_preserves_previous_summary_and_hides_raw_errors(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    client.patch(base, json={"segments": transcript()})
    previous = {"overview": "Previous summary", "provider": "local", "model": "extractive-v1"}
    client.app.state.store.update(meeting["id"], summary=previous)

    def fail(*args, **kwargs):
        raise ValueError("PRIVATE TRANSCRIPT secret-token")

    monkeypatch.setattr(main.summarization, "summarize", fail)
    assert client.post(base + "/summary", json={"allow_remote": True}).status_code == 202
    final = wait_done(client, meeting["id"])
    assert final["status"] == "error"
    assert final["summary"] == previous
    assert "PRIVATE" not in final["error"] and "secret-token" not in final["error"]


@pytest.mark.parametrize("summary", [
    {"provider": "local"}, {"provider": "ollama"}, {"provider": "openai-compatible"},
    {"provider": "anthropic"}, {"reasoning_effort": "ultra"}, {"model": "bad\nmodel"},
])
def test_invalid_or_retired_summary_settings_rejected(client, summary):
    assert client.put("/api/settings", json={"summary": summary}).status_code == 422


def test_transcription_job_and_missing_models(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    monkeypatch.setattr(
        main.speech, "speech_status", lambda *a: {"ready": False, "detail": "Install models first"}
    )
    assert client.post(base + "/transcribe", json={}).status_code == 409
    monkeypatch.setattr(main.speech, "speech_status", lambda *a: {"ready": True})

    def transcribe(path, model_dir, model, language, speaker_count, progress, **kwargs):
        assert path.read_bytes() == wav_bytes()
        assert speaker_count == 2
        progress(50, "Separating speakers")
        return {
            "duration": 1,
            "language": "en",
            "speakers": {"speaker_0": "Speaker 1", "speaker_1": "Speaker 2"},
            "segments": transcript(),
        }

    monkeypatch.setattr(main.speech, "transcribe_audio", transcribe)
    assert client.post(base + "/transcribe", json={"speaker_count": 2}).status_code == 202
    final = wait_done(client, meeting["id"])
    assert final["status"] == "transcribed" and final["progress"] == 100
    assert len(final["speakers"]) == 2


def test_background_failure_and_busy_guard(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    client.app.state.store.update(meeting["id"], status="transcribing")
    assert client.delete(base).status_code == 409
    assert client.patch(base, json={"title": "Changed"}).status_code == 409
    assert client.post(base + "/transcribe", json={}).status_code == 409
    client.app.state.store.update(meeting["id"], status="ready")

    def fail(*args, **kwargs):
        raise ValueError("No speech detected. Try a clearer recording.")

    monkeypatch.setattr(main.speech, "transcribe_audio", fail)
    client.post(base + "/transcribe", json={})
    final = wait_done(client, meeting["id"])
    assert final["status"] == "error" and "No speech" in final["error"]
    assert client.get(base + "/audio").status_code == 200


def test_restart_recovers_interrupted_meetings(tmp_path):
    store = Store(tmp_path / "data")
    meeting = store.create("Restart test", "audio.wav", "auto", None, 1)
    store.update(meeting["id"], status="transcribing")
    restarted = Store(tmp_path / "data")
    result = restarted.get(meeting["id"])
    assert result["status"] == "error" and "retry" in result["error"]


def test_transcript_validation(client):
    base = "/api/meetings/" + upload(client)["id"]
    bad = transcript()
    bad[1]["id"] = bad[0]["id"]
    assert client.patch(base, json={"segments": bad}).status_code == 422
    bad[1]["id"] = "two"
    bad[1]["end"] = 500
    assert client.patch(base, json={"segments": bad}).status_code == 422
    assert client.patch(base, json={"speakers": {"a": ""}}).status_code == 422
    assert client.patch(base, json={"title": " "}).status_code == 422


def test_imported_playlists_cannot_load_remote_audio(client):
    playlist = b"#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://example.invalid/private.ts\n#EXT-X-ENDLIST\n"
    response = client.post("/api/meetings", files={"file": ("audio.m3u8", playlist, "application/x-mpegURL")})
    assert response.status_code == 415
    assert not list(client.app.state.store.audio_dir.iterdir())


def test_upload_limit_cleans_up_partial_file(client, monkeypatch):
    monkeypatch.setattr(main, "MAX_AUDIO_BYTES", 20)
    response = client.post("/api/meetings", files={"file": ("large.wav", wav_bytes(), "audio/wav")})
    assert response.status_code == 413
    assert not list(client.app.state.store.audio_dir.iterdir())


def test_silent_recording_finishes_with_actionable_message(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    monkeypatch.setattr(
        main.speech,
        "transcribe_audio",
        lambda *a, **kwargs: {"duration": 1, "language": "en", "speakers": {}, "segments": []},
    )
    assert client.post(base + "/transcribe", json={}).status_code == 202
    final = wait_done(client, meeting["id"])
    assert final["status"] == "error"
    assert final["stage"] == "No speech detected"
    assert "audio is saved" in final["error"]
    assert client.get(base + "/audio").status_code == 200


def test_audio_response_never_uses_active_document_mime(client):
    meeting = client.post("/api/meetings", files={"file": ("recording.html", wav_bytes())}).json()
    response = client.get(meeting["audio_url"])
    assert response.headers["content-type"] == "application/octet-stream"
    assert response.headers["x-content-type-options"] == "nosniff"


def test_unsuccessful_retranscription_keeps_existing_corrections(client, monkeypatch):
    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    client.patch(base, json={"segments": transcript(), "speakers": {"speaker_0": "Alex", "speaker_1": "Sam"}})
    monkeypatch.setattr(
        main.speech,
        "transcribe_audio",
        lambda *a, **kwargs: {"duration": 1, "language": "en", "speakers": {}, "segments": []},
    )
    client.post(base + "/transcribe", json={})
    final = wait_done(client, meeting["id"])
    assert final["status"] == "error"
    assert final["segments"] == transcript()
    assert final["speakers"]["speaker_0"] == "Alex"


@pytest.mark.parametrize("model", ["moss-0.9b", "vibevoice-1.5b", "vibevoice-7b"])
def test_new_roster_settings_round_trip(client, model):
    response = client.put("/api/settings", json={"transcription": {"model": model}})
    assert response.status_code == 200
    assert client.get("/api/settings").json()["transcription"]["model"] == model


@pytest.mark.parametrize("model", ["tiny", "base", "small", "tiny.en", "base.en", "small.en"])
def test_old_roster_rejected_by_settings_and_install(client, model):
    assert client.put("/api/settings", json={"transcription": {"model": model}}).status_code == 422
    assert client.post("/api/models/install", json={"model": model}).status_code == 422


def test_cancel_transcription_preserves_existing_work(client, monkeypatch):
    import threading

    meeting = upload(client)
    base = f"/api/meetings/{meeting['id']}"
    store = client.app.state.store
    store.update(
        meeting["id"],
        segments=transcript(),
        speakers={"speaker_0": "Renamed"},
        notes="Keep these notes",
        summary={"overview": "Keep this summary"},
    )
    started = threading.Event()

    def slow(*args, cancel_event):
        started.set()
        assert cancel_event.wait(3)
        raise main.speech.TranscriptionCancelled("Stopped")

    monkeypatch.setattr(main.speech, "transcribe_audio", slow)
    assert client.post(base + "/transcribe", json={}).status_code == 202
    assert started.wait(1)
    assert client.post(base + "/transcribe/cancel", json={}).status_code == 202
    final = wait_done(client, meeting["id"])
    assert final["status"] == "complete"
    assert final["stage"] == "Transcription stopped"
    assert final["segments"] == transcript()
    assert final["notes"] == "Keep these notes"
    assert final["summary"]["overview"] == "Keep this summary"
    assert final["error"] is None
    assert client.get(base + "/audio").content == wav_bytes()
    assert client.post(base + "/transcribe/cancel", json={}).status_code == 409


def test_cancel_queued_transcription_immediately(client, monkeypatch):
    import threading

    first, second = upload(client), upload(client)
    started = threading.Event()

    def slow(*args, cancel_event):
        started.set()
        assert cancel_event.wait(3)
        raise main.speech.TranscriptionCancelled("Stopped")

    monkeypatch.setattr(main.speech, "transcribe_audio", slow)
    first_url = f"/api/meetings/{first['id']}"
    second_url = f"/api/meetings/{second['id']}"
    assert client.post(first_url + "/transcribe", json={}).status_code == 202
    assert started.wait(1)
    assert client.post(second_url + "/transcribe", json={}).status_code == 202
    response = client.post(second_url + "/transcribe/cancel", json={})
    assert response.status_code == 202 and response.json()["status"] == "ready"
    assert client.get(first_url).json()["status"] == "transcribing"
    client.post(first_url + "/transcribe/cancel", json={})
    assert wait_done(client, first["id"])["stage"] == "Transcription stopped"
