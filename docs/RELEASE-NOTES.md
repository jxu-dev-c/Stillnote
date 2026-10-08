# Stillnote @VERSION@

Local meeting recording and transcription for **Apple silicon Macs running macOS 15 or newer**.

## What's new in 0.9.0

### Summaries use your own Codex or Claude Code setup

- A summary is now one plain `codex exec` or `claude -p` request, run as if you typed it in
  Terminal. Your CLI's sign-in, skills, MCP servers, instruction files, and permissions apply, so
  a summary prompt can ask the agent to use your skills.
- The whole transcript goes out in one request instead of being summarized in sections and
  merged.
- A meeting's **notes** and **context links** are now sent with its summary request. The agent is
  asked to look the links up with your skills, such as work items or emails, and use what it
  finds as context. When notes or links change after a summary was made, the **Summary** tab says
  so and offers **Regenerate**.
- For recordings with screen video, summary requests always include the local video path. The
  agent can open it according to its own configuration and permissions.
- Summaries start right away, without a confirmation sheet: choosing the provider and model in
  **Settings → Summaries** is the consent. `stillnote summarize` still needs `--allow-remote`.
- **Settings → Summaries** keeps provider, model, effort, and prompt. The YOLO, shell-path, and
  inherit-shell-environment options are gone: the CLI always gets your login shell's environment.

### Name Meeting

- A **Name Meeting** button beside the title asks the provider from Settings for a short title,
  using the meeting's summary, or its transcript when there is no summary. It replaces any title,
  because you asked for it.
- Summaries no longer change titles. New recordings keep their dated default title, and imports
  keep their filename, until you rename them or click **Name Meeting**.

### Video in a sheet

- Screen recordings no longer play above the summary. Every meeting has the same bottom playback
  bar, and meetings with screen video add a **Show Video** button that opens the video in a
  resizable sheet. Playback, speed, and transcript timestamps stay in sync, and playback continues
  in the bar after you close the sheet.

### Fixes and polish

- Calendar meetings show durations with explicit units, and keep them visible in narrow and
  overlapping Day and Week columns. Hovering a meeting shows its full time range.
- Toolbar pickers have balanced spacing, toolbar icons are centered, and the Import Audio icon
  matches the recording button. The sidebar drops the Library heading and the waveform icons on
  recent meetings.

## The `stillnote` command and AI agents

Stillnote bundles a `stillnote` command. Homebrew puts it on your `PATH`; otherwise it is at
`/Applications/Stillnote.app/Contents/Helpers/stillnote`.

```sh
stillnote search "product launch" --in summary
stillnote transcript replace ANE AEM --all --dry-run
stillnote record stop
stillnote help
```

Reading meetings works whether or not the app is open. Corrections and recording need Stillnote
running: it is the only writer, so a change made here appears in the open window, and capture
permissions belong to the app rather than to your terminal. Add `--json` to any command for
structured output, and switch the whole interface off in Settings → Advanced. Generating a summary
still asks for consent, as `stillnote summarize <id> --allow-remote`.

To let a coding agent drive it, install the published skill with
`npx skills add jxu-dev-c/Stillnote`.

## Upgrading from 0.8.0

Existing meetings, settings, and downloaded models are preserved, and no new download is
needed. Your summary provider, model, effort, and prompt are kept; a stored copy of the previous
default prompt moves to the new default.

**Breaking:** a custom shell path, or turning shell inheritance off, is no longer supported and is
dropped on upgrade. If your CLI credentials or `PATH` are exported from a different shell's
startup files, such as `.bash_profile` while your account shell is Zsh, export them from your
login shell's startup files instead. If those startup files hang or prompt, fix them, or summaries
and Name Meeting fail with "Could not load your shell environment."

## Upgrading from 0.7.0

Existing meetings, settings, and downloaded models are preserved, and no new download is
needed. Your saved summary effort level is kept. Older meetings' default titles are updated
the next time they are summarized.

## Upgrading from 0.6.0

Existing meetings, settings, and downloaded models are preserved, and no new download is
needed. Meeting reminders stay off until you turn them on.

## Upgrading from 0.5.0

Existing meetings, settings, and downloaded models are preserved, and no new download is
needed. Homebrew relinks the updated `stillnote` command. The menu bar icon appears as soon
as the app is running.

## Upgrading from 0.4.0

Existing meetings and settings are preserved. Download the supporting Silero VAD model
in Settings to use recording cleanup. Homebrew also links the new `stillnote` command.

## Upgrading from 0.3.0 or earlier

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
- Optional AI summaries use your configured Codex or Claude Code CLI with its own
  permissions, and send transcript text, notes, and context links to the provider chosen in
  Settings.
- The `stillnote` command reads meetings whether or not the app is open, but changing data and
  starting or stopping a recording need Stillnote running.
