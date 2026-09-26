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

**Requirements:** Apple silicon Mac and macOS 15+. Install with [Homebrew](https://brew.sh) or the app ZIP.

```bash
brew install jxu-dev-c/stillnote/stillnote
```

The app bundles its native Swift speech engine. Python and a separate runtime
installation are not needed. This command requires
the first Homebrew-enabled release to have been published to the
[Stillnote tap](https://github.com/jxu-dev-c/homebrew-stillnote).

Open Stillnote from Applications. The app is currently ad-hoc signed; if macOS blocks
its first launch, use [Open Anyway in Privacy & Security](https://support.apple.com/en-gb/102445).
If that fails or the icon keeps bouncing, follow the self-signing steps below.

In **Settings**, download the speech model once (about 1.3 GB). Grant microphone
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
brew upgrade --cask jxu-dev-c/stillnote/stillnote
```

To repair the bundled speech engine, run `brew reinstall --cask jxu-dev-c/stillnote/stillnote`
or replace the app using a fresh ZIP. Existing installations need a one-time download
of the converted 8-bit model in Settings. Existing meetings and old model files are preserved.

Uninstall with `brew uninstall --cask jxu-dev-c/stillnote/stillnote`. These preserve your meetings,
settings, and models. Avoid `--zap` or deleting Application Support to keep your data.

## Command line and AI agents

Stillnote bundles a `stillnote` command for reading and correcting meetings and for driving
recording. Homebrew puts it on your `PATH`; otherwise call it at
`/Applications/Stillnote.app/Contents/Helpers/stillnote`, or symlink it somewhere on your `PATH`.

```bash
stillnote status
stillnote list --speaker Jackson --since 2026-05 --until 2026-05
stillnote search "product launch" --in summary
stillnote show latest --segments
stillnote transcript replace ANE AEM --all --dry-run   # count first
stillnote transcript replace ANE AEM --all --whole-word
stillnote record start --title "Design review"
stillnote record stop
stillnote help
```

Reading works whether or not the app is open. Changing data and recording need Stillnote running:
it is the only writer, so a correction made here shows up in the open window, and capture
permissions belong to the app rather than to your terminal. Add `--json` to any command for
structured output. Turn the whole interface off in **Settings → Advanced**.

Generating a summary sends the transcript to your configured agent CLI, so it asks for consent
explicitly: `stillnote summarize <id> --allow-remote`.

### Agent skill

To let a coding agent use all of this, install the published skill with the
[skills CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add jxu-dev-c/Stillnote
```

It teaches the agent the commands, the JSON shapes, and the care they call for — to count the
matches of a library-wide replacement before applying it, to tell you when a correction cleared a
summary, and never to send a transcript to a provider unless you asked. The source is in
[skills/stillnote](skills/stillnote/SKILL.md).

## Contributing

Bug reports, suggestions, and pull requests are welcome. Read the
[contributing guide](CONTRIBUTING.md), keep changes focused, and run
`./scripts/check.sh` before submitting a pull request. Use synthetic examples
instead of private meeting content.

### Transcription modes

Choose a mode in **Settings → Transcription → Mode**. **Quality** is the default and
preserves the model's original context precision. **Balanced** compresses context
memory moderately. **Low Memory** compresses it further; recognition and speaker
labels can differ. Every mode uses the same installed model and keeps the whole
meeting in context. No additional downloads are required.

The choice is saved automatically and applies to jobs queued afterward, including
retranscriptions. If the selected mode cannot fit the Mac's memory budget, the job
stops and suggests a lower-memory mode or shorter recording. Existing transcripts
remain intact. Compression reduces context storage; it does not guarantee faster
transcription. See [performance verification](docs/TRANSCRIPTION-PERFORMANCE.md).

### Transcription hot words

In **Settings → Transcription → Hot words**, enter one word or phrase per line,
then select **Save Hot Words**. Names, acronyms, and specialized terms guide MOSS
recognition; they are hints, not guaranteed replacements. One list is saved locally
for your macOS user and applies to all transcriptions and retranscriptions queued
after saving. Existing transcripts are unchanged. To disable hints, clear the list
and save. Blank lines and duplicate entries are removed.

Hot words are supported by the bundled native speech engine.
