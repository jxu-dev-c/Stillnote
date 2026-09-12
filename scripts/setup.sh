#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stillnote is a macOS 15+ application.'
  exit 1
fi

# MOSS inference is the only part of Stillnote that is not Swift. It lives in its own
# virtual environment so its native dependencies stay isolated from the app.
if command -v uv >/dev/null 2>&1; then
  uv venv --allow-existing .venv-moss
  uv pip install --python .venv-moss/bin/python -r requirements-moss.lock
  uv pip install --python .venv-moss/bin/python pytest ruff
else
  python3 -m venv .venv-moss
  .venv-moss/bin/python -m pip install -r requirements-moss.lock pytest ruff
fi

./scripts/build-app.sh
echo 'Ready. Run ./scripts/start.sh, then download the speech model once in Settings.'
