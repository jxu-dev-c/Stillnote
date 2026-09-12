#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v uv >/dev/null 2>&1; then
  uv sync --extra dev
  uv venv --allow-existing .venv-moss
  uv pip install --python .venv-moss/bin/python -r requirements-moss.lock
else
  python3 -m venv .venv
  .venv/bin/python -m pip install -e '.[dev]'
  python3 -m venv .venv-moss
  .venv-moss/bin/python -m pip install -r requirements-moss.lock
fi
(cd frontend && npm ci && npm run build)
if [[ "$(uname -s)" == Darwin ]] && xcrun --find swiftc >/dev/null 2>&1; then
  ./scripts/build-capture.sh
fi
echo 'Ready. Run ./scripts/start.sh and open http://127.0.0.1:8765.'
echo 'In Settings, download the local speech models once to enable offline transcription.'
