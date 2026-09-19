#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
python="${STILLNOTE_TEST_PYTHON:-$HOME/Library/Application Support/Stillnote/venv-moss/bin/python}"
if [[ -x "$python" ]]; then
  (cd sidecar && "$python" -m pytest -q)
  (cd sidecar && "$python" -m ruff check .)
else
  echo 'MOSS worker checks require a test Python with pytest, ruff, and numpy.' >&2
  exit 1
fi
