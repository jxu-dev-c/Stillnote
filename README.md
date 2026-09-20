# Stillnote

A private meeting notebook for your Mac. Record meetings or import recordings,
turn speech into speaker-labeled transcripts, and keep summaries and notes together.

## Why Stillnote?

- **Local transcription.** Audio and speech recognition stay on your Mac, with offline transcription after the initial model download.
- **Capture the whole conversation.** Record microphone and system audio, with optional screen video.
- **Make meetings useful.** Edit transcripts, name speakers, add notes, and export your work.
- **Optional AI summaries.** Generate key points, decisions, and action items through Codex or Claude Code. Transcript text may be sent to hosted models with your confirmation.

## Installation

**Requirements:** Apple silicon Mac, macOS 15+, and [Homebrew](https://brew.sh).

```bash
brew install jxu-dev-c/stillnote/stillnote-runtime jxu-dev-c/stillnote/stillnote
```

Homebrew installs the app and its isolated speech runtime, including Python. No
Stillnote source checkout or manual Python setup is needed. This command requires
the first Homebrew-enabled release to have been published to the
[Stillnote tap](https://github.com/jxu-dev-c/homebrew-stillnote).

Open Stillnote from Applications. The app is currently ad-hoc signed; if macOS blocks
its first launch, use [Open Anyway in Privacy & Security](https://support.apple.com/en-gb/102445).

In **Settings**, download the speech model once (about 1.8 GB). Grant microphone
and screen/system audio permissions when prompted. For AI summaries, install and
sign in to the Codex or Claude Code CLI, then select it in Settings.

## Updates and repair

Quit Stillnote before updating:

```bash
brew update
brew upgrade jxu-dev-c/stillnote/stillnote-runtime
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

To repair speech dependencies, run `brew reinstall jxu-dev-c/stillnote/stillnote-runtime`.
If you prefer a downloaded app ZIP, install only the runtime with
`brew install jxu-dev-c/stillnote/stillnote-runtime`.

When migrating from a manual app installation, quit Stillnote and move the old app
out of `/Applications` or `~/Applications` before installing with Homebrew. Keep
`~/Library/Application Support/Stillnote`: it contains your meetings and models.
The older runtime there can remain; the app prefers the Homebrew runtime.

Uninstall with `brew uninstall --cask jxu-dev-c/stillnote/stillnote` and, optionally,
`brew uninstall jxu-dev-c/stillnote/stillnote-runtime`. These preserve your meetings,
settings, and models. Avoid `--zap` or deleting Application Support to keep your data.

## Contributing

Bug reports, suggestions, and pull requests are welcome. Read the
[contributing guide](CONTRIBUTING.md), keep changes focused, and run
`./scripts/check.sh` before submitting a pull request. Use synthetic examples
instead of private meeting content.
