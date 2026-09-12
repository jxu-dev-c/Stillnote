#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Native capture is available on macOS 15+. Browser recording remains available.'
  exit 0
fi
capture_contents='native/build/Stillnote Capture.app/Contents'
mkdir -p "$capture_contents/MacOS" native/build/module-cache
cp native/macos/Info.plist "$capture_contents/Info.plist"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path native/build/module-cache \
  native/macos/CaptureSupport.swift native/macos/main.swift \
  -o "$capture_contents/MacOS/stillnote-capture" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker native/macos/Info.plist
codesign --force --sign - --identifier local.stillnote.capture "native/build/Stillnote Capture.app"
echo 'Built Stillnote Capture. Permissions are requested when you start a native recording.'
