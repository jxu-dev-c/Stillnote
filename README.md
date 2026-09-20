# Stillnote

An extremely lightweight, private meeting notebook for your Mac. Record meetings or import recordings,
turn speech into speaker-labeled transcripts, and keep summaries and notes together.

Transcription and speaker detection are powered by [OpenMOSS's MOSS-Transcribe-Diarize model](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize).

<img width="1268" height="895" alt="image" src="https://github.com/user-attachments/assets/1dc6f398-8ca3-46db-832e-b40ef7d594d3" />

<img width="752" height="620" alt="image" src="https://github.com/user-attachments/assets/3b5631d6-6acf-43a9-9374-9ea429d1325c" />


## Why Stillnote?

- **Local transcription.** Transcription and Speaker Detection entirely stay on your Mac.
- **AI Agent summaries.** Use **Codex or Claude Code CLI** for summaries, without needing extra API configurations. 

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
If that fails or the icon keeps bouncing, follow the self-signing steps below.

In **Settings**, download the speech model once (about 1.8 GB). Grant microphone
and screen/system audio permissions when prompted. For AI summaries, install and
sign in to the Codex or Claude Code CLI, then select it in Settings.

## If the icon keeps bouncing or Open Anyway does not work

The current release is already ad-hoc signed, but it is **not Apple-notarized**.
On some Macs, macOS can hold it before startup even after **Open Anyway**. 

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

Uninstall with `brew uninstall --cask jxu-dev-c/stillnote/stillnote` and, optionally,
`brew uninstall jxu-dev-c/stillnote/stillnote-runtime`. These preserve your meetings,
settings, and models. Avoid `--zap` or deleting Application Support to keep your data.

## Contributing

Bug reports, suggestions, and pull requests are welcome. Read the
[contributing guide](CONTRIBUTING.md), keep changes focused, and run
`./scripts/check.sh` before submitting a pull request. Use synthetic examples
instead of private meeting content.
