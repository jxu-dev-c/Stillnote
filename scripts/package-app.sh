#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple silicon is required.' >&2; exit 1; }
./scripts/build-app.sh release
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
staging="build/candidate"
mkdir -p "$staging"
cp LICENSE THIRD_PARTY_NOTICES.md build/Stillnote.app/Contents/Resources/
codesign --force --sign "${STILLNOTE_SIGNING_IDENTITY:--}" --identifier local.stillnote.app build/Stillnote.app
codesign --verify --strict build/Stillnote.app
archive="Stillnote-${STILLNOTE_RELEASE_VERSION:-$version}-macos-arm64.zip"
ditto -c -k --keepParent build/Stillnote.app "$staging/$archive"
cp scripts/install-app.sh "$staging/Install-Stillnote.sh"
(cd "$staging" && shasum -a 256 "$archive" Install-Stillnote.sh > SHA256SUMS)
cp LICENSE THIRD_PARTY_NOTICES.md "$staging/"
sed "s/@VERSION@/$version/g" docs/RELEASE-NOTES.md > "$staging/RELEASE-NOTES.md"
echo "Development candidate: $staging/$archive (runtime not bundled)"
