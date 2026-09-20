#!/usr/bin/env bash
# Maintainer-operated publication; requires gh access to both repositories.
set -euo pipefail
tag="${1:-}"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Usage: scripts/publish-homebrew.sh vMAJOR.MINOR.PATCH' >&2; exit 1;
}
source_repo='jxu-dev-c/Stillnote'
tap_repo='jxu-dev-c/homebrew-stillnote'
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
[[ "$(gh release view "$tag" --repo "$source_repo" --json isDraft --jq .isDraft)" == false ]]
gh release download "$tag" --repo "$source_repo" --dir "$scratch/assets"
cd "$scratch/assets"
shasum -a 256 -c SHA256SUMS
# Explicit asset list keeps unrelated private release attachments out of the tap.
assets=("Stillnote-${tag#v}-macos-arm64.zip" "Stillnote-runtime-${tag#v}-macos-arm64.tar.gz"
        Stillnote-homebrew.tar.gz Install-Stillnote.sh SHA256SUMS LICENSE THIRD_PARTY_NOTICES.md RELEASE-NOTES.md)
for asset in "${assets[@]}"; do test -s "$asset"; done
tar -xzf Stillnote-homebrew.tar.gz
gh repo clone "$tap_repo" "$scratch/tap"
mkdir -p "$scratch/tap/Casks" "$scratch/tap/Formula"
cp homebrew/Casks/stillnote.rb "$scratch/tap/Casks/"
cp homebrew/Formula/stillnote-runtime.rb "$scratch/tap/Formula/"
cp LICENSE "$scratch/tap/LICENSE"
cat > "$scratch/tap/README.md" <<'EOF'
# Stillnote Homebrew tap

For Apple silicon Macs running macOS 15 or newer:

```sh
brew install --cask jxu-dev-c/stillnote/stillnote
```

Open Stillnote, approve its first launch in macOS Privacy & Security if needed,
and download the speech model in Settings. The app is currently ad-hoc signed.

Quit Stillnote before upgrading:

```sh
brew update
brew upgrade jxu-dev-c/stillnote/stillnote-runtime
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

Repair speech dependencies with `brew reinstall jxu-dev-c/stillnote/stillnote-runtime`.
Uninstall with `brew uninstall --cask jxu-dev-c/stillnote/stillnote`; optionally remove
`stillnote-runtime` too. Meetings and downloaded models remain in Application Support.

If you installed Stillnote manually, quit it and move the old app out of Applications
before installing through Homebrew. Keep the Stillnote folder in Application Support.

Release assets are hosted here so installation does not require access to the source repository.
EOF
cd "$scratch/tap"
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git checkout -b main
  git add README.md LICENSE
  git -c commit.gpgsign=false commit -m "Initialize Stillnote Homebrew tap"
  git push -u origin main
fi
git add Casks Formula LICENSE README.md
if ! git diff --cached --quiet; then
  git -c commit.gpgsign=false commit -m "Update Stillnote to $tag"
fi
# Publish assets before advertising their URLs on the tap's default branch.
existing=$(gh api --paginate "repos/$tap_repo/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .draft")
if [[ -z "$existing" ]]; then
  gh release create "$tag" --repo "$tap_repo" --draft --title "$tag" --notes-file "$scratch/assets/RELEASE-NOTES.md"
  existing=true
fi
if [[ "$existing" == true ]]; then
  cd "$scratch/assets"
  gh release upload "$tag" --repo "$tap_repo" --clobber "${assets[@]}"
  gh release edit "$tag" --repo "$tap_repo" --draft=false --prerelease=false
else
  # Never repoint a published version to different bytes.
  gh release download "$tag" --repo "$tap_repo" --pattern SHA256SUMS --dir "$scratch/published"
  cmp "$scratch/assets/SHA256SUMS" "$scratch/published/SHA256SUMS"
fi
git -C "$scratch/tap" push origin HEAD:main
echo "Published: brew install --cask jxu-dev-c/stillnote/stillnote"
