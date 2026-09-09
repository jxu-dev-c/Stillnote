"""Isolated local model inference entry point; launched only by speech.transcribe_audio."""

import json
import sys
from pathlib import Path

from .speech import _transcribe_in_process


def _emit(event: dict) -> None:
    print("STILLNOTE_EVENT " + json.dumps(event, ensure_ascii=False), flush=True)


def main() -> int:
    if len(sys.argv) != 6:
        return 2

    def progress(value: float, detail: str) -> None:
        _emit({"type": "progress", "progress": value, "detail": detail})

    try:
        result = _transcribe_in_process(
            Path(sys.argv[1]),
            Path(sys.argv[2]),
            sys.argv[3],
            sys.argv[4],
            int(sys.argv[5]) or None,
            progress,
        )
    except (RuntimeError, ValueError) as error:
        _emit({"type": "error", "message": str(error)[:600]})
        return 1
    except Exception:
        _emit(
            {
                "type": "error",
                "message": "Local speech processing failed. Your recording is saved. "
                "Check the audio format and try reinstalling the speech models.",
            }
        )
        return 1
    _emit({"type": "result", "result": result})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
