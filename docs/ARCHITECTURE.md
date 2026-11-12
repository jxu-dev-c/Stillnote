# Stillnote implementation contract

A native macOS 15+ app for Apple silicon: SwiftUI interface, SwiftPM package with a pinned native MLX dependency. Capture, storage, decoding, summaries, and exports are Swift and run
in process. MOSS 0.9B inference runs in a short-lived bundled Swift worker using the vendored MOSS package. Nothing listens on
a network port; the bundled `stillnote` command reaches the app through a Unix domain socket
inside the library folder. No recording or transcription leaves the computer. Summaries and Name Meeting
send meeting text to the provider chosen in Settings; the CLI also requires `--allow-remote`.

## Layout

```
Stillnote.app
├── StillnoteCore   library target, no SwiftUI, fully unit-tested
└── Stillnote       executable target: SwiftUI views + AppModel
Sources/StillnoteSpeechWorker  bundled native MLX executable; models download separately
Sources/StillnoteCLI           bundled `stillnote` command; a client of the running app
```

| Module | Responsibility |
| --- | --- |
| `Sources/StillnoteCore/Models/` | `Meeting`, `Segment`, `MeetingSummary`, `ContextLink`, `AppSettings`, input bounds, formatting. |
| `Sources/StillnoteCore/Store/` | `Paths` (Application Support layout, checkout adoption) and the `Store` actor over SQLite. |
| `Sources/StillnoteCore/Capture/` | ScreenCaptureKit session, device and permission discovery, session persistence and recovery. |
| `Sources/StillnoteCore/Audio/` | Decoding to 16 kHz mono, bounded-memory mixing, silence trimming and non-speech suppression, MP4 muxing, extension resolution for stored media. |
| `Sources/StillnoteCore/Speech/` | Model manifest, verified download, readiness, MOSS, silence-detection and voice-embedding worker drivers, transcript parsing, voice matching and calibration. |
| `Sources/StillnoteCore/Summary/` | Headless Codex/Claude Code adapters over `posix_spawn`, chunking, validation, local merging. |
| `Sources/StillnoteCore/Export/` | Markdown, plain text, SRT, and JSON exports. |
| `Sources/StillnoteCore/CLI/` | Command catalog and parser, wire protocol, socket transport, transcript replacement, and library search. Every result and its rendering, so both processes answer identically. |
| `Sources/Stillnote/` | `AppModel` (observable state, job orchestration), `CommandServer`, and the SwiftUI screens. |
| `Sources/StillnoteCLI/` | The `stillnote` executable: argument handling, transport choice, and output. |

## Data

`~/Library/Application Support/Stillnote/data/stillnote.sqlite3` keeps the schema the
previous localhost version wrote, so an existing database opens unchanged:

```sql
CREATE TABLE meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL);  -- single row id=1
```

Later tables are additive and created on the first writable open: `speaker_profiles`,
`categories(id, data)`, the derived `meeting_library`, and for voice recognition `voiceprints(meeting_id, data)` and
`voice_model(id, data)` (single row id=1). A trigger deletes a meeting's voiceprints when the
meeting row is deleted, so a library edited by an older build cannot keep voices for a meeting
that no longer exists.

Each meeting is one JSON document. Fields added after a record was written default on
read. Audio is `data/audio/<meeting-id>` and optional screen video is
`data/video/<meeting-id>`, both without an extension; `MediaFile` resolves them through
symlinks in `data/media/` because AVFoundation selects its demuxer from the path
extension. Retired speech models migrate to MOSS and retired summary providers to Codex or
Claude Code, dropping obsolete API credentials, without touching saved meetings.

```
Meeting = {id,title,created_at,updated_at,duration,status:'ready'|'transcribing'|'transcribed'|'summarizing'|'complete'|'error',
  progress,stage,error,audio_name,audio_url,video_url,language,speaker_count,
  speakers:Record<string,string>,speaker_profiles:Record<string,string>,auto_speaker_profiles:Record<string,number>,
  segments:Segment[],summary:Summary|null,notes,context_links:ContextLink[],
  cleanup:{original_duration,head,tail,applied_at}|null,recorded_at?,source?:'recording'|'import',automatic_title,title_ownership_version,
  starred?,category_id?}
Category = {id,name,color:'blue'|'purple'|'pink'|'orange'|'green'|'teal'|'yellow'|'red'|'gray',position}
Segment = {id,start,end,speaker,text}
Summary = {overview,key_points[],decisions[],action_items:[{text,owner,due,completed?}],provider,model,generated_at}
ContextLink = {url,title}
```

`completed` is set when an action item is checked off on the Summary page; items without it are
open. Checking one off is a plain edit, so the summary stays current.

`starred` and `category_id` drive the sidebar's Starred list and categories. Documents without
them read as unstarred and uncategorized. Deleting a category clears `category_id` from its
meetings in the same transaction, and split parts keep both fields. `position` is the manual sidebar
order; the Name and Meeting Count sorts are a per-user view preference, not stored in the library.
An older build drops both meeting fields when it re-saves a meeting.

`created_at` is when the meeting was saved, which for a recording is after it ended.
`recorded_at` is when a recording's kept audio began: the capture start written to the
session's `session.json`, plus any silence trimmed from the head. Imports and older
recordings don't have it. `source` records whether the audio was recorded or imported. Documents
written before it was added don't have it.

`automatic_title` is true for titles Stillnote chose: a recording's `Meeting · <date>` placeholder,
an imported file's name when the title field was left blank, and titles from **Name Meeting** or
**Stop, Transcribe & Summarize**.
Older documents without the field infer it when the title matches the original filename or
the dated recording placeholder; other titles default to false. Older imports and re-saved
recording placeholders also stored false without a user choice, so records without
`title_ownership_version` infer ownership for those defaults even with false. New writes
include `title_ownership_version: 1`, so all explicit title choices then survive reopening.
Old meetings named or renamed back to their exact default cannot be distinguished from untouched
defaults. Editing a meeting in an older build removes the marker, so this inference applies again
if that library is then reopened in a current build.
Renaming the meeting clears the flag. Summaries never change the title, and summaries written by
0.8.0 may still carry an unused `title` key.

**Name Meeting** and **Stop, Transcribe & Summarize** are the only ways Stillnote changes an
existing title; the latter keeps a split part's ` partN` suffix. `MeetingNamer` sends one
request to the summary provider, separately from summaries, with a fixed prompt that the summary
prompt in Settings doesn't affect, at low effort. It sends the meeting's summary (overview, key
points, and decisions) when there is one, and otherwise the transcript's first 60 KB. The reply
replaces the title and sets `automatic_title`. Like a summary, it starts without a confirmation
sheet: choosing the provider in Settings is the consent.
Settings that still hold the 0.8.0 default summary prompt, which asked for a title, move to the
current default.

## Concurrency

`AppModel` is `@MainActor @Observable` and is the only source of truth for the interface;
there is no polling. `Store` is an actor, and every mutation is a read-modify-write inside
it, so a background job's progress write cannot clobber a concurrent user edit. `JobQueue`
serializes local heavy work — transcription, voice recognition, and model downloads — so it
never competes for memory or the GPU; a job cancelled while still queued observes cancellation
and returns. Agent jobs (summaries and Name Meeting) only wait on the provider's CLI, so they
run on `AgentJobLimiter` instead: up to `summary.concurrency` at once (default 3, 1–8, set under
Settings → Summary), in arrival order, and never behind a transcription. A meeting still shows
`summarizing` while its summary waits for a slot. Jobs left running when the app quits are
marked retryable on the next launch.

Overlapping recording stops share one save task, claimed before any suspension, so only
one operation can move the media and insert the meeting. Save/discard controls stay disabled
through cleanup and persistence; a discard already waiting on a save cannot delete that
meeting or the next recovered session. Transcription requests reserve their meeting before
awaiting the store so concurrent stop callers queue only one job.

The recording page and the menu bar offer two ways to stop: **Stop Recording** saves only,
and **Stop, Transcribe & Summarize** runs `AppModel.processRecording`. A saved recording that
`RecordingSplit.eligible` accepts is split first, without the confirmation sheet; a split that
fails or is refused leaves the recording whole and processes it as is. Each resulting meeting is
marked for a summary and naming before its transcription is queued. The transcription job takes both marks when it starts, whatever its
outcome. A saved transcript then runs opt-in auto-tagging and the summary in that order, outside
the transcription's own job, because auto-tagging waits on the queue. A saved summary then starts naming
in its own task. A run that is stopped, fails, or finds no speech drops the summary and the
naming, and a failed summary drops the naming, so later manual work never triggers either on
its own.

## Capture

`CaptureSession` uses ScreenCaptureKit for the selected microphone, optional system audio,
and opt-in screen video, all on one serial callback queue. Both audio sources are
normalized to mono 48 kHz PCM and written to seekable WAVs whose headers are rewritten
after every buffer, so audio survives a crash. A pause-adjusted host clock places every
sample, so removed pauses stay aligned across sources and sparse gaps read as silence.
Levels are reported every 200 ms. Capture stops if microphone callbacks cease for eight
seconds or after 90 minutes of recorded time.

Finishing trims silence before anything else reads the mix, because screen video takes its
audio from that file and cutting afterwards would leave the two tracks a silence apart. The
detector locates speech, and leading and trailing non-speech is removed from the saved
recording — the case where a recording kept running after the meeting ended. The policy
refuses to cut unless sustained speech was found, at least a minute would be removed, and ten
seconds would remain; a stray keystroke cannot move the boundaries, and a recording the
detector does not understand is kept whole. Sessions with screen video lose only their tail,
since a compressed video passthrough cannot begin mid-GOP. What was removed is recorded on the
meeting as `cleanup`, which is the only surviving record: the per-source captures are deleted
when a session is saved, so a trim cannot be undone. A failure here never fails a save.

Screen video is fragmented H.264 MP4 at up to 1920 pixels wide and 15 fps with frame
reordering disabled, so pause/resume timestamps remain safe to finalize. Audio-only
sessions attach no screen output and write no images. Finishing mixes the sources in
one-second blocks at equal gain — never loading a meeting into memory — then copies the
compressed video and interleaves the mixed audio as AAC. Speech inference reads only the
mixed WAV; video is never supplied to transcription or summaries. Unsaved sessions live in
`data/recordings/<id>/` and are offered for save or discard after an interrupted run.
Capture permissions are requested only when a recording is started.

## Speech

The app decodes the recording to 16 kHz mono float32 with external media references
forbidden. Before inference it silences every region the detector found no speech in and
removes a silent head and tail, writing a separate copy so the stored recording and its
playback keep whatever was captured. Speech samples pass through unaltered: filtering speech
before recognition costs accuracy, so only audio with no speech in it is touched, with a 10 ms
fade at each boundary so the gate cannot introduce a click. Timestamps come back relative to
the audio the model saw and are shifted by the removed head, then clamped to the stored
recording, so the player stays in sync. The pass is skipped — never fatal — when the detector
is unavailable or fails.

Silence detection is `StillnoteSpeechWorker vad <pcm> <vad-model-dir> [<threshold>]`, which
emits one `ranges` event. It is Silero VAD through `MLXAudioVAD`, fed 512 samples at a time
with the LSTM state carried across about 30-second reads, so a 90-minute meeting is never
resident in memory. It runs in the worker because that is what keeps MLX and Metal out of the
app process; it deliberately does not go through `JobQueue`, because saving a recording must
not wait behind an unrelated transcription and a 2 MB detector is not the contention that
queue exists to prevent.

Inference then runs the bundled `StillnoteSpeechWorker <pcm> <model-dir> <language>
<speaker-count> [<hot-words-json> [<mode>]]`. The model loader accepts a verified local directory;
no inference downloads or external executable dependencies are used. The worker emits
`STILLNOTE_EVENT {json}` lines for progress, the raw transcript, or an actionable error;
anything else on the pipe is ignored and never becomes meeting content. Cancellation
terminates the process and escalates to `SIGKILL` after two seconds, then restores the
meeting's previous transcript and summary.

Parsing lives in Swift so the transcript format is defined in one place: MOSS's
`[start][S01]text[end]` output becomes stable `speaker_n` ids with display names, with
timestamps clamped to the recording. Output that does not fully match the grammar is a
truncated generation and is rejected rather than saved. Transcript or speaker edits
invalidate the previous summary; a failed retranscription preserves existing corrections.

Voice embedding is `StillnoteSpeechWorker embed <pcm> <model-dir> <windows-json>`. The JSON is
an array of `{speaker,start,spans}` windows planned in Core; each is ten seconds of audio from
`start` on the stored recording's timeline, with `spans` marking where that speaker talks. The
worker runs pyannote community-1's WeSpeaker ResNet34 as two compiled Core ML models, `FBank` on
the CPU and `Embedding` on all compute units, in batches of up to 16 windows, turning `spans`
into the model's 589-frame mask. It emits progress and one `embeddings` event holding a
unit-length 256-dimensional vector per window, which the app rejects unless every vector is
complete and finite. Core ML is a system framework, so the worker gains no dependency.

Model setup is an explicit action that downloads public files only, verifying each file's
size and SHA-256 before an atomic rename, and recording the publisher revision in
`.verified`. Inference requires complete local files. Setup installs the engine and the
silence detector together; a manifest entry declares its `kind`, so a supporting model can
never be selected as a transcription engine, and its `directory`, so MOSS keeps the install
path it has always used. The detector is not part of `ready`: an install that predates it
keeps transcribing, with cleanup skipped until it is downloaded. The voice model (`kind:
"speaker"`, about 15 MB) is not part of setup at all; Learn Voices downloads it the first time.
Its compiled Core ML bundles are directories, so manifest file names may be nested; the installer
creates their folders and refuses any name that is absolute or contains an empty, `.` or `..`
component.

## Summaries

A summary is one request to the user's own CLI, run as if typed in their terminal:
`codex exec --skip-git-repo-check --output-schema … -` or `claude -p --output-format json
--json-schema …`, with the configured model and effort. The prompt and the whole
speaker-labeled transcript travel on stdin from a private temporary directory, with the
environment of the user's interactive login shell and a ten-minute deadline that kills the
whole process group. The CLI's own config applies unchanged — sign-in, skills, MCP servers,
instructions files, and permissions — so the agent can do whatever that config allows, and
the transcript is untrusted input to it. The CLI enforces the JSON schema; Stillnote still
validates the result. The meeting's notes and context links follow the transcript as the user's
own context, with a request to look the links up with the agent's skills. Consent is a
precondition checked before any process starts.

For meetings with screen video, summaries always include the local screen-video path
resolved from the app's own video store as JSON-encoded text. Stillnote sends no video
bytes itself; the agent can use the path according to its own configuration and permissions.
The retired `summary_include_video_path` field is ignored when reading older meetings.

## Launch

Nothing in `App.init()` touches the filesystem. The window appears first, then `load()`
resolves paths, adopts a development checkout's data on first launch, opens the store, and
probes the model, MOSS runtime, agent CLIs, and capture devices — the last four off the
main actor. Until that finishes the window shows a progress view, so a slow or blocked
read degrades into a visible wait rather than an app that never draws.

## Command interface

`stillnote` ships inside the bundle at `Contents/Helpers/stillnote` — not `Contents/MacOS`, where
a case-insensitive volume would make `stillnote` and `Stillnote` the same file and the CLI would
overwrite the app. The Homebrew cask links it onto `PATH`. It reads the app's version from the
bundle's `Info.plist` relative to its own path, since `Bundle.main` is not the app from `Helpers`.

The running app is the only writer and the only process that can record. Both follow from the
existing design rather than preference: `Store.update` is a read-modify-write over a whole meeting
document, so a second writer would silently drop concurrent edits, and `AppModel.meetings` is the
interface's only source of truth with no file watcher, so an external write would stay invisible
until relaunch. Capture is harder still — TCC grants belong to the signed bundle, device discovery
needs the window server, and `RecordingCoordinator` is `@MainActor` with a single-session
invariant — so a CLI launched from a terminal inherits the terminal's permissions, not Stillnote's.

`CommandServer` therefore binds `<data>/cli.sock` once `load()` has a store and a recorder, and
dispatches through `AppModel`, so a correction typed in a terminal appears in the open window.
Requests are one newline-delimited JSON object each way. A socket is a filesystem object, not a
network port: the directory is already `0700` and the socket is `0600`, so only this macOS user can
reach it. `AppSettings.cli.enabled` (Settings → Advanced) refuses every command when off, because
the surface can switch on a microphone. Binding is exclusive, so a second instance finds the
library already served and leaves it alone; a socket file left by a crash or a quit is reclaimed
only after a connection proves nothing is listening.

Commands that only read are implemented once, in `CommandRunner`, against `Store`. The app answers
them from its live store, and the CLI answers them itself — through `Store(readOnly:)`, which
creates nothing and rejects writes — when the app is closed. Write and record commands then report
that the app must be open rather than opening a second writer. The CLI resolves paths with
`Paths.resolve`, never `Paths.standard`, which can adopt a development checkout's data.

Transcript replacement, search, date ranges, and meeting references live in Core so they are
covered by tests, which can reach neither the app nor the CLI target. The policy that a transcript
correction invalidates the summary drawn from it is `TranscriptEdit.finish`, called by both the
window's segment editor and the CLI, so the two cannot diverge. `summarize`, `name`, and
`process` require `--allow-remote`. The window treats the provider chosen in Settings as consent,
but a command may come from an agent, so it must consent on each request.

`process` is Stop, Transcribe & Summarize for meetings already saved. `ProcessPlan` (Core) picks
the meetings and where each resumes — `transcribe` with no transcript, `summarize` with one —
and `CommandServer` carries the plan out through `AppModel.processRecording` or
`AppModel.summarize(thenNameWithSuffix:)`, so splitting, auto-tagging, and naming are the
window's own. It returns once everything is queued; the job queue then transcribes one meeting
at a time, and each summary and title starts as soon as an agent slot is free. `name` calls `AppModel.nameMeeting`, which throws the failure `suggestTitle` would show
in the window's alert.

`skills/stillnote` publishes this as an agent skill. `scripts/check-skill.sh`, run by
`scripts/check.sh`, validates its frontmatter and proves the commands and long options it documents
match the catalog in both directions.

## Interface

The meeting pages follow the UI refresh design: its colors, glass controls, and SVG icons for
light and dark appearances live in `Views/DesignStyle.swift` (`DS`, `Icon`), and Reduce
Transparency swaps the glass for opaque fills. Settings keep stock controls. `NavigationSplitView`
hosts the sidebar; its detail column holds the 300-point meeting list beside the open meeting, or
the calendar in place of both. The window has no visible toolbar; each page draws its own controls
in the design's top row.

The meeting list groups meetings as Mail does (Today, Yesterday, Previous 7 and 30 Days, then
months and years) and shows each one's time, length, people, and a `snippet`: the summary
overview, or the first transcript line. Swiping a row right stars it and left deletes it, by
two-finger trackpad swipe or by dragging; a short swipe reveals the action and a long one performs
it. Deletions are held while their toast offers Undo (`Feedback`), then carried out. **New
Meeting** starts a recording with the saved defaults; ⌘R opens the recording options first.
Recordings show in the window as their own page, from whichever entry point started them.

A meeting opens on its Summary page when it has one, and otherwise on its Transcript. The
transcript reads like lyrics: the focused line is large in the middle and fills in as it plays,
with the lines around it fading. Focus follows playback; scrolling browses lines without seeking,
and choosing a line plays from it. The dock below has 15-second skips and a timeline drawn from
the transcript's speech. Header portraits open **Assign Speaker** for a whole voice; the focused
line's speaker chip opens it for that line alone, which moves the line to the voice linked to the
chosen person (or a new voice) and, like any transcript correction, clears the summary. Both show
a toast with Undo. The Summary page holds the overview, key points, decisions, action items,
links, and notes.

The calendar (`MeetingCalendarView`) has Day, Week, and Month ranges, with events tinted by
category. Each
meeting appears at `Meeting.startDate`, which is `recorded_at` when it's set. An older recording
is estimated as its save time minus its kept duration and any trimmed tail. An import stays at
the time it was imported. Records older than `source` with the audio name `recording.wav` are
treated as recordings, which includes the rare older import of a file with that name. The week
grid spans 7 AM to 9 PM, widened to fit any meeting shown, and a meeting's block is as tall as its
duration, with a 26-minute minimum so its title fits. Positions are local clock times rather than
time elapsed since midnight, so a meeting on a daylight-saving changeover day still lines up with
its hour label. Overlapping meetings share a column. The date math and the overlap columns are
in `StillnoteCore/Models/CalendarLayout.swift`. The chosen range and date are kept per
window in scene storage. Recordings with screen video open AVKit's `VideoPlayer` in a sheet that
shares the dock's player. Settings live in the
standard Settings scene. The main window is a single `Window` scene; a `MenuBarExtra` starts a
recording with the saved transcription defaults, stops it with the same two actions as the
recording page, shows the elapsed time while capturing,
and opens the window or Settings, which keeps the app running after the window closes. Notes autosave after a 700 ms pause, with an unsaved draft kept in
`UserDefaults` until it matches what was saved.

### Meeting reminders

`AppSettings.meeting_reminders` (`{enabled}`) is opt-in: new installs and older
settings records decode with `enabled` false. While it is false, `MeetingReminder` doesn't start
the monitor, so nothing observes microphone use.

`MicrophoneActivityMonitor` (Core) reads Core Audio's process objects: each process's
`IsRunningInput`, PID, and bundle ID. It never reads audio and needs no TCC grant. Core Audio
does not notify when a process's input flag changes, so the monitor listens for:

- `DeviceIsRunningSomewhere` on every device
- the process and device lists changing

It rereads the process list when one of these fires, and once more 750 ms later, since a process's
flag can trail its device starting. `MeetingApps` maps bundle IDs, including nested helper IDs, to
a fixed set of meeting apps and browsers. Stillnote's own process is excluded.

`MeetingReminderPolicy` is a clock-free value that sets the timing rules, and it is unit-tested.
An app must hold the microphone for 2 s before a reminder shows. Each microphone session reminds
once, and a session ends only after 60 s off the microphone. A reminder is withdrawn when:

- its app releases the microphone
- a recording starts from any path
- reminders are turned off
- the user closes it, which also counts as the reminder for that session
- 60 s pass without an answer

`MeetingReminder` wakes at the policy's next deadline instead of ticking. The reminder is a
non-activating `NSPanel` at the top right of the menu-bar screen, so answering it leaves the
meeting app frontmost. Its Start Recording action is `AppModel.startQuickRecording`, which is the
menu bar's path.

Menu bar actions never activate the app or open a window, except **Open Stillnote** and
**Settings…**. Starting, pausing, and stopping a recording from the menu bar or the reminder leave
Stillnote hidden. A failure sets `AppModel.alertMessage`, which the menu shows as a line of text
and the menu bar icon as a warning symbol until the main window's alert is dismissed.

### Reusable speaker profiles

Speaker profiles are local JSON records in SQLite’s `speaker_profiles` table, keyed by UUID. Each stores a name and one optional email and phone number. Meetings map local diarization labels to profile IDs through `speaker_profiles`; older meeting documents default to an empty mapping. Diarization labels do not imply identity across recordings: a link is made by hand, or by voice recognition (below) when its match is confident.

Meeting `speakers` values remain name snapshots used by transcripts, summaries, and exports. Profile edits affect future assignments, while shared contact details stay solely in the profile store and are excluded from summary prompts and exports. Assignments that change a displayed name invalidate that meeting’s summary. Local renaming unlinks the identity; unlinking alone retains the snapshot. Retranscription clears assignments on successful transcript replacement, and deleting a meeting retains profiles. Creation with initial assignment uses a SQLite transaction. Store operations reject assignments to processing meetings.

The `stillnote speaker` commands cover the same ground from a terminal: `list`, `show`, and `voices` read the library directly (so they work with the app closed), while `add`, `update`, `delete`, `assign`, `learn`, and `autotag` go through `AppModel` like every other change. `speaker add` refuses a duplicate name so a name stays a usable `<profile>` reference.

The transcript’s speaker sheet provides a profile dropdown and assignment/unlink actions. Edit Profile opens Settings → Speakers with the selected profile. Settings uses a macOS list with plus/minus controls and inline detail fields; there is no separate profile-editing sheet. A transactional, one-time migration converts existing custom speaker names into distinct profiles without merging matching names or changing meeting snapshots or summaries. Generic diarization labels are excluded. Contact fields are trimmed; nonempty emails receive basic format validation, while phone formatting is preserved. Failed saves remain visible in the editor.

### Voice recognition

**Learn Voices** (Settings → Speakers, or `stillnote speaker learn`) reads a voiceprint for every
diarized label in each meeting that has at least one manual profile link, then calibrates the
matching rule against those links. Nothing is trained; a pretrained speaker-embedding model turns
speech into vectors and the rule decides how close is close enough.

- **Windows.** `VoiceWindowPlanner` takes each label's segments, removes speech that overlaps
  another label (including `speaker_unknown`, which is never itself recognized), trims 0.1 s
  from each edge because MOSS timestamps are sentence-level, and drops spans under 0.5 s. It
  packs the rest into ten-second windows, keeps windows with at least 2 s of the speaker, and
  spreads at most 24 per label across the meeting. A window that would pass the end of the
  recording moves back inside it so the model never sees padding. A label with under 3 s of
  clean speech is `too_short`.
- **Voiceprints.** A label's voiceprint is the speech-weighted mean of its window embeddings,
  normalized. A meeting's voiceprints are stored as one `voiceprints` row with a fingerprint of
  every segment's timing and label, the duration and the model revision. Text edits leave the
  fingerprint alone; retranscription, splits and speaker or timing edits make the row stale, and
  a stale row is recomputed before use. Saving a row whose fingerprint no longer matches the
  meeting is refused.
- **Samples.** Only labels linked by hand train. A link made by voice is recorded in
  `auto_speaker_profiles` with its score and is excluded until the user assigns or unlinks that
  label, so a wrong match cannot teach the next one.
- **Scoring.** `centroid` compares a voiceprint with the normalized mean of a profile's samples;
  `nearest` averages its three most similar samples. A label is assigned when its best score
  reaches the threshold and leads the runner-up by the margin; otherwise it is `uncertain` or
  `unrecognized`. Several labels may map to one profile, because MOSS sometimes splits a person.
- **Calibration.** Every tagged meeting is scored against profiles built from all the others.
  Labels of profiles that appear in no other meeting act as strangers, where abstaining is the
  right answer. Over both scorers and a grid of thresholds and margins, the rule that tags the
  most labels while staying at 97% precision wins, or the best F1 when none reaches it. With no
  repeat speakers, a fixed conservative rule applies. The result and its precision and coverage
  are the `voice_model` row. On a library of 338 tagged voices in 83 meetings, the chosen rule
  was right 97.2% of the time and tagged 85% of recognizable speakers.

**Auto-Tag** (the transcript tab, Settings → Speakers for every meeting, `stillnote speaker
autotag`, or opt-in after each transcription with `speaker_recognition.auto_tag_after_transcription`)
matches only labels that have no profile and applies the confident ones with
`Store.applyVoiceMatches`: one write that refuses a busy meeting or one whose transcript changed
since its voices were read, never replaces an existing link, and clears the summary when a
displayed name changes, as a manual assignment does. Every model run is one meeting on
`JobQueue`, so a transcription started meanwhile waits for at most one meeting. A library-wide
run reports every meeting it had to skip and why, such as missing audio without current
voiceprints; it never drops one silently. Auto-tagging leaves the meeting's status alone, like
naming. **Forget Voices** deletes every voiceprint and the
learned rule, and keeps profile links.

### Hot-word settings and worker protocol

The per-user settings document stores `transcription.hot_words` as a string array;
missing values default to an empty list. Jobs capture the saved list when queued.
The worker accepts `<pcm> <model-dir> <language> <speaker-count> [<hot-words-json> [<mode>]]`.
The optional argument is a JSON string array passed directly through `Process`
(no shell); empty lists use the original four-argument protocol. The worker validates
and appends nonempty lists to the existing diarized transcription prompt using
MOSS's `热词提示：` format. No transcript replacement or meeting-specific list is used.
The app bundles and signs the worker with `mlx.metallib` beside it. The vendored package
revision and patches are recorded in `Vendor/MossTranscribeDiarize/UPSTREAM.md`.
The converted 8-bit checkpoint uses `speech/moss-0.9b-mlx-8bit`; the old model directory
is retained but never mistaken for a compatible native checkpoint.

### Splitting long recordings

`AppSettings.split_threshold_minutes` defaults to 50 and accepts any positive whole number of minutes.
The threshold is edited directly in a text field; invalid input keeps the last saved
value. The detail header offers **Split Recording** for saved audio-only meetings at or
above that threshold. While that action is visible, the trim badge is hidden to avoid
competing for header space; stored cleanup metadata is preserved. Screen recordings
are excluded. A confirmation sheet previews
names and durations and explicitly warns that splitting replaces the original meeting
and audio and clears its summary. Each part is 1,200 seconds except the remainder.
Splitting also supports saved imports longer than the speech engine’s 90-minute limit;
that limit applies to transcription, not to the source being split.

`RecordingSplit` plans independent meetings named `<original title> partN`, reserving
space for the suffix within the title limit. It streams decoded audio to float32 WAVs
at the source sample rate/channel count. No speech or summary provider runs. Each
transcript sentence belongs to the part containing its midpoint (an exact boundary
belongs to the later part); text stays whole, timestamps become local and are clipped
to that part. Thus a boundary-spanning sentence can include words audible in the
adjacent part. Notes, links, speaker snapshots and profile associations are copied.
Summaries, stale task errors and cleanup metadata are cleared. Recording dates advance
by each part's offset; imports retain their import date.

AppModel reserves splitting before its first suspension and flushes pending notes.
Conflicting UI and command writes are refused during the operation. Store compares
the original snapshot and inserts every part/removes the original in one SQLite
transaction, only after all audio files exist. Filesystem changes use a durable journal
under `data/splits/`: before commit, recovery removes partial outputs and retains the
original; after commit, it removes the retired original. Failed cleanup leaves the
journal for a later launch. A failed export/transaction never deletes the original.

### Library loading and search

The meeting list and the calendar cover the whole library. `AppModel.meetings` contains `MeetingListItem` metadata, not full
`Meeting` documents. Only the selected detail is retained; jobs hold their own snapshots
for their lifetimes. Selection requests are cancellable, revisions reject stale reads,
and returning to All Meetings releases the selected transcript, summary and notes.
Ordinary metadata updates replace one row without sorting the entire library.

`meeting_library` is a derived SQLite table containing a body-free JSON projection with the
list's `snippet` (at most 160 characters),
a row revision, a search-content revision and a cached search document. The original
`meetings(id,data)` schema and JSON format stay authoritative and unchanged. A transaction
creates and backfills the derived table on first writable open. SQLite triggers maintain
metadata and invalidate search text, including when an older app writes a meeting. A library
indexed before snippets existed gets the current triggers and its snippets on its next writable
open, in one transaction that leaves row revisions alone.
Insert/update savepoints rebuild invalidated search text in the same commit; profile
and recording-split transactions include those changes and roll them back together.
Legacy cache rebuilds and speaker migration process one meeting at a time. Read-only
CLI opens never migrate or write a database.

Search documents contain only the title and transcript joined with spaces, lowercased
and normalized to Unicode NFC. A 200 ms input debounce starts a cancellable scan on a
separate read-only Store connection, leaving the writer and detail navigation available.
SQLite `instr` filters candidates before Foundation verifies canonical substring
semantics. Results contain IDs and render the latest metadata. Query/content revisions
reject obsolete results; progress, notes and speaker-label-only changes do not restart
search. A legacy writer's invalidated cache falls back to that single meeting's text until
rebuilt. Clearing the query immediately restores the library; failures have a retry state.

CLI writes resolve their target from metadata and read the full meeting explicitly, so
commands work even when its detail has never been opened. Existing full-document CLI
read/bulk operations retain their contracts and can transiently load multiple meetings;
they do not populate the UI's detail cache. The index remains in the same private database
and adds disk space, not a resident full-library text cache. See
[measurements and verification](LIBRARY-PERFORMANCE.md).
