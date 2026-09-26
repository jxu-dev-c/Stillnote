# Stillnote implementation contract

A native macOS 15+ app for Apple silicon: SwiftUI interface, SwiftPM package with a pinned native MLX dependency. Capture, storage, decoding, summaries, and exports are Swift and run
in process. MOSS 0.9B inference runs in a short-lived bundled Swift worker using the vendored MOSS package. Nothing listens on
a network port. No recording or transcription leaves the computer. Summaries can send
transcript text to a provider only after per-request consent.

## Layout

```
Stillnote.app
├── StillnoteCore   library target, no SwiftUI, fully unit-tested
└── Stillnote       executable target: SwiftUI views + AppModel
Sources/StillnoteSpeechWorker  bundled native MLX executable; models download separately
```

| Module | Responsibility |
| --- | --- |
| `Sources/StillnoteCore/Models/` | `Meeting`, `Segment`, `MeetingSummary`, `ContextLink`, `AppSettings`, input bounds, formatting. |
| `Sources/StillnoteCore/Store/` | `Paths` (Application Support layout, checkout adoption) and the `Store` actor over SQLite. |
| `Sources/StillnoteCore/Capture/` | ScreenCaptureKit session, device and permission discovery, session persistence and recovery. |
| `Sources/StillnoteCore/Audio/` | Decoding to 16 kHz mono, bounded-memory mixing, silence trimming and non-speech suppression, MP4 muxing, extension resolution for stored media. |
| `Sources/StillnoteCore/Speech/` | Model manifest, verified download, readiness, MOSS and silence-detection worker drivers, transcript parsing. |
| `Sources/StillnoteCore/Summary/` | Headless Codex/Claude Code adapters over `posix_spawn`, chunking, validation, local merging. |
| `Sources/StillnoteCore/Export/` | Markdown, plain text, SRT, and JSON exports. |
| `Sources/Stillnote/` | `AppModel` (observable state, job orchestration) and the SwiftUI screens. |

## Data

`~/Library/Application Support/Stillnote/data/stillnote.sqlite3` keeps the schema the
previous localhost version wrote, so an existing database opens unchanged:

```sql
CREATE TABLE meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL);  -- single row id=1
```

Each meeting is one JSON document. Fields added after a record was written default on
read. Audio is `data/audio/<meeting-id>` and optional screen video is
`data/video/<meeting-id>`, both without an extension; `MediaFile` resolves them through
symlinks in `data/media/` because AVFoundation selects its demuxer from the path
extension. Retired speech models migrate to MOSS and retired summary providers to Codex or
Claude Code, dropping obsolete API credentials, without touching saved meetings.

```
Meeting = {id,title,created_at,updated_at,duration,status:'ready'|'transcribing'|'transcribed'|'summarizing'|'complete'|'error',
  progress,stage,error,audio_name,audio_url,video_url,summary_include_video_path,language,speaker_count,
  speakers:Record<string,string>,segments:Segment[],summary:Summary|null,notes,context_links:ContextLink[],
  cleanup:{original_duration,head,tail,applied_at}|null}
Segment = {id,start,end,speaker,text}
Summary = {overview,key_points[],decisions[],action_items:[{text,owner,due}],provider,model,generated_at}
ContextLink = {url,title}
```

## Concurrency

`AppModel` is `@MainActor @Observable` and is the only source of truth for the interface;
there is no polling. `Store` is an actor, and every mutation is a read-modify-write inside
it, so a background job's progress write cannot clobber a concurrent user edit. `JobQueue`
serializes transcription, summaries, and model downloads so they never compete for memory
or the GPU; a job cancelled while still queued observes cancellation and returns. Jobs left
running when the app quits are marked retryable on the next launch.

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

Model setup is an explicit action that downloads public files only, verifying each file's
size and SHA-256 before an atomic rename, and recording the publisher revision in
`.verified`. Inference requires complete local files. Setup installs the engine and the
silence detector together; a manifest entry declares its `kind`, so a supporting model can
never be selected as a transcription engine, and its `directory`, so MOSS keeps the install
path it has always used. The detector is not part of `ready`: an install that predates it
keeps transcribing, with cleanup skipped until it is downloaded.

## Summaries

Agents receive only speaker-labeled transcript text on stdin, in their own session and a
private temporary directory, with a five-minute deadline that kills the whole process
group. Codex runs read-only with shell and web search disabled and user config ignored;
Claude Code disables tools, MCP servers, slash commands, and hooks. Both use ephemeral
sessions and schema-constrained JSON with independent output validation. Long transcripts
are summarized in sections and merged locally, so decisions late in a long meeting survive
without extra requests. Consent is a precondition checked before any process starts.

A meeting's `summary_include_video_path` preference adds its local screen-video path to
each section as JSON-encoded text metadata. It defaults to false for new and legacy
meetings, the path is resolved from the app's own video store, and file-reading tools stay
disabled, so no video content is sent. Changing it affects future summaries and preserves
any existing one.

## Launch

Nothing in `App.init()` touches the filesystem. The window appears first, then `load()`
resolves paths, adopts a development checkout's data on first launch, opens the store, and
probes the model, MOSS runtime, agent CLIs, and capture devices — the last four off the
main actor. Until that finishes the window shows a progress view, so a slow or blocked
read degrades into a visible wait rather than an app that never draws.

## Interface

The interface is built from stock SwiftUI and AppKit controls with system semantic colors
and SF Symbols, so it follows the viewer's appearance, accent color, and contrast settings
rather than carrying its own palette. `NavigationSplitView` hosts the sidebar and either
the meeting `Table` or a meeting's detail view; playback uses AVKit's `VideoPlayer` for
recordings with screen video and a compact transport otherwise. Settings live in the
standard Settings scene. Notes autosave after a 700 ms pause, with an unsaved draft kept in
`UserDefaults` until it matches what was saved.

### Reusable speaker profiles

Speaker profiles are local JSON records in SQLite’s `speaker_profiles` table, keyed by UUID. Each stores a name and one optional email and phone number. Meetings map local diarization labels to profile IDs through `speaker_profiles`; older meeting documents default to an empty mapping. Assignment is manual; diarization labels do not imply identity across recordings.

Meeting `speakers` values remain name snapshots used by transcripts, summaries, and exports. Profile edits affect future assignments, while shared contact details stay solely in the profile store and are excluded from summary prompts and exports. Assignments that change a displayed name invalidate that meeting’s summary. Local renaming unlinks the identity; unlinking alone retains the snapshot. Retranscription clears assignments on successful transcript replacement, and deleting a meeting retains profiles. Creation with initial assignment uses a SQLite transaction. Store operations reject assignments to processing meetings.

The transcript’s speaker sheet provides a profile dropdown and assignment/unlink actions. Edit Profile opens Settings → Speakers with the selected profile. Settings uses a macOS list with plus/minus controls and inline detail fields; there is no separate profile-editing sheet. A transactional, one-time migration converts existing custom speaker names into distinct profiles without merging matching names or changing meeting snapshots or summaries. Generic diarization labels are excluded. Contact fields are trimmed; nonempty emails receive basic format validation, while phone formatting is preserved. Failed saves remain visible in the editor.

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
