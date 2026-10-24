#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Stillnote
bin="$(swift build --show-bin-path)"
mkdir -p build/library-performance
swiftc -g -parse-as-library -module-name StillnoteModelCheck -I "$bin/Modules" \
  scripts/check-library-model.swift Sources/Stillnote/AppModel.swift \
  Sources/Stillnote/CommandServer.swift Sources/Stillnote/MeetingReminder.swift \
  Sources/Stillnote/Views/*.swift "$bin"/StillnoteCore.build/*.o \
  -Xlinker -framework -Xlinker AVKit -o build/library-performance/model-check
build/library-performance/model-check
