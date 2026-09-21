#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
./scripts/build-metal.sh debug
swift build --build-tests
bin="$(swift build --show-bin-path)"
# XCTest loads MLX relative to the test executable inside its bundle.
cp "$bin/mlx.metallib" "$bin/StillnotePackageTests.xctest/Contents/MacOS/mlx.metallib"
swift test --skip-build --no-parallel
