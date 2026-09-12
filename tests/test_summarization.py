import json
from datetime import datetime

import pytest
from meeting_app import summarization as summaries


@pytest.fixture
def meeting():
    return {
        "id": "PRIVATE ID",
        "title": "PRIVATE TITLE",
        "notes": "PRIVATE NOTES",
        "context_links": [{"url": "https://private.example", "title": "PRIVATE LINK"}],
        "audio_name": "PRIVATE AUDIO.wav",
        "audio_path": "/private/audio.wav",
        "audio": b"PRIVATE AUDIO",
        "speakers": {"speaker_1": "Alex"},
        "segments": [{"speaker": "speaker_1", "text": "I'll send the revised proposal by Friday."}],
    }


@pytest.fixture
def provider_summary():
    return {
        "overview": "The team discussed the pilot.",
        "key_points": ["Budget review is needed."],
        "decisions": ["Launch the pilot in October."],
        "action_items": [{"text": "Send the revised proposal.", "owner": "Alex", "due": "Friday"}],
    }


@pytest.mark.parametrize("provider,model", [("codex", "gpt-5.6-luna"), ("claude-code", "claude-sonnet-5")])
def test_headless_defaults_and_transcript_only_input(meeting, provider_summary, monkeypatch, provider, model):
    calls = []

    def request(*args):
        calls.append(args)
        return json.dumps(provider_summary)

    monkeypatch.setattr(summaries, "request_json", request)
    result = summaries.summarize(meeting, {"provider": provider}, True)
    assert result["provider"] == provider and result["model"] == model
    assert datetime.fromisoformat(result["generated_at"]).tzinfo is not None
    assert len(calls) == 1
    assert calls[0][:3] == (provider, model, "high")
    assert "Alex: I'll send" in calls[0][4]
    assert "PRIVATE" not in str(calls) and "private.example" not in str(calls)
    assert calls[0][5] == summaries.SUMMARY_SCHEMA


@pytest.mark.parametrize("settings", [{}, {"provider": "codex"}, {"provider": "claude-code"}])
def test_consent_required_before_cli_start(meeting, monkeypatch, settings):
    monkeypatch.setattr(summaries, "request_json", lambda *args: pytest.fail("CLI must not start"))
    with pytest.raises(summaries.SummaryError, match="consent"):
        summaries.summarize(meeting, settings)


def test_empty_transcript_and_size_limit_rejected_before_cli(monkeypatch):
    monkeypatch.setattr(summaries, "request_json", lambda *args: pytest.fail("CLI must not start"))
    with pytest.raises(summaries.SummaryError, match="Transcribe"):
        summaries.summarize({"segments": []}, {}, True)
    with pytest.raises(summaries.SummaryError, match="too long"):
        summaries.summarize({"segments": [{"text": "x" * summaries.MAX_TRANSCRIPT_BYTES}]}, {}, True)


@pytest.mark.parametrize(
    "settings",
    [{"provider": "local"}, {"model": "bad\nmodel"}, {"model": 123}, {"reasoning_effort": "ultra"}],
)
def test_invalid_configuration_rejected_before_cli(meeting, monkeypatch, settings):
    monkeypatch.setattr(summaries, "request_json", lambda *args: pytest.fail("CLI must not start"))
    with pytest.raises(summaries.SummaryError):
        summaries.summarize(meeting, settings, True)


def test_custom_model_and_effort_are_honored(meeting, provider_summary, monkeypatch):
    def request(provider, model, effort, *args):
        assert (provider, model, effort) == ("claude-code", "custom-model", "medium")
        return json.dumps(provider_summary)

    monkeypatch.setattr(summaries, "request_json", request)
    summaries.summarize(
        meeting, {"provider": "claude-code", "model": " custom-model ", "reasoning_effort": "medium"}, True
    )


@pytest.mark.parametrize(
    "content", ["not json", "[]", "{}", '{"overview":"x","key_points":{},"decisions":[],"action_items":[]}']
)
def test_invalid_provider_output_fails_clearly(meeting, monkeypatch, content):
    monkeypatch.setattr(summaries, "request_json", lambda *args: content)
    with pytest.raises(summaries.SummaryError, match="invalid summary format"):
        summaries.summarize(meeting, {}, True)


def test_valid_fenced_json_is_normalized_and_unknown_fields_ignored(provider_summary):
    provider_summary["api_key"] = "should not be saved"
    provider_summary["action_items"][0]["due"] = " "
    result = summaries._parse_summary("```json\n" + json.dumps(provider_summary) + "\n```")
    assert "api_key" not in result
    assert result["action_items"][0]["due"] is None


def test_long_transcript_includes_final_section_and_merges_without_extra_calls(monkeypatch):
    meeting = {
        "segments": [
            {"speaker": "s1", "text": f"Topic {index}: " + "development planning " * 100}
            for index in range(12)
        ]
    }
    meeting["segments"].append({"speaker": "s2", "text": "I'll send the FINAL REPORT by Friday."})
    prompts = []

    def request(provider, model, effort, instructions, prompt, schema):
        prompts.append(prompt)
        return json.dumps(
            {
                "overview": "Discussed planning.",
                "key_points": ["Planning."],
                "decisions": ["Agreed to review."],
                "action_items": [{"text": "Send FINAL REPORT", "owner": "s2", "due": "Friday"}]
                if "FINAL REPORT" in prompt
                else [],
            }
        )

    monkeypatch.setattr(summaries, "request_json", request)
    result = summaries.summarize(meeting, {}, True)
    assert len(prompts) > 1
    assert all(len(prompt.encode()) < summaries.CHUNK_BYTES + 300 for prompt in prompts)
    assert "FINAL REPORT" in prompts[-1]
    assert len(result["decisions"]) == 1
    assert result["action_items"] == [{"text": "Send FINAL REPORT", "owner": "s2", "due": "Friday"}]


def test_unicode_chunks_are_valid_bounded_and_preserve_every_character():
    text = "我们讨论下周的项目计划。" * 3000
    chunks = summaries._chunks([("说话者", text)])
    assert len(chunks) > 1
    assert all(len(chunk.encode("utf-8")) <= summaries.CHUNK_BYTES for chunk in chunks)
    assert "".join(chunk.removeprefix("说话者: ") for chunk in chunks) == text
