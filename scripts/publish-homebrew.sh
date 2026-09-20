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
assets=("Stillnote-${tag#v}-macos-arm64.zip"
        Stillnote-homebrew.tar.gz Install-Stillnote.sh SHA256SUMS LICENSE THIRD_PARTY_NOTICES.md RELEASE-NOTES.md)
for asset in "${assets[@]}"; do test -s "$asset"; done
tar -xzf Stillnote-homebrew.tar.gz
gh repo clone "$tap_repo" "$scratch/tap"
mkdir -p "$scratch/tap/Casks" "$scratch/tap/Formula"
cp homebrew/Casks/stillnote.rb "$scratch/tap/Casks/"
# Retain any legacy runtime formula for older app installations; the new cask does not depend on it.
cp LICENSE "$scratch/tap/LICENSE"
cat > "$scratch/tap/README.md" <<'EOF'
# Stillnote Homebrew tap

For Apple silicon Macs running macOS 15 or newer:

```sh
brew install jxu-dev-c/stillnote/stillnote
```

Open Stillnote, approve its first launch in macOS Privacy & Security if needed,
and download the speech model in Settings. The app is currently ad-hoc signed.

## If the icon keeps bouncing or Open Anyway does not work

The current release is already ad-hoc signed, but it is **not Apple-notarized**.
On some Macs, macOS can hold it before startup even after **Open Anyway**. Reinstalling
the speech runtime does not fix this launch problem.

You can make a fresh copy and self-sign it locally. This does **not** require a paid
Apple Developer membership. Only do this with Stillnote downloaded from this project's
release or Homebrew tap: self-signing is your local approval, not an Apple malware check.

1. Quit Stillnote. If its icon keeps bouncing, use **Apple menu → Force Quit → Stillnote**.
2. Open **Terminal**, paste the entire block below, and press Return. It detects the
   usual app locations; for a custom install, set `source_app` to that app's full path.

```bash
(
  set -eu
  source_app="/Applications/Stillnote.app"
  if [ ! -d "$source_app" ]; then
    source_app="$HOME/Applications/Stillnote.app"
  fi
  if [ ! -d "$source_app" ]; then
    echo "Stillnote.app was not found. Set source_app to your installed app's path."
    exit 1
  fi

  # A new path matters: signing the already-stalled copy in place may not help.
  target_app="$HOME/Applications/Stillnote Local $(date +%Y%m%d-%H%M%S).app"
  if [ -e "$target_app" ]; then
    echo "The destination already exists. Wait a second and run this again."
    exit 1
  fi
  /usr/bin/codesign --verify --strict "$source_app"
  mkdir -p "$HOME/Applications"
  /usr/bin/ditto --noextattr --norsrc "$source_app" "$target_app"
  /usr/bin/codesign --force --sign - --options runtime --timestamp=none \
    --identifier local.stillnote.app "$target_app"
  /usr/bin/codesign --verify --strict "$target_app"
  /usr/bin/open "$target_app"
  echo "Open this copy from now on: $target_app"
)
```

The command copies the bundle without its downloaded-file metadata, applies a local
ad-hoc signature, and opens it at a new path. It does not change global Gatekeeper
settings or delete the original app, meetings, notes, or downloaded models.

3. Use the new **Stillnote Local …** app in your user Applications folder. Replace any
   Dock shortcut pointing to the old copy. macOS may ask for capture permissions again.

This is a workaround for affected Macs, not a notarized release or a guaranteed fix for
every launch failure. Homebrew continues to manage the original app; the local copy does
not update automatically. After a Homebrew upgrade, quit Stillnote and repeat the steps
using the updated original. If it still fails, report your macOS version and Terminal
output; do not disable Gatekeeper globally.

Quit Stillnote before upgrading:

```sh
brew update
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

Repair the bundled speech engine with `brew reinstall --cask jxu-dev-c/stillnote/stillnote`.
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
echo "Published: brew install jxu-dev-c/stillnote/stillnote"
