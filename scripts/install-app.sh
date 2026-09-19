#!/usr/bin/env bash
# Personal installation of our ad-hoc-signed GitHub build. No global Gatekeeper changes.
set -euo pipefail
if [[ $# != 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/Stillnote-version-macos-arm64.zip" >&2
  exit 1
fi
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
destination="$HOME/Applications/Stillnote.app"
if pgrep -f "$destination/Contents/MacOS/Stillnote" >/dev/null; then
  echo 'Quit Stillnote before installing (your meetings will be preserved).' >&2
  exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ditto -x -k "$archive" "$scratch/extracted"
source_app="$scratch/extracted/Stillnote.app"
test -x "$source_app/Contents/MacOS/Stillnote"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == local.stillnote.app ]]
codesign --verify --strict "$source_app"
# Imported download/provenance metadata can hold the ad-hoc executable before
# dyld enters main(), even after Open Anyway. Make a local copy without that
# metadata; keep the executable and its verified signature byte-for-byte intact.
ditto --noextattr --norsrc "$source_app" "$scratch/Stillnote.app"
codesign --verify --strict "$scratch/Stillnote.app"
cmp "$source_app/Contents/MacOS/Stillnote" "$scratch/Stillnote.app/Contents/MacOS/Stillnote"
mkdir -p "$HOME/Applications"
backup=''
if [[ -e "$destination" ]]; then
  backup="$HOME/Applications/Stillnote.backup.$(date +%Y%m%d-%H%M%S).app"
  mv "$destination" "$backup"
fi
if ! mv "$scratch/Stillnote.app" "$destination"; then
  [[ -z "$backup" ]] || mv "$backup" "$destination"
  exit 1
fi
echo "Installed $destination"
[[ -z "$backup" ]] || echo "Previous app saved at $backup"
open "$destination"
