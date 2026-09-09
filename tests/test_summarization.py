import json
from datetime import datetime

import httpx
import pytest
from meeting_app import summarization as summaries


@pytest.fixture
def meeting():
    return {
        "id": "private-meeting-id",
        "title": "PRIVATE TITLE",
        "notes": "PRIVATE NOTES",
        "audio_name": "PRIVATE AUDIO NAME.wav",
        "audio_path": "/private/audio.wav",
        "audio": b"PRIVATE AUDIO BYTES",
        "speakers": {"speaker_1": "Alex", "speaker_2": "Sam"},
        "segments": [
            {"speaker": "speaker_1", "text": "We decided to launch the pilot in October."},
            {"speaker": "speaker_1", "text": "I'll send the revised proposal by Friday."},
            {"speaker": "speaker_2", "text": "We need to review the budget."},
            {"speaker": "speaker_2", "text": "Could we move the launch to November?"},
        ],
    }


@pytest.fixture
def provider_summary():
    return {
        "overview": "The team discussed the pilot.",
        "key_points": ["Budget review is needed."],
        "decisions": ["Launch the pilot in October."],
        "action_items": [{"text": "Send the revised proposal.", "owner": "Alex", "due": "Friday"}],
    }


def fake_client(monkeypatch, handler):
    original = httpx.Client
    options = []

    def factory(**kwargs):
        options.append(kwargs)
        return original(transport=httpx.MockTransport(handler), **kwargs)

    monkeypatch.setattr(summaries.httpx, "Client", factory)
    return options


def forbid_network(monkeypatch):
    def fail(**kwargs):
        pytest.fail("Network access must not happen")

    monkeypatch.setattr(summaries.httpx, "Client", fail)


def test_local_extracts_decisions_actions_and_only_explicit_owners_and_due(meeting, monkeypatch):
    forbid_network(monkeypatch)
    result = summaries.summarize(meeting, {})
    assert result["provider"] == "local"
    assert result["model"] == "extractive-v1"
    assert datetime.fromisoformat(result["generated_at"]).tzinfo is not None
    assert result["decisions"] == ["We decided to launch the pilot in October."]
    assert result["action_items"] == [
        {"text": "I'll send the revised proposal by Friday.", "owner": "Alex", "due": "Friday"},
        {"text": "We need to review the budget.", "owner": None, "due": None},
    ]
    assert "pilot" in result["overview"]
    assert "PRIVATE" not in json.dumps(result)


def test_local_does_not_turn_hypotheticals_or_questions_into_commitments(monkeypatch):
    forbid_network(monkeypatch)
    meeting = {
        "segments": [
            {"speaker": "s1", "text": "If we agreed to launch, we will send the announcement."},
            {"speaker": "s1", "text": "Maybe I'll draft a plan."},
            {"speaker": "s2", "text": "We have not decided on a date."},
            {"speaker": "s2", "text": "We need to send the proposal?"},
            {"speaker": "s2", "text": "I will be away on holiday next week."},
        ]
    }
    result = summaries.summarize(meeting, {"provider": "local"})
    assert result["decisions"] == []
    assert result["action_items"] == []


def test_local_explicit_decision_label_and_typographic_apostrophes():
    result = summaries.summarize(
        {
            "speakers": {"s1": "Alex"},
            "segments": [
                {"speaker": "s1", "text": "Decision: the launch will take place on Monday."},
                {"speaker": "s1", "text": "I’ll write the release notes before tomorrow."},
            ],
        },
        {"provider": "local"},
    )
    assert result["decisions"] == ["Decision: the launch will take place on Monday."]
    assert {
        "text": "I’ll write the release notes before tomorrow.",
        "owner": "Alex",
        "due": "tomorrow",
    } in result["action_items"]


def test_local_negative_decisions_preserved_without_creating_negated_actions():
    result = summaries.summarize(
        {
            "segments": [
                {"speaker": "s1", "text": "We will not send the release today."},
                {"speaker": "s1", "text": "We decided not to launch until Monday."},
                {"speaker": "s1", "text": "We don't need to review this again."},
            ]
        },
        {"provider": "local"},
    )
    assert result["decisions"] == ["We decided not to launch until Monday."]
    assert result["action_items"] == []


def test_real_asr_comma_joined_commitments_survive_nearby_suggestions():
    # Text produced by the real two-voice transcription smoke test.
    result = summaries.summarize(
        {
            "speakers": {"s1": "Speaker 1", "s2": "Speaker 2"},
            "segments": [
                {
                    "speaker": "s1",
                    "text": "Welcome to the planning meeting, we need to finish the design review by Friday, I will send the updated prototype to the team tomorrow.",
                },
                {
                    "speaker": "s2",
                    "text": "That sounds good, I will handle the testing and check the mobile layout, we should schedule a short review on Thursday afternoon.",
                },
                {
                    "speaker": "s2",
                    "text": "I will do that. I will also write the release checklist and share it with everyone. Thanks for the update.",
                },
            ],
        },
        {},
    )
    assert result["action_items"] == [
        {"text": "we need to finish the design review by Friday", "owner": None, "due": "Friday"},
        {
            "text": "I will send the updated prototype to the team tomorrow.",
            "owner": "Speaker 1",
            "due": None,
        },
        {"text": "I will handle the testing and check the mobile layout", "owner": "Speaker 2", "due": None},
        {
            "text": "I will also write the release checklist and share it with everyone.",
            "owner": "Speaker 2",
            "due": None,
        },
    ]


def test_clause_splitting_preserves_conditional_scope_and_named_owners():
    result = summaries.summarize(
        {
            "speakers": {"s1": "Alex", "s2": "Sam"},
            "segments": [
                {"speaker": "s1", "text": "If we get approval, I will send the proposal."},
                {"speaker": "s1", "text": "Unless we get approval; Sam will send the proposal."},
                {
                    "speaker": "s2",
                    "text": "We could prepare a draft; Alex will review the checklist by Friday.",
                },
            ],
        },
        {},
    )
    assert result["action_items"] == [
        {"text": "Alex will review the checklist by Friday.", "owner": "Alex", "due": "Friday"},
    ]


@pytest.mark.parametrize("provider", ["openai-compatible", "anthropic"])
@pytest.mark.parametrize("consent", [False, None, "true", 1])
def test_remote_consent_is_explicit_and_precedes_any_network(meeting, monkeypatch, provider, consent):
    forbid_network(monkeypatch)
    with pytest.raises(summaries.SummaryError, match="consent"):
        summaries.summarize(meeting, {"provider": provider}, allow_remote=consent)


@pytest.mark.parametrize(
    "provider,expected",
    [
        ("local", False),
        ("ollama", False),
        ("openai-compatible", True),
        ("anthropic", True),
    ],
)
def test_provider_classification(provider, expected):
    assert summaries.is_remote_provider({"provider": provider}) is expected


def test_empty_transcript_fails_without_network(monkeypatch):
    forbid_network(monkeypatch)
    with pytest.raises(summaries.SummaryError, match="Transcribe"):
        summaries.summarize({"segments": [{"text": "   "}]}, {"provider": "local"})


def test_unknown_provider_is_not_treated_as_local(meeting, monkeypatch):
    forbid_network(monkeypatch)
    with pytest.raises(summaries.SummaryError, match="supported"):
        summaries.summarize(meeting, {"provider": "magic-cloud"})


def test_openai_request_contains_only_transcript_and_validates_response(
    meeting, provider_summary, monkeypatch
):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": json.dumps(provider_summary)}, "finish_reason": "stop"}]
            },
        )

    options = fake_client(monkeypatch, handler)
    result = summaries.summarize(
        meeting,
        {"provider": "openai-compatible", "model": "configured-model", "api_key": "secret-token"},
        allow_remote=True,
    )
    assert len(requests) == 1
    request = requests[0]
    assert str(request.url) == "https://api.openai.com/v1/chat/completions"
    assert request.headers["Authorization"] == "Bearer secret-token"
    body = json.loads(request.content)
    assert body["store"] is False
    assert body["stream"] is False
    assert body["response_format"] == {"type": "json_object"}
    assert body["messages"][0]["role"] == "system"
    assert "untrusted" in body["messages"][0]["content"]
    assert "Alex: I'll send the revised proposal" in body["messages"][1]["content"]
    assert "PRIVATE" not in request.content.decode()
    assert "/private/" not in request.content.decode()
    assert "secret-token" not in request.content.decode()
    assert "secret-token" not in json.dumps(result)
    assert result["action_items"] == provider_summary["action_items"]
    assert options[0]["trust_env"] is False
    assert options[0]["follow_redirects"] is False


def test_anthropic_payload_and_text_blocks(meeting, provider_summary, monkeypatch):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "content": [
                    {"type": "thinking", "thinking": "ignored"},
                    {"type": "text", "text": json.dumps(provider_summary)},
                ],
                "stop_reason": "end_turn",
            },
        )

    fake_client(monkeypatch, handler)
    result = summaries.summarize(
        meeting,
        {"provider": "anthropic", "model": "configured-claude", "api_key": "secret-key"},
        allow_remote=True,
    )
    assert requests[0].url.path == "/v1/messages"
    assert requests[0].headers["x-api-key"] == "secret-key"
    assert requests[0].headers["anthropic-version"] == "2023-06-01"
    body = json.loads(requests[0].content)
    assert body["messages"][0]["role"] == "user"
    assert "system" in body
    assert body["max_tokens"] == 4096
    assert result["provider"] == "anthropic"


@pytest.mark.parametrize(
    "provider,url",
    [
        ("openai-compatible", "http://api.example.com/v1"),
        ("anthropic", "https://user:secret@api.example.com/v1"),
        ("anthropic", "https://api.example.com/v1?key=secret"),
        ("ollama", "https://ollama.com"),
        ("ollama", "http://192.168.0.1:11434"),
        ("ollama", "http://localhost.evil.example:11434"),
        ("ollama", "http://127.0.0.1:99999"),
    ],
)
def test_unsafe_endpoints_rejected_before_network(meeting, monkeypatch, provider, url):
    forbid_network(monkeypatch)
    with pytest.raises(summaries.SummaryError):
        summaries.summarize(meeting, {"provider": provider, "model": "test", "base_url": url}, True)


def test_ollama_local_model_preflight_and_loopback_normalization(meeting, provider_summary, monkeypatch):
    requests = []

    def handler(request):
        requests.append(request)
        if request.url.path == "/api/show":
            return httpx.Response(
                200, json={"model_info": {"general.architecture": "llama"}, "capabilities": ["completion"]}
            )
        return httpx.Response(200, json={"message": {"content": json.dumps(provider_summary)}, "done": True})

    fake_client(monkeypatch, handler)
    result = summaries.summarize(
        meeting, {"provider": "ollama", "model": "local-model", "base_url": "http://localhost:11434"}
    )
    assert [request.url.path for request in requests] == ["/api/show", "/api/chat"]
    assert all(request.url.host == "127.0.0.1" for request in requests)
    assert json.loads(requests[0].content) == {"model": "local-model"}
    assert json.loads(requests[1].content)["format"] == "json"
    assert result["provider"] == "ollama"


@pytest.mark.parametrize(
    "model_info",
    [
        {"remote_model": "remote", "remote_host": "https://ollama.com"},
        {"remote_host": "https://ollama.com", "model_info": {"architecture": "llama"}},
        {},
    ],
)
def test_ollama_cloud_or_unconfirmed_models_never_receive_transcript(meeting, monkeypatch, model_info):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=model_info)

    fake_client(monkeypatch, handler)
    with pytest.raises(summaries.SummaryError):
        summaries.summarize(meeting, {"provider": "ollama", "model": "renamed-model"})
    assert len(requests) == 1
    assert json.loads(requests[0].content) == {"model": "renamed-model"}


@pytest.mark.parametrize(
    "status,message",
    [
        (401, "API key"),
        (403, "API key"),
        (404, "not found"),
        (429, "limit"),
        (400, "rejected"),
        (500, "unavailable"),
        (307, "Redirects are disabled"),
    ],
)
def test_provider_errors_never_echo_secrets_or_bodies(meeting, monkeypatch, status, message):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(
            status,
            json={"error": {"message": "secret-token PRIVATE TRANSCRIPT"}},
            headers={"location": "https://other-host.example"},
        )

    fake_client(monkeypatch, handler)
    with pytest.raises(summaries.SummaryError, match=message) as error:
        summaries.summarize(
            meeting, {"provider": "openai-compatible", "model": "test", "api_key": "secret-token"}, True
        )
    assert "secret-token" not in str(error.value)
    assert "PRIVATE" not in str(error.value)
    assert len(requests) == 1


@pytest.mark.parametrize(
    "exception,match", [(httpx.ConnectError, "Could not connect"), (httpx.ReadTimeout, "timed out")]
)
def test_network_error_details_are_not_exposed(meeting, monkeypatch, exception, match):
    def handler(request):
        raise exception("secret-key PRIVATE", request=request)

    fake_client(monkeypatch, handler)
    with pytest.raises(summaries.SummaryError, match=match) as error:
        summaries.summarize(meeting, {"provider": "openai-compatible", "model": "test"}, True)
    assert "secret-key" not in str(error.value)


@pytest.mark.parametrize(
    "content", ["not json", "[]", "{}", '{"overview":"x","key_points":{},"decisions":[],"action_items":[]}']
)
def test_invalid_provider_output_fails_clearly(meeting, monkeypatch, content):
    fake_client(
        monkeypatch,
        lambda request: httpx.Response(200, json={"choices": [{"message": {"content": content}}]}),
    )
    with pytest.raises(summaries.SummaryError, match="invalid summary format"):
        summaries.summarize(meeting, {"provider": "openai-compatible", "model": "test"}, True)


def test_valid_fenced_json_is_normalized_and_unknown_fields_ignored(provider_summary):
    provider_summary["api_key"] = "should not be saved"
    provider_summary["action_items"][0]["due"] = " "
    result = summaries._parse_summary("```json\n" + json.dumps(provider_summary) + "\n```")
    assert "api_key" not in result
    assert result["action_items"][0]["due"] is None


def test_truncated_response_is_not_saved_as_complete(meeting, provider_summary, monkeypatch):
    fake_client(
        monkeypatch,
        lambda request: httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": json.dumps(provider_summary)}, "finish_reason": "length"}]
            },
        ),
    )
    with pytest.raises(summaries.SummaryError, match="output limit"):
        summaries.summarize(meeting, {"provider": "openai-compatible", "model": "test"}, True)


def test_long_transcript_includes_final_section_and_merges_without_extra_remote_calls(monkeypatch):
    meeting = {
        "segments": [
            {"speaker": "s1", "text": f"Topic {index}: " + "development planning " * 100}
            for index in range(12)
        ]
    }
    meeting["segments"].append({"speaker": "s2", "text": "I'll send the FINAL REPORT by Friday."})
    transcript_requests = []

    def handler(request):
        prompt = json.loads(request.content)["messages"][1]["content"]
        transcript_requests.append(prompt)
        final = "FINAL REPORT" in prompt
        result = {
            "overview": "Discussed planning.",
            "key_points": ["Planning."],
            "decisions": ["Agreed to review."],
            "action_items": (
                [{"text": "Send FINAL REPORT", "owner": "s2", "due": "Friday"}] if final else []
            ),
        }
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(result)}}]})

    fake_client(monkeypatch, handler)
    result = summaries.summarize(meeting, {"provider": "openai-compatible", "model": "test"}, True)
    assert len(transcript_requests) > 1
    assert all(len(prompt.encode()) < summaries.CHUNK_BYTES + 300 for prompt in transcript_requests)
    assert "FINAL REPORT" in transcript_requests[-1]
    assert len(result["decisions"]) == 1
    assert result["action_items"] == [{"text": "Send FINAL REPORT", "owner": "s2", "due": "Friday"}]


def test_unicode_chunks_are_valid_bounded_and_preserve_every_character():
    text = "我们讨论下周的项目计划。" * 3000
    chunks = summaries._chunks([("说话者", text)])
    assert len(chunks) > 1
    assert all(len(chunk.encode("utf-8")) <= summaries.CHUNK_BYTES for chunk in chunks)
    assert "".join(chunk.removeprefix("说话者: ") for chunk in chunks) == text
