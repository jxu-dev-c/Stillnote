#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
python="$HOME/Library/Application Support/Stillnote/venv-moss/bin/python"
if [[ -x "$python" ]]; then
  (cd sidecar && "$python" -m pytest -q)
  (cd sidecar && "$python" -m ruff check .)
else
  echo 'Skipping MOSS worker checks: run ./scripts/setup.sh to create the runtime.'
fi
