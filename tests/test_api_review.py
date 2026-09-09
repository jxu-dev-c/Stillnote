"""Regressions found while reviewing API privacy and recovery behavior."""

import pytest
from fastapi.testclient import TestClient
from meeting_app import main


@pytest.fixture
def review_client(tmp_path, monkeypatch):
    monkeypatch.setattr(main.speech, "speech_status", lambda *args: {"ready": True})
    app = main.create_app(tmp_path / "data", tmp_path / "models")
    with TestClient(app, base_url="http://127.0.0.1") as client:
        yield client


def test_settings_validation_does_not_echo_submitted_api_key(review_client):
    secret = "sensitive-api-key-" + "X" * 4100
    response = review_client.put("/api/settings", json={"summary": {"api_key": secret}})
    assert response.status_code == 422
    assert secret not in response.text
    assert "sensitive-api-key" not in response.text
    assert "api_key" in response.text  # Preserve the useful field location.


def test_settings_invalid_enum_does_not_echo_secret_mistakenly_pasted_in_provider(review_client):
    secret = "sensitive-api-key-mistakenly-pasted-as-provider"
    response = review_client.put("/api/settings", json={"summary": {"provider": secret, "api_key": secret}})
    assert response.status_code == 422
    assert secret not in response.text
    assert "provider" in response.text


@pytest.mark.parametrize(
    "edit",
    [
        {"speakers": {"s1": "Alex"}},
        {"segments": [{"id": "one", "start": 0, "end": 1, "speaker": "s1", "text": "Corrected text"}]},
    ],
)
def test_successful_transcript_correction_clears_obsolete_processing_error(review_client, edit):
    store = review_client.app.state.store
    meeting = store.create("Meeting", "meeting.wav", "auto", None, 2)
    store.update(
        meeting["id"],
        status="error",
        error="Summary provider timed out.",
        stage="Summary failed",
        progress=30,
        segments=[{"id": "one", "start": 0, "end": 1, "speaker": "s1", "text": "Original text"}],
        speakers={"s1": "Speaker 1"},
    )
    response = review_client.patch(f"/api/meetings/{meeting['id']}", json=edit)
    assert response.status_code == 200
    result = response.json()
    assert result["status"] == "transcribed"
    assert result["error"] is None
    assert "failed" not in result["stage"].lower()
    assert result["progress"] == 100
