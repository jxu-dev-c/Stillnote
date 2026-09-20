#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
# Process tests mutate the environment and use blocking pipe I/O. Run suites
# sequentially so small CI runners cannot starve their background I/O threads.
swift test --no-parallel
python="${STILLNOTE_TEST_PYTHON:-$HOME/Library/Application Support/Stillnote/venv-moss/bin/python}"
if [[ -x "$python" ]]; then
  (cd sidecar && "$python" -m pytest -q)
  (cd sidecar && "$python" -m ruff check .)
  "$python" -m unittest discover -s scripts/tests
else
  echo 'MOSS worker checks require a test Python with pytest, ruff, and numpy.' >&2
  exit 1
fi
