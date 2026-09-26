#!/usr/bin/env bash
# Verifies the packaged candidate in build/candidate before it is published.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
(cd build/candidate && shasum -a 256 -c SHA256SUMS)
extracted=$(mktemp -d)
trap 'rm -rf "$extracted"' EXIT
ditto -x -k "build/candidate/Stillnote-$version-macos-arm64.zip" "$extracted"
app="$extracted/Stillnote.app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/StillnoteSpeechWorker" --self-test
# The bundled CLI is what the Homebrew cask links onto PATH, and it reports the same version as
# the bundle it shipped in.
[[ "$("$app/Contents/Helpers/stillnote" --version)" == "stillnote $version" ]]
"$app/Contents/Helpers/stillnote" help >/dev/null
for binary in MacOS/Stillnote MacOS/StillnoteSpeechWorker Helpers/stillnote; do
  [[ "$(lipo -archs "$app/Contents/$binary")" == arm64 ]]
  test -x "$app/Contents/$binary"
done
# The CLI lives in Helpers because MacOS/stillnote and MacOS/Stillnote are the same file on a
# case-insensitive volume. If it ever moves back, the app binary is silently replaced by the CLI,
# so assert the two are genuinely different executables.
[[ "$(shasum -a 256 <"$app/Contents/MacOS/Stillnote")" != "$(shasum -a 256 <"$app/Contents/Helpers/stillnote")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
for resource in AppIcon.icns speech_models.json LICENSE THIRD_PARTY_NOTICES.md; do
  test -s "$app/Contents/Resources/$resource"
done
echo "Verified build/candidate for $version"
