#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
.venv/bin/python -m pytest -q
.venv/bin/ruff check backend tests
(cd frontend && npm run check && npm run build)
