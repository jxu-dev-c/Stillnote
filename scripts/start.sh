#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .venv/bin/python ]]; then
  echo 'Run ./scripts/setup.sh first.'
  exit 1
fi
if [[ ! -f frontend/dist/index.html ]]; then
  echo 'Building the interface...'
  (cd frontend && npm run build)
fi
echo "Stillnote is available at http://127.0.0.1:${STILLNOTE_PORT:-8765}"
exec .venv/bin/python -m meeting_app.main
