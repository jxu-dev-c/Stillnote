#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Stillnote is a macOS 15+ application.'
  exit 1
fi
configuration="${1:-release}"
swift build -c "$configuration" --product Stillnote
swift build -c "$configuration" --product StillnoteSpeechWorker
swift build -c "$configuration" --product StillnoteCLI
./scripts/build-metal.sh "$configuration"
bin="$(swift build -c "$configuration" --show-bin-path)"
app='build/Stillnote.app'
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"
cp Resources/Info.plist "$contents/Info.plist"
cp Resources/AppIcon.icns "$contents/Resources/AppIcon.icns"
cp "$bin/Stillnote" "$contents/MacOS/Stillnote"
cp "$bin/StillnoteSpeechWorker" "$contents/MacOS/StillnoteSpeechWorker"
# The command-line interface ships under its command name, in Helpers rather than MacOS: the
# filesystem is case-insensitive by default, so MacOS/stillnote would overwrite MacOS/Stillnote.
cp "$bin/StillnoteCLI" "$contents/Helpers/stillnote"
# MLX searches Resources/mlx relative to its executable. Keep data out of MacOS.
cp "$bin/mlx.metallib" "$contents/Resources/mlx.metallib"
ln -s ../Resources "$contents/MacOS/Resources"
cp Sources/StillnoteCore/Resources/speech_models.json "$contents/Resources/"
for bundle in "$bin"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  [[ "$(basename "$bundle")" == Stillnote_StillnoteCore.bundle ]] && continue
  cp -R "$bundle" "$contents/Resources/"
done
mkdir -p "$contents/Resources/licenses"
cp Vendor/MossTranscribeDiarize/LICENSE "$contents/Resources/licenses/MossTranscribeDiarize-LICENSE"
# Preserve licenses/notices for embedded C/C++ components as well as Swift packages.
while IFS= read -r -d '' license; do
  relative="${license#.build/checkouts/}"
  destination="$contents/Resources/licenses/$relative"
  mkdir -p "$(dirname "$destination")"
  cp "$license" "$destination"
done < <(find .build/checkouts -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -not -path '*/.git/*' -print0)
codesign --force --sign "${STILLNOTE_SIGNING_IDENTITY:--}" "$contents/MacOS/StillnoteSpeechWorker"
codesign --force --sign "${STILLNOTE_SIGNING_IDENTITY:--}" "$contents/Helpers/stillnote"
# Reuse a configured identity across builds so macOS can retain capture grants.
# The default stays ad-hoc for local development without a signing certificate.
codesign --force --sign "${STILLNOTE_SIGNING_IDENTITY:--}" --identifier local.stillnote.app "$app"
codesign --verify --deep --strict "$app"
"$contents/MacOS/StillnoteSpeechWorker" --self-test
"$contents/Helpers/stillnote" --version
echo "Built $app"
