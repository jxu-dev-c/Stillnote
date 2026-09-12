#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d build/Stillnote.app ]]; then
  ./scripts/build-app.sh
fi
open build/Stillnote.app
