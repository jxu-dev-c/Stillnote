#!/usr/bin/env bash
# Build an isolated app containing the production toolbar and harmless synthetic actions.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Stillnote
bin="$(swift build --show-bin-path)"
app=build/ToolbarPreview.app
mkdir -p "$app/Contents/MacOS"
swiftc -g -parse-as-library -module-name ToolbarPreview -I "$bin/Modules" \
  scripts/preview-toolbar-help.swift Sources/Stillnote/AppModel*.swift \
  Sources/Stillnote/CommandServer.swift Sources/Stillnote/MeetingReminder.swift \
  Sources/Stillnote/Views/*.swift "$bin"/StillnoteCore.build/*.o \
  -Xlinker -framework -Xlinker AVKit -o "$app/Contents/MacOS/ToolbarPreview"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ToolbarPreview</string>
<key>CFBundleIdentifier</key><string>local.stillnote.toolbar-preview</string>
<key>CFBundleName</key><string>ToolbarPreview</string>
</dict></plist>
PLIST
printf 'Built %s. Open it to check pointer, keyboard, and accessibility behavior.\n' "$app"
