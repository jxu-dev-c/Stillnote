"""Isolated inference entry point, launched only by the Stillnote app.

argv: <pcm-path> <model-dir> <language> <speaker-count> [<hot-words-json>]
The PCM file holds 16 kHz mono float32 samples decoded by the app. Progress, the raw
MOSS transcript, and actionable errors are written to stdout as STILLNOTE_EVENT lines.
"""

import json
import sys
import traceback
from pathlib import Path

SAMPLE_RATE = 16_000
MAX_SECONDS = 90 * 60


def _emit(event: dict) -> None:
    print("STILLNOTE_EVENT " + json.dumps(event, ensure_ascii=False), flush=True)


def _load_audio(path: Path):
    import numpy as np

    audio = np.fromfile(path, dtype="<f4")
    if audio.size == 0:
        raise ValueError("This recording contains no valid audio.")
    if not np.isfinite(audio).all():
        raise ValueError("This recording contains no valid audio.")
    if audio.size / SAMPLE_RATE > MAX_SECONDS:
        raise ValueError("MOSS supports recordings up to 90 minutes. Import a shorter recording.")
    return audio


def parse_hot_words(raw: str) -> list[str]:
    try:
        words = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError("Hot words must be a JSON array of strings.") from error
    if not isinstance(words, list) or any(not isinstance(word, str) for word in words):
        raise ValueError("Hot words must be a JSON array of strings.")
    return list(dict.fromkeys(word.strip() for word in words if word.strip()))


def main() -> int:
    if len(sys.argv) not in (5, 6):
        _emit({"type": "error", "message": "The speech worker was started with unexpected arguments."})
        return 2

    def progress(value: float, detail: str) -> None:
        _emit({"type": "progress", "progress": float(value), "detail": detail})

    try:
        from .mlx_runner import run

        hot_words = parse_hot_words(sys.argv[5]) if len(sys.argv) == 6 else []
        audio = _load_audio(Path(sys.argv[1]))
        text = run(
            Path(sys.argv[2]),
            audio,
            sys.argv[3],
            int(sys.argv[4]) or None,
            progress,
            hot_words=hot_words,
        )
    except (RuntimeError, ValueError) as error:
        _emit({"type": "error", "message": str(error)[:600]})
        return 1
    except Exception:
        # The detail goes to stderr, which the app discards; the app shows the
        # actionable message instead of a Python traceback.
        traceback.print_exc(file=sys.stderr)
        _emit(
            {
                "type": "error",
                "message": "Local speech processing failed. Your recording is saved. "
                "Check the audio format and try reinstalling the speech models.",
            }
        )
        return 1
    _emit({"type": "result", "text": text})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
