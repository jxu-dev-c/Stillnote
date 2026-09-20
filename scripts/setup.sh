#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stillnote is a macOS 15+ application.'
  exit 1
fi

# MOSS inference is the only part of Stillnote that is not Swift. It lives in its own
# virtual environment under Application Support rather than in this checkout: a bundled
# app reading the Documents folder needs permission macOS cannot grant during launch.
support="$HOME/Library/Application Support/Stillnote"
venv="$support/venv-moss"
mkdir -p "$support"

if command -v uv >/dev/null 2>&1; then
  # MOSS requires a recent Python; uv may otherwise pick an older default.
  uv venv --python 3.13 --allow-existing "$venv"
  uv pip install --python "$venv/bin/python" -r requirements-moss.lock
  uv pip install --python "$venv/bin/python" ./sidecar pytest ruff packaging
else
  python3 -m venv "$venv"
  "$venv/bin/python" -m pip install -r requirements-moss.lock ./sidecar pytest ruff packaging
fi

./scripts/build-app.sh
echo "MOSS runtime: $venv"
echo 'Ready. Run ./scripts/start.sh, then download the speech model once in Settings.'
