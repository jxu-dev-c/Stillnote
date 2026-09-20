#!/usr/bin/env bash
# Destructive package lifecycle checks: only run on a disposable CI runner.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${CI:-}" == true ]] || { echo 'Run on a disposable CI runner only.' >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || exit 1
candidate="$PWD/build/candidate"
(cd "$candidate" && shasum -a 256 -c SHA256SUMS)
tap='jxu-dev-c/stillnote'
brew tap-new --no-git "$tap"
tap_dir="$(brew --repository)/Library/Taps/jxu-dev-c/homebrew-stillnote"
cp -R "$candidate/homebrew/Casks" "$tap_dir/"
# Exercise the exact generated definitions against the candidate assets before
# publication. Only transport changes; SHA256 and version checks remain intact.
python3 - "$tap_dir" "$candidate" <<'PY'
from pathlib import Path
import re
import sys
for path in Path(sys.argv[1]).rglob('*.rb'):
    content = path.read_text()
    version = re.search(r'version "([^"]+)"', content)[1]
    content = re.sub(r'https://github.com/jxu-dev-c/homebrew-stillnote/releases/download/[^/]+/',
                     Path(sys.argv[2]).as_uri() + '/', content).replace('#{version}', version)
    path.write_text(content)
    # An older installed version using the same fixture exercises Brew's upgrade
    # path without depending on an existing public runtime release.
    path.with_suffix('.rb.next').write_text(content)
    path.write_text(content.replace(f'version "{version}"', 'version "0.0.0"'))
PY
support="$HOME/Library/Application Support/Stillnote"
mkdir -p "$support"
printf 'preserve\n' > "$support/homebrew-test-sentinel"
brew install "$tap/stillnote"
(cd "$HOME" && /Applications/Stillnote.app/Contents/MacOS/Stillnote --diagnose) | tee "$candidate/diagnostics.txt"
grep -F '/Applications/Stillnote.app/Contents/MacOS/StillnoteSpeechWorker' "$candidate/diagnostics.txt"
grep -F 'MOSS runtime:    ready' "$candidate/diagnostics.txt"
for definition in "$tap_dir"/Casks/*.rb.next; do mv "$definition" "${definition%.next}"; done
brew upgrade --cask "$tap/stillnote"
brew reinstall --cask "$tap/stillnote"
/Applications/Stillnote.app/Contents/MacOS/StillnoteSpeechWorker --self-test
brew uninstall --cask "$tap/stillnote"
test "$(cat "$support/homebrew-test-sentinel")" = preserve
