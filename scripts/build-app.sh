#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stillnote is a macOS 15+ application.'
  exit 1
fi
configuration="${1:-release}"
swift build -c "$configuration" --product Stillnote
binary="$(swift build -c "$configuration" --show-bin-path)/Stillnote"
app='build/Stillnote.app'
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Resources/Info.plist "$contents/Info.plist"
cp "$binary" "$contents/MacOS/Stillnote"
# SwiftPM emits resource bundles beside the binary; the app looks for them in Resources.
for bundle in "$(dirname "$binary")"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$contents/Resources/"
done
codesign --force --sign - --identifier local.stillnote.app "$app"
echo "Built $app"
