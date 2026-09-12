#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
if [[ -x .venv-moss/bin/python ]]; then
  (cd sidecar && ../.venv-moss/bin/python -m pytest -q)
  (cd sidecar && ../.venv-moss/bin/python -m ruff check .)
else
  echo 'Skipping MOSS worker checks: run ./scripts/setup.sh to create .venv-moss.'
fi
