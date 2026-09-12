#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stillnote is a macOS 15+ application.'
  exit 1
fi
configuration="${1:-release}"
swift build -c "$configuration" --product Stillnote
bin="$(swift build -c "$configuration" --show-bin-path)"
app='build/Stillnote.app'
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
cp "$bin/Stillnote" "$contents/MacOS/Stillnote"
# Resources are copied out of SwiftPM's bundles as plain files: a nested .bundle inside a
# hand-assembled app hangs CFBundle when LaunchServices launches it.
for bundle in "$bin"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  find "$bundle" -type f ! -name 'Info.plist' -print0 |
    while IFS= read -r -d '' resource; do cp "$resource" "$contents/Resources/"; done
done
codesign --force --sign - --identifier local.stillnote.app "$app"
echo "Built $app"
