# Stillnote @VERSION@

Local meeting recording and transcription for **Apple silicon Macs running macOS 15 or newer**.

## What's new in 0.14.1

- Tag suggestions now use OpenAI's Decisions API with `gpt-6-luna`. Each existing tag is checked
  independently; up to five tags with at least 80% confidence are added. The previous default
  model setting updates automatically.
- The meeting list's search button responds reliably to clicks through the transparent title bar.
- The Transcript and Summary tabs no longer show redundant hover labels.

## What's new in 0.14.0

### Categories are now tags

- A meeting can carry several tags. Turn them on and off from the **Tags** submenu in its context
  menu, which also has **Suggest Tags** and **Clear Tags**. Each tag in the sidebar lists every
  meeting that carries it, and create one with **New Tag…** in the sidebar's Tags menu.
- Your categories become tags with the same names, colors, and meetings. On the calendar, a
  meeting takes its first tag's color.
- **Suggest Tags** on one meeting, or **Auto-Tag Meetings…** in the sidebar's Tags menu, asks
  OpenAI which of your existing tags fit. It only adds tags; it never creates or removes one. Turn
  on **Suggest tags after each summary** in **Settings → Summaries** to tag new meetings as they
  are summarized.
- Suggestions need an OpenAI API key: save one in **Settings → Summaries**, where it goes to your
  Keychain, or export `OPENAI_API_KEY` in your shell. They send the meeting's title, its summary or
  the opening of its transcript, and your tag names to OpenAI; nothing is sent unless you ask or
  turn on the setting.
- The `stillnote` command and agent skill gain `tag list`, `tag show`, `tag create`, `tag apply`,
  `tag remove`, `tag auto`, and `list --tag`. `list` and `show` report each meeting's tags.

### Recently Deleted

- Deleted meetings are kept for five days in **Recently Deleted**, above Settings. It shows when
  each one will be removed for good, and **Restore** brings it back with its notes, summary, and
  speaker assignments. Recordings stay on disk until then.
- Meetings in Recently Deleted don't appear in lists, search, the calendar, or `stillnote`
  commands.
- The open meeting can be swiped to delete like any other, which closes its page. Meetings still
  being processed can't be deleted.

### Easier toolbar and meeting pages

- Hover over a meeting toolbar icon, or reach it with Tab, to see its name, and why it's
  unavailable when it is dimmed. The icons can be pressed with Space or Return.
- The meeting list's search button now shows a search icon instead of sliders.
- Speaker portraits sit on their own row under the title and wrap when there are many.
- Summary sections fill two columns, or one in a narrow window.

## What's new in 0.13.1

- The **Summary** tab and the folded **…** actions menu respond during playback again, instead of
  jumping playback to an earlier line.
- Choosing a speaker's portrait on the summary page opens **Assign Speaker** there, without
  switching to the transcript.

## What's new in 0.13.0

### A redesigned sidebar

- The sidebar now has **All Meetings**, **Today**, **Starred**, and **Calendar**, plus your own
  **Categories**, each with a meeting count. Calendar moved here from the toolbar, and the
  sidebar's Recent Meetings list was removed.
- Star a meeting or put it in a category from its context menu in the list or calendar. Create
  categories with **New Category**; rename, recolor, or delete them from their context menu; and
  sort them manually (drag to reorder), by name, or by meeting count from the **…** menu.

### Redesigned meeting pages

- Meetings are listed beside the open one, grouped by date with a line from each summary. Swipe
  right to star or left to delete, with Undo.
- A meeting opens on its summary — overview, decisions, action items you can check off, links,
  and notes on one page — or on its transcript, which now reads like lyrics: the current line
  large and filling in as it plays, with the recording's real waveform as the playback timeline.
- Choose a speaker's portrait to assign that voice to a person, or the speaker on a single line to
  reassign just that line.
- **New Meeting** starts recording at once and shows the recording in the window; ⌘R still opens
  recording options. The calendar's week view is redrawn with events in their category's color.

### Summaries no longer wait behind transcription

- Summaries and **Name Meeting** now run alongside transcription instead of queueing behind every
  pending one, so a large `stillnote process` batch no longer locks meetings for hours. Up to 3 run
  at once; change it in **Settings → Summaries → Jobs at once** (1–8).
- `stillnote show --json` marks checked-off action items with `"completed": true`.

## The `stillnote` command and AI agents

Stillnote bundles a `stillnote` command. Homebrew puts it on your `PATH`; otherwise it is at
`/Applications/Stillnote.app/Contents/Helpers/stillnote`.

```sh
stillnote search "product launch" --in summary
stillnote transcript replace ANE AEM --all --dry-run
stillnote speaker autotag latest --dry-run
stillnote process --all --dry-run
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

## Upgrading from 0.14.0

Existing meetings, tags, settings, downloaded models, and capture permissions are preserved.
The old default tag-suggestion model migrates to `gpt-6-luna`; custom model names must be changed
to `gpt-6-luna` in Settings → Summaries. Your existing OpenAI API key is reused.

## Upgrading from 0.13.1

Everything is preserved and capture permissions carry over; nothing new to download or set up.
Categories become tags automatically, each meeting keeping its category as its only tag. Tag
suggestions stay off until you use them or turn them on. Only meetings deleted after the update
go to Recently Deleted.

If you go back to an earlier version, it shows only each meeting's first tag, and drops the
others from any meeting it saves. Meetings in Recently Deleted stay hidden and aren't removed
until you return to 0.14.0 or later.

## Upgrading from 0.13.0

Everything is preserved and capture permissions carry over; nothing new to download or set up.

## Upgrading from 0.12.0

Existing meetings, settings, speaker profiles, and downloaded models are preserved, no new
download is needed, and capture permissions carry over. Meetings start unstarred and
uncategorized.

**Changed:** **New Meeting** starts recording immediately; use ⌘R to choose recording options
first. Calendar is now in the sidebar instead of the toolbar.

## Upgrading from 0.11.0

Existing meetings, settings, speaker profiles, and downloaded models are preserved, and no new
download is needed. macOS asks for microphone and screen/system audio permissions once more after
this update; later updates keep them.

**Changed:** **Stop, Transcribe & Summarize** now splits long recordings and replaces the
meeting's title with a generated one. `stillnote record stop` is unchanged and only transcribes.

## Upgrading from 0.10.0

Existing meetings, settings, speaker profiles, and downloaded models are preserved, and the
speech model is unchanged. Voice recognition does nothing until you use it: the first
**Learn Voices** downloads a 15 MB voice model. Auto-tagging after transcription stays off until
you turn it on in **Settings → Speakers**.

**Changed:** stopping a recording with **Stop Recording** no longer starts a transcription. To
transcribe as soon as you stop, choose **Stop, Transcribe & Summarize**, which also requests a
summary from your configured Codex or Claude Code CLI. `stillnote record stop` is unchanged and
still queues transcription.

## Upgrading from 0.9.0

Existing meetings, settings, and downloaded models are preserved. No new model download is
needed. The sidebar shows your latest 50 meetings; open All Meetings for the full history.
Recording splitting is optional and requires confirmation before replacing the original.

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

The app is signed with Stillnote's own certificate and not notarized. If macOS blocks the first launch, follow
[Apple’s Open Anyway instructions](https://support.apple.com/en-gb/102445).
If that fails or the icon keeps bouncing, follow the self-signing steps below.

## If the icon keeps bouncing or Open Anyway does not work

The current release is signed with Stillnote's own certificate, but it is **not Apple-notarized**.
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
   Dock shortcut pointing to the old copy. This copy carries your local ad-hoc signature
   instead of Stillnote's certificate, so macOS asks for capture permissions again, and again
   each time you repeat these steps.

This is a workaround for affected Macs, not a notarized release or a guaranteed fix for
every launch failure. Homebrew continues to manage the original app; the local copy does
not update automatically. After a Homebrew upgrade, quit Stillnote and repeat the steps
using the updated original. If it still fails, report your macOS version and Terminal
output; do not disable Gatekeeper globally.

## Updates, migration, and repair

Microphone and screen/system audio permissions carry over between updates. Updating from
0.11.0 or earlier asks for them one last time, because those releases were ad-hoc signed. If
**Screen & System Audio Recording** shows Stillnote enabled but capture still fails, select
Stillnote there, remove it with **−**, and allow it again when Stillnote asks.

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
- Updating from 0.11.0 or earlier asks for capture permissions one last time.
- Speech models are downloaded separately in Settings.
- Optional AI summaries use your configured Codex or Claude Code CLI with its own
  permissions, and send transcript text, notes, and context links to the provider chosen in
  Settings.
- Optional tag suggestions use your own OpenAI API key and send the meeting's title, summary or
  transcript opening, and your tag names to OpenAI.
- The `stillnote` command reads meetings whether or not the app is open, but changing data and
  starting or stopping a recording need Stillnote running.
