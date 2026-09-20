# Stillnote @VERSION@

Local meeting recording and transcription for **Apple silicon Macs running macOS 15 or newer**.

## Installation

After this release has been published to the [Homebrew tap](https://github.com/jxu-dev-c/homebrew-stillnote):

```sh
brew install --cask jxu-dev-c/stillnote/stillnote
```

Homebrew installs the app, Python, and all speech dependencies. Open Stillnote from
Applications, then download the speech model once in Settings (about 1.8 GB).
Recording and transcription work offline after that download.

For a manual app download, extract `Stillnote-@VERSION@-macos-arm64.zip`, move
Stillnote.app into Applications, and install its runtime with:

```sh
brew install jxu-dev-c/stillnote/stillnote-runtime
```

The app is ad-hoc signed and not notarized. If macOS blocks the first launch, follow
[Apple’s Open Anyway instructions](https://support.apple.com/en-gb/102445).

## Updates, migration, and repair

Quit Stillnote before upgrading:

```sh
brew update
brew upgrade jxu-dev-c/stillnote/stillnote-runtime
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

Repair dependencies with `brew reinstall jxu-dev-c/stillnote/stillnote-runtime`.
For migration, quit and move the manually installed app out of Applications before
installing through Homebrew. Preserve `~/Library/Application Support/Stillnote`;
existing meetings and models are reused, and the legacy runtime may remain.

Uninstall the app with `brew uninstall --cask jxu-dev-c/stillnote/stillnote` and optionally
remove `stillnote-runtime`. Neither operation deletes meetings, settings, or models.

## Current limitations

- First launch may require approval in macOS Privacy & Security.
- Updates may require granting capture permissions again.
- Speech models are downloaded separately in Settings.
- Optional AI summaries use your configured Codex or Claude Code CLI and may send
  transcript text to hosted models after your confirmation.
