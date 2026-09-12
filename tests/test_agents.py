import json
import os
import sys
from pathlib import Path

import pytest
from meeting_app import agents
from meeting_app.storage import Store

RESULT = {"overview": "Done", "key_points": [], "decisions": [], "action_items": []}


@pytest.fixture
def fake_cli(tmp_path, monkeypatch):
    record = tmp_path / "invocation.json"
    executable = tmp_path / "fake agent"
    executable.write_text(
        f"#!{sys.executable}\n"
        + """
import json, os, pathlib, sys, time
args = sys.argv[1:]
prompt = sys.stdin.read()
pathlib.Path(os.environ['TEST_AGENT_RECORD']).write_text(json.dumps({'args': args, 'prompt': prompt, 'cwd': os.getcwd(), 'pid': os.getpid()}))
mode = os.environ.get('TEST_AGENT_MODE', 'success')
if mode == 'timeout':
    time.sleep(30)
if mode == 'exit':
    print('PRIVATE TRANSCRIPT secret-token', file=sys.stderr)
    sys.exit(7)
result = {'overview': 'Done', 'key_points': [], 'decisions': [], 'action_items': []}
content = json.dumps(result)
if mode == 'large':
    content = 'x' * 1000001
if mode == 'invalid':
    content = 'not json'
if args[0] == 'exec':
    if mode != 'missing':
        pathlib.Path(args[args.index('--output-last-message') + 1]).write_text(content)
    print('CLI progress is not the final response')
else:
    if mode in ('invalid', 'large'):
        print(content)
    elif mode == 'error':
        print(json.dumps({'subtype': 'error_max_turns', 'is_error': True, 'result': 'PRIVATE TRANSCRIPT secret-token'}))
    elif mode == 'legacy':
        print(json.dumps({'subtype': 'success', 'result': content}))
    else:
        print(json.dumps({'subtype': 'success', 'is_error': False, 'structured_output': result}))
"""
    )
    executable.chmod(0o700)
    monkeypatch.setenv("TEST_AGENT_RECORD", str(record))
    monkeypatch.setenv("STILLNOTE_CODEX_BIN", str(executable))
    monkeypatch.setenv("STILLNOTE_CLAUDE_BIN", str(executable))
    return record


@pytest.mark.parametrize("provider", ["codex", "claude-code"])
def test_real_subprocess_stdin_flags_output_and_temporary_cleanup(fake_cli, provider):
    prompt = 'Alex: $(touch never) `echo danger`\n"A quoted transcript"'
    text = agents.request_json(
        provider, agents.DEFAULT_MODELS[provider], "high", "Return JSON only", prompt, {"type": "object"}
    )
    assert json.loads(text) == RESULT
    record = json.loads(fake_cli.read_text())
    args = record["args"]
    assert prompt in record["prompt"] and prompt not in str(args)
    assert args[args.index("--model") + 1] == agents.DEFAULT_MODELS[provider]
    assert not Path(record["cwd"]).exists()
    if provider == "codex":
        assert args[0] == "exec" and args[-1] == "-"
        assert 'model_reasoning_effort="high"' in args
        assert args[args.index("--sandbox") + 1] == "read-only"
        assert "--ephemeral" in args and "--ignore-user-config" in args
    else:
        assert "--print" in args and "--no-session-persistence" in args
        assert args[args.index("--effort") + 1] == "high"
        assert args[args.index("--tools") + 1] == ""
        assert "--strict-mcp-config" in args


@pytest.mark.parametrize(
    "provider,mode,match",
    [
        ("codex", "exit", "exit 7"),
        ("claude-code", "exit", "exit 7"),
        ("claude-code", "error", "could not complete"),
        ("claude-code", "invalid", "invalid output"),
        ("codex", "missing", "final summary"),
        ("codex", "large", "large response"),
        ("claude-code", "large", "large response"),
    ],
)
def test_failures_do_not_expose_cli_output(fake_cli, monkeypatch, provider, mode, match):
    monkeypatch.setenv("TEST_AGENT_MODE", mode)
    with pytest.raises(agents.SummaryError, match=match) as error:
        agents.request_json(provider, "model", "high", "instructions", "PRIVATE TRANSCRIPT", {})
    assert "PRIVATE" not in str(error.value) and "secret-token" not in str(error.value)
    assert not Path(json.loads(fake_cli.read_text())["cwd"]).exists()


def test_timeout_stops_cli_and_cleans_workspace(fake_cli, monkeypatch):
    monkeypatch.setenv("TEST_AGENT_MODE", "timeout")
    monkeypatch.setattr(agents, "AGENT_TIMEOUT_SECONDS", 0.2)
    with pytest.raises(agents.SummaryError, match="timed out"):
        agents.request_json("codex", "model", "high", "instructions", "transcript", {})
    record = json.loads(fake_cli.read_text())
    assert not Path(record["cwd"]).exists()
    if os.name == "posix":
        with pytest.raises(ProcessLookupError):
            os.kill(record["pid"], 0)


def test_claude_result_text_supported(fake_cli, monkeypatch):
    monkeypatch.setenv("TEST_AGENT_MODE", "legacy")
    assert json.loads(agents.request_json("claude-code", "model", "high", "", "transcript", {})) == RESULT


def test_missing_cli_status_and_actionable_error(monkeypatch):
    monkeypatch.setattr(agents.shutil, "which", lambda command: None)
    assert not agents.agent_status()["codex"]["installed"]
    with pytest.raises(agents.SummaryError, match="STILLNOTE_CODEX_BIN"):
        agents.request_json("codex", "model", "high", "", "transcript", {})


@pytest.mark.parametrize(
    "legacy,provider",
    [("local", "codex"), ("ollama", "codex"), ("openai-compatible", "codex"), ("anthropic", "claude-code")],
)
def test_legacy_settings_migration_preserves_meetings_and_removes_api_credentials(tmp_path, legacy, provider):
    store = Store(tmp_path)
    settings = store.settings()
    settings["transcription"].update(language="fr", speaker_count=3)
    settings["summary"] = {
        "provider": legacy,
        "model": "old-model",
        "base_url": "https://example.test",
        "api_key": "secret-token",
    }
    meeting = store.create("Keep", "audio.wav", "fr", 3, 1)
    store.update(meeting["id"], summary={"overview": "Keep this", "provider": legacy}, notes="Keep notes")
    before = store.get(meeting["id"])
    with store.db() as db:
        db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)", (json.dumps(settings),))
    migrated = store.settings()
    assert migrated["summary"] == {
        "provider": provider,
        "model": agents.DEFAULT_MODELS[provider],
        "reasoning_effort": "high",
    }
    assert migrated["transcription"] == settings["transcription"]
    assert store.get(meeting["id"]) == before
    with store.db() as db:
        saved = db.execute("SELECT data FROM settings WHERE id=1").fetchone()[0]
        assert "secret-token" not in saved and "base_url" not in saved
    assert Store(tmp_path).settings() == migrated
