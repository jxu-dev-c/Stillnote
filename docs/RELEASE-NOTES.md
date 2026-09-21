# Stillnote @VERSION@

Local meeting recording and transcription for **Apple silicon Macs running macOS 15 or newer**.

## What's new in 0.4.0

- **Bundled native speech engine:** transcription now runs through Swift MLX. Python and the separate Homebrew speech runtime are no longer required.
- **Transcription memory modes:** choose Quality, Balanced, or Low Memory in Settings → Transcription. Balanced uses 8-bit context storage; Low Memory reduces it further and can change wording, timestamps, or speaker assignments.
- **More efficient transcription:** windowed audio reads, smaller prefill batches, and optimized decoding reduce memory pressure. Device-aware memory checks help avoid workloads that exceed the estimated budget.
- Existing speaker labels, personal hot words, progress reporting, and cancellation remain supported.

## Upgrading from 0.3.0

Download the new pinned 8-bit speech model once in Settings (about 1.3 GB).
Existing meetings, settings, and older model files are preserved. The legacy
`stillnote-runtime` package is no longer needed by this version and may be removed
if you no longer use an older Stillnote app.

## Installation

After this release has been published to the [Homebrew tap](https://github.com/jxu-dev-c/homebrew-stillnote):

```sh
brew install jxu-dev-c/stillnote/stillnote
```

Homebrew installs the app with its native speech engine. Open Stillnote from
Applications, then download the speech model once in Settings (about 1.3 GB).
Recording and transcription work offline after that download.

For a manual app download, extract `Stillnote-@VERSION@-macos-arm64.zip`, move
Stillnote.app into Applications. No separate speech runtime is needed.

The app is ad-hoc signed and not notarized. If macOS blocks the first launch, follow
[Apple’s Open Anyway instructions](https://support.apple.com/en-gb/102445).
If that fails or the icon keeps bouncing, follow the self-signing steps below.

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

## Updates, migration, and repair

Quit Stillnote before upgrading:

```sh
brew update
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

Repair the app with `brew reinstall --cask jxu-dev-c/stillnote/stillnote`.
For migration, quit and move the manually installed app out of Applications before
installing through Homebrew. Preserve `~/Library/Application Support/Stillnote`;
existing meetings are reused. Download the native model once; legacy files may remain.

Uninstall the app with `brew uninstall --cask jxu-dev-c/stillnote/stillnote` and optionally
remove `stillnote-runtime`. Neither operation deletes meetings, settings, or models.

## Current limitations

- First launch may require approval in macOS Privacy & Security.
- Updates may require granting capture permissions again.
- Speech models are downloaded separately in Settings.
- Optional AI summaries use your configured Codex or Claude Code CLI and may send
  transcript text to hosted models after your confirmation.
