# Changelog

## 0.14.0

- Turn categories into tags. A meeting can now carry several tags, toggled from the **Tags** menu
  in its context menu, and each tag in the sidebar lists every meeting that carries it. Existing
  categories become tags with the same meetings, names, and colors. A meeting's first tag colors
  it on the calendar.
- Suggest tags with OpenAI. **Suggest Tags** in a meeting's Tags menu and **Auto-Tag Meetings…** in
  the sidebar's Tags menu ask OpenAI's Responses API which of your existing tags fit; Stillnote only
  adds tags, never creates or removes one. Turn on **Suggest tags after each summary** in
  **Settings → Summaries** to tag new meetings automatically. Save an OpenAI API key there (it goes
  to the Keychain) or export `OPENAI_API_KEY` in your shell.
- Add tags to the `stillnote` command and agent skill: `tag list`, `tag show`, `tag create`,
  `tag apply`, `tag remove`, `tag auto`, and `list --tag`. `list` and `show` now report each
  meeting's tags.
- Keep deleted meetings for five days. Deleting a meeting moves it to **Recently Deleted**, above
  Settings, which shows when each one will be removed for good and brings it back with
  **Restore**, with its notes, summary, and speaker assignments. Its recording stays on disk until
  then. Meetings in Recently Deleted are left out of lists, search, the calendar, and `stillnote`
  commands. The open meeting can now be swiped to delete like any other, which closes its page;
  meetings still being processed can't be deleted.
- Label the meeting toolbar's icon buttons. Hovering over one, or reaching it with Tab, shows its
  name in a capsule, and why it's unavailable when it is dimmed. The icon buttons can be reached
  with Tab and pressed with Space or Return.
- Replace the meeting list's sliders icon, which opened search, with a search icon labeled
  **Search meetings**.
- Tidy the meeting pages. Speaker portraits sit on their own row under the title and wrap when
  there are many; summary sections fill two columns, or one in a narrow window; and the list's
  title hides while the sidebar is folded. **New Tag…** is in the sidebar's Tags menu.

## 0.13.1

- Fix clicks on the **Summary** tab and the folded **…** actions menu during playback. Once a
  meeting had played a few lines, the hidden lines above the current one covered the toolbar,
  so these clicks jumped playback instead.
- Open **Assign Speaker** from a speaker's portrait on the summary page without switching to the
  transcript.

## 0.13.0

- Run summaries and **Name Meeting** alongside transcription instead of behind it. They only wait
  on the agent CLI, so they no longer queue behind every pending transcription and lock their
  meetings for hours during a large `stillnote process` batch. Up to 3 run at once; change it in
  Settings → Summaries → Jobs at once (1–8).
- Redesign the sidebar. It now has **All Meetings**, **Today**, **Starred**, and **Calendar**, plus
  your own **Categories**, each with a meeting count. Star a meeting or put it in a category from
  its context menu in the list or calendar. Create categories with **New Category**; rename,
  recolor, or delete them from their context menu; and sort them manually (drag to reorder), by
  name, or by meeting count from the **…** menu. Calendar moved from the toolbar into the sidebar,
  and the sidebar's Recent Meetings list was removed.
- Redesign the meeting pages. Meetings are listed beside the open one, grouped by date with a
  line from each summary; swipe right to star or left to delete, with Undo. A meeting opens on its
  summary — overview, decisions, action items you can check off, links, and notes on one page —
  or on its transcript, which now reads like lyrics: the current line large and filling in as it
  plays, with the recording's waveform as the timeline in the playback dock. Choose a speaker's portrait to
  assign that voice to a person, or the speaker on a single line to reassign just that line.
  **New Meeting** starts recording at once and shows the recording in the window (⌘R still opens
  recording options). The calendar's week view is redrawn with events in their category's color.

## 0.12.0

- Add `stillnote process`, which queues meetings already in the library through the whole
  **Stop, Transcribe & Summarize** pipeline — split, transcribe, auto-tag, summarize, and name —
  one meeting or every unfinished one with `--all`. Each resumes where it stopped, so a
  transcribed meeting goes straight to its summary. `--dry-run` shows the plan; `--status`,
  `--since`, `--until`, and `--limit` narrow the batch; `--no-split` and `--keep-title` skip
  those steps. Add `stillnote name` to title one meeting.
- Make **Stop, Transcribe & Summarize** run the whole pipeline. A recording at or above the
  split threshold in Settings → Transcription → Long recordings is now split into 20-minute
  parts first, and each meeting is named with **Name Meeting**'s provider once its summary is
  ready. Named parts keep their `partN` suffix.
- Keep microphone and screen/system audio permissions across updates. Releases are now signed
  with one persistent Stillnote certificate instead of a per-build ad-hoc signature, which macOS
  treated as a new app every time. Updating from 0.11.0 or earlier asks for permissions one last
  time. The app is still not Apple-notarized.

## 0.11.0

- Recognize speakers by voice. **Learn Voices** in Settings → Speakers reads a voiceprint for
  every speaker you've linked to a profile and tests itself against those tags, reporting how
  often its matches were right. **Auto-Tag Speakers** on the transcript links untagged speakers
  whose voices match a profile confidently and leaves uncertain ones alone; **Auto-Tag All
  Meetings** does the same across the library and names any meeting it had to skip, and an
  opt-in setting runs it after every transcription. Speakers linked by voice show a waveform badge until you confirm or change them.
  The first run downloads a 15 MB Core ML voice model; voices never leave the Mac.
- Add `stillnote speaker voices`, `speaker learn`, and `speaker autotag` (with `--all` and
  `--dry-run`); `show --json` marks voice-matched speakers with `voice_match`.
- Replace **Stop & Transcribe** in the menu bar and **Finish & Transcribe** in the recording
  window with two actions: **Stop Recording** only saves the recording, and **Stop, Transcribe &
  Summarize** also transcribes it and then summarizes it with the provider from Settings, after
  any opt-in auto-tagging so the summary uses recognized names. Without the speech model, only
  Stop Recording is offered. The recording window puts the two on their own row so the longer
  label fits.

## 0.10.0

- Split long audio-only recordings into 20-minute parts after confirmation. The default
  eligibility threshold is 50 minutes and can be set to any positive whole number in Settings.
  Parts keep their transcript timestamps relative to their own audio, notes, and context links;
  summaries start empty. Splitting replaces the original meeting and audio.
- Copy a meeting's summary from Export → Copy Summary, including decisions and action items.
- Load meeting details on demand and search in the database to reduce library startup time,
  memory use, and navigation delays. The sidebar shows the latest 50 meetings; All Meetings
  retains the full history, and an opened older meeting remains visible under Selected Meeting.
- Save edited meeting titles when editing ends.
- Make speaker assignment searchable and keep Edit Profiles available in Settings.
- Restrict speaker-filtered search results to transcript segments attributed to that speaker.
- Repair inverted transcription timestamp rows and detect repetition loops even when timestamps advance.
- Show recording controls for recordings started through the menu bar or command interface.
- Show only one summary regeneration action.
- Validate documented skill command options against the CLI catalog and refresh the skill's
  speaker-search guidance and summary output example.

## 0.9.0

- Open screen recordings in a sheet from the **Show Video** button in the playback bar instead
  of playing them inline above the summary. Every meeting now has the same bottom playback bar.
- Name meetings with a separate **Name Meeting** button beside the title instead of as part of a
  summary. It sends one request with its own fixed prompt, using the meeting's summary, or its
  transcript when there is no summary. Summaries no longer change titles: a custom summary prompt
  could leave out the title, and long meetings could be named after a single section.
- Start summaries and Name Meeting without a confirmation sheet. The provider and model chosen in
  Settings apply directly, and `stillnote summarize` still needs `--allow-remote`.
- Run summaries as a plain `codex exec` or `claude -p` with the CLI's native JSON schema, using
  your own CLI config: skills, MCP servers, instructions files, and permissions now apply, so a
  prompt can ask the agent to use your skills. The whole transcript goes in one request
  instead of being summarized in sections and merged. Settings → Summaries keeps provider, model,
  effort, and prompt; the YOLO and shell-environment options are gone, and the CLI always gets
  your login shell's environment.
  **Breaking:** a custom shell path or turning shell inheritance off is no longer supported, and
  those choices are dropped on upgrade. If your CLI credentials or PATH are exported from a
  different shell's startup files, such as `.bash_profile` while your account shell is Zsh,
  export them from your login shell's startup files instead. If those startup files hang or
  prompt, fix them, or summaries and Name Meeting fail with "Could not load your shell
  environment."
- Send a meeting's notes and context links with its summary request. Until now summaries ignored
  them. The agent is asked to look up the links with your skills, such as work items or emails,
  and use what it finds as context. When notes or links change after a summary was made, the
  Summary tab says so and offers Regenerate.
- Always include the local video path in summary requests for recordings with screen video.
  The **Send Video Path to AI** option is gone; the agent can open the path according to its own
  configuration and permissions.
- Show calendar meeting durations with explicit units, keeping the duration visible in narrow
  and overlapping Day and Week columns. Hovering a meeting shows its full time range.
- Balance the spacing of the toolbar pickers, center the toolbar icons, and match the Import
  Audio icon to the recording button. The sidebar drops the Library heading and the waveform
  icons on recent meetings; busy and error indicators remain.

## 0.8.0

- Add a calendar view to All Meetings. A List | Calendar switch in the toolbar shows meetings by
  day, week, or month, like Apple's Calendar app. Meetings appear when they happened and are as
  tall as they lasted, overlapping meetings sit side by side, and ⌘T goes to today. Clicking a
  meeting opens it, and the toolbar search filters the calendar too.
- Place new recordings at the time capture started instead of the time they were saved, and
  estimate the start of older recordings. Imports stay at their import time.
- Move transcript search into the macOS toolbar. It appears on the Transcript tab and collapses
  to a button when the window is narrow.
- Offer every thinking effort level the summary provider accepts: None, Minimal, Low, Medium,
  High, Extra High, and Max for Codex, and Low through Max for Claude Code. A saved level the
  provider doesn't accept falls back to Low.
- Let summaries replace an imported meeting's filename title when the Title field was left
  blank, and fix older recordings and imports whose default title a summary could not replace.
  Titles you typed yourself are still never replaced.
- Keep a recording's audio when Stop is pressed again while it is saving. The menu and recording
  sheet show that it is saving until the meeting is stored.

## 0.7.0

- Offer to record when a meeting starts. When Teams, Zoom, Webex, Slack, FaceTime, Discord, or a
  web browser starts using the microphone, a small reminder at the top right of the screen offers
  to start recording. Close it with its × button, or it goes away by itself when the call ends or
  after a minute. The feature is opt-in and is off until you turn it on in Settings →
  Transcription.
- Keep a transcript's speaker chips on one row that scrolls sideways when there are more speakers
  than fit, instead of stacking them and pushing the transcript down.
- Stop recent meetings in the sidebar from drawing behind the Settings button.

## 0.6.0

- Add a menu bar icon to start and stop a recording, open Stillnote, and open Settings. It
  shows the elapsed time while recording.
- Stop asking for a title when starting a recording. It is named `Meeting · <date>` until its
  summary suggests a descriptive title; a title you type yourself is never replaced.
- Manage speaker profiles from the command line: `stillnote speaker list`, `show`, `add`,
  `update`, `delete`, and `assign`.

## 0.5.0

- Trim leading and trailing silence from a saved recording, for the times a recording kept
  running after the meeting ended. Only cuts over a minute are applied, and a recording with
  no detected speech is kept whole.
- Silence typing, fans, and static wherever nobody is speaking in the audio sent to
  transcription. Speech is never filtered, and playback keeps the original recording.
- Add a Recording cleanup section to transcription settings with a sensitivity control.
- Show on a meeting how much silence was trimmed and how long the recording originally was.
- Download a 2.2 MB Silero VAD model alongside the speech engine to detect speech locally.
- Bundle a `stillnote` command for reading, searching, and correcting meetings and for starting
  and stopping a recording. Homebrew puts it on your PATH.
- Replace text across every transcript in one step, with a dry run that counts the matches first.
- Read meetings, search, and export while the app is closed; changes and recording need it open.
- Add a Settings → Advanced switch for the command interface, on by default.
- Publish a `stillnote` agent skill under `skills/`, installable with
  `npx skills add jxu-dev-c/Stillnote`.

## 0.4.0

- Add Quality, Balanced, and Low Memory transcription modes with device-aware memory checks.
- Reduce transcription memory pressure with windowed audio reads, smaller prefill batches, and optimized decoding.

- Bundle a native Swift MLX speech engine; remove the Python and Homebrew runtime requirement.
- Download a pinned 8-bit checkpoint once (about 1.3 GB), preserving older model files and meetings.
- Preserve diarization, hot words, progress, bounded GPU memory, and process-based cancellation.

## 0.3.0

- Save one hot-word list per user and apply it to transcription and retranscription.
- Show examples for separate words and phrases with spaces in transcription settings.
- Update the packaged speech worker to accept hot-word hints, with upgrade guidance for older runtimes.

## 0.2.1

- Speed up speech model downloads with resumable parallel chunks.
- Document local self-signing when macOS stalls during launch.

## 0.2.0

- Install the app and its speech runtime through the Stillnote Homebrew tap.
- Package pinned speech dependencies as verified offline wheels for macOS 15+.
- Discover Homebrew runtimes from Finder launches while retaining source setup support.

## 0.1.0

Experimental native macOS meeting notebook with local recording, MOSS transcription,
speaker labels, notes, exports, and optional CLI-based summaries.
