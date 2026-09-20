#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
echo 'Ready. Run ./scripts/start.sh, then download the speech model once in Settings.'
