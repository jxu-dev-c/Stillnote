#!/usr/bin/env bash
# Build only the app target and an isolated row preview; no app services are started.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build "$@" --product Stillnote
bin="$(swift build "$@" --show-bin-path)"
app="build/meeting-selection/StillnoteSelectionPreview.app"
mkdir -p "$app/Contents/MacOS"
# Inject metadata into a test-only AppModel copy. Do not initialize the database,
# recorder, provider discovery, or any other service just to exercise the list.
fixture_model="build/meeting-selection/AppModel.swift"
cp Sources/Stillnote/AppModel.swift "$fixture_model"
cat >> "$fixture_model" <<'SWIFT'

extension AppModel {
    func seedSelectionPreview(_ items: [MeetingListItem]) { meetings = items }
}
SWIFT
swiftc -g -parse-as-library -module-name StillnoteSelectionPreview -I "$bin/Modules" \
  scripts/preview-meeting-selection.swift "$fixture_model" Sources/Stillnote/AppModel+*.swift \
  Sources/Stillnote/CommandServer.swift Sources/Stillnote/MeetingReminder.swift \
  Sources/Stillnote/Views/*.swift "$bin"/StillnoteCore.build/*.o \
  -Xlinker -framework -Xlinker AVKit -o "$app/Contents/MacOS/StillnoteSelectionPreview"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.stillnote.selection-preview</string>
<key>CFBundleName</key><string>StillnoteSelectionPreview</string>
<key>CFBundleExecutable</key><string>StillnoteSelectionPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
printf 'Preview: %s/%s\n' "$PWD" "$app"
