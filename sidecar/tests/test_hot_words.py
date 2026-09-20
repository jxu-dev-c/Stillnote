import json
import sys

import pytest

from moss_worker import __main__ as worker
from moss_worker import mlx_runner


@pytest.mark.parametrize("raw", ['null', '{}', '"word"', '[1]', '["ok", null]', 'bad'])
def test_rejects_malformed_hot_words(raw):
    with pytest.raises(ValueError, match="JSON array of strings"):
        worker.parse_hot_words(raw)


def test_preserves_phrases_unicode_case_and_order():
    assert worker.parse_hot_words('[" API ", "", "示例", "New York", "API", "api"]') == [
        "API", "示例", "New York", "api"
    ]


@pytest.mark.parametrize("words", [None, [], ["示例", "New York", 'a "quote"']])
def test_worker_forwards_optional_words(monkeypatch, capsys, words):
    argv = ["moss_worker", "/audio.f32", "/model", "en", "2"]
    if words is not None:
        argv.append(json.dumps(words))
    monkeypatch.setattr(sys, "argv", argv)
    audio = object()
    monkeypatch.setattr(worker, "_load_audio", lambda path: audio)

    def run(path, supplied_audio, language, speakers, progress, hot_words):
        assert supplied_audio is audio
        assert language == "en"
        assert speakers == 2
        assert hot_words == (words or [])
        return "[0][S01]hello[1]"

    monkeypatch.setattr(mlx_runner, "run", run)
    assert worker.main() == 0
    assert json.loads(capsys.readouterr().out.removeprefix("STILLNOTE_EVENT "))["type"] == "result"


def test_invalid_worker_input_emits_error_before_audio_load(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["moss_worker", "/missing", "/model", "en", "0", '[123]'])
    assert worker.main() == 1
    assert "JSON array of strings" in capsys.readouterr().out


def test_prompt_keeps_transcription_instructions_and_adds_hints():
    original = (
        "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，"
        "正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"
    )
    assert mlx_runner.build_prompt("auto", None, []) == original
    assert mlx_runner.build_prompt("en", 2, ["API", "New York", "示例"]) == (
        original + " Audio language: en. Expected speakers: 2. 热词提示：API, New York, 示例"
    )


def test_runner_forwards_words_to_inference(monkeypatch):
    monkeypatch.setattr(mlx_runner, "_run", lambda *args: args[-1])
    assert mlx_runner.run(None, None, "auto", None, None, ["API"]) == ["API"]
