#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
./scripts/build-metal.sh debug
swift test --no-parallel
