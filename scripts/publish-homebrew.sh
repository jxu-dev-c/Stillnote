#!/usr/bin/env bash
# Publishes release assets and the cask to the public Homebrew tap. The release workflow passes
# the assets it just built; a maintainer with gh access to both repositories can rerun it for an
# already published tag to backfill or repair the tap.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-}"
assets="${2:-}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Usage: scripts/publish-homebrew.sh vMAJOR.MINOR.PATCH [ASSET_DIRECTORY]' >&2; exit 1;
}
source_repo='jxu-dev-c/Stillnote'
tap_repo='jxu-dev-c/homebrew-stillnote'
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
if [[ -n "$assets" ]]; then
  assets="$(cd "$assets" && pwd)"
else
  gh release download "$tag" --repo "$source_repo" --dir "$scratch/assets"
  assets="$scratch/assets"
fi
cd "$assets"
shasum -a 256 -c SHA256SUMS
# Explicit asset list keeps unrelated private release attachments out of the tap.
files=("Stillnote-${tag#v}-macos-arm64.zip" Stillnote-homebrew.tar.gz Install-Stillnote.sh
       SHA256SUMS LICENSE THIRD_PARTY_NOTICES.md RELEASE-NOTES.md)
for file in "${files[@]}"; do test -s "$file"; done
# Publish the assets before advertising their URLs on the tap's default branch.
if gh release view "$tag" --repo "$tap_repo" >/dev/null 2>&1; then
  # Published bytes are immutable, so a rerun must carry the same assets.
  gh release download "$tag" --repo "$tap_repo" --pattern SHA256SUMS --dir "$scratch/published"
  cmp SHA256SUMS "$scratch/published/SHA256SUMS"
else
  gh release create "$tag" --repo "$tap_repo" --title "$tag" --notes-file RELEASE-NOTES.md "${files[@]}"
fi
tar -xzf Stillnote-homebrew.tar.gz -C "$scratch"
gh repo clone "$tap_repo" "$scratch/tap" -- --depth 1
# Any legacy runtime formula is left in place for older app installations.
mkdir -p "$scratch/tap/Casks"
cp "$scratch/homebrew/Casks/stillnote.rb" "$scratch/tap/Casks/stillnote.rb"
cp LICENSE "$scratch/tap/LICENSE"
cp "$root/packaging/homebrew/tap-README.md" "$scratch/tap/README.md"
cd "$scratch/tap"
git add Casks/stillnote.rb LICENSE README.md
if ! git diff --cached --quiet; then
  git -c commit.gpgsign=false commit -m "Update Stillnote to $tag"
  git push origin HEAD:main
fi
echo "Published: brew install jxu-dev-c/stillnote/stillnote"
