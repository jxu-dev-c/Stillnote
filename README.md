# Stillnote

A private meeting notebook that runs on your own Mac. Record your microphone and system
audio with optional screen video, import a recording, distinguish speakers, edit the
transcript, and turn the conversation into useful notes.

Stillnote is a native macOS app. **Audio recording, speech recognition, and speaker
diarization run locally.** Optional summaries run through your installed Codex or Claude
Code CLI, which may send transcript text to hosted models after you confirm that choice
for the meeting.

## Requirements

macOS 15 or newer on Apple silicon, with Xcode or the Xcode Command Line Tools installed.
Python 3.11–3.13 is needed once, to create the MOSS inference runtime.

## Run

```bash
./scripts/setup.sh    # creates the MOSS runtime and builds Stillnote.app
./scripts/start.sh    # opens build/Stillnote.app
```

In Settings (⌘,), download the local speech model once; MOSS 0.9B is about 1.8 GB. The
app then records and transcribes without an internet connection. Model setup is separate
from transcription and never uploads meeting content.

The first launch adopts an existing `data/` and `models/` directory from this checkout
and moves them to `~/Library/Application Support/Stillnote/`.

`Stillnote.app --diagnose` prints where the app resolved its data, models, MOSS runtime,
and agent CLIs, and whether capture is available. It is the fastest way to check an
install without opening the window.

## Use

1. **Record a meeting** (⌘R): select a microphone, optionally include system audio and
   screen video, then start and grant the macOS capture permissions. Separate meters show
   microphone and system audio. Pause and resume as needed, then finish to save and
   transcribe. If the model is not installed yet, recordings are saved for later.
2. **Import audio** (⌘O): choose or drop a WAV, MP3, M4A, AAC, FLAC, AIFF, MP4, or MOV
   file, up to 2 GB.
3. **Review speakers**: automatic diarization assigns anonymous speaker labels. Provide an
   expected speaker count when you know it; rename speakers and correct text or speaker
   assignments in the transcript. Click a timestamp to listen to that point.
4. **Generate a summary**: get an overview, key points, decisions, and action items.
   Choose a summary agent in Settings. Each recording's Summary tab has a **Send video
   path to AI** toggle, off by default, available when screen video is saved. Remote
   providers require a sharing confirmation each time you generate a summary.
5. **Keep context or export**: use **Context** to add background notes and website links
   with optional labels. Notes save as you type. Context and links are included in
   Markdown, plain text, and JSON exports; SRT contains subtitles only. Deleting a meeting
   removes its database record, original audio, and any screen video.

Leave a link's label blank to use its page title. Stillnote briefly fetches the public
page without cookies; if a title cannot be retrieved, the website's host remains the
label. Link icons load directly from each website's `/favicon.ico` with no referrer and no
third-party icon service. Linked pages are not included in summaries.

Recordings write audio to disk while capturing. After an interrupted run, **New
recording** offers to save the recovered audio or discard the session. Recordings stop at
90 minutes.

### Capturing an online meeting

Enable **Include system audio** to capture remote participants from desktop apps such as
Teams or Zoom. Enable **Record screen video** only when you want to save a selected
display; screen images are never written in audio-only mode. macOS requires Microphone and
Screen & System Audio Recording permission for Stillnote; ScreenCaptureKit needs screen
recording access even for its microphone stream. Use headphones to reduce microphone echo —
there is no acoustic echo cancellation.

### Speech model

Stillnote uses **MOSS 0.9B**
([OpenMOSS-Team/MOSS-Transcribe-Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize),
~1.8 GB) for local transcription and speaker attribution. It supports 50+ languages;
language and speaker-count selections are prompt hints, not enforced constraints.

MOSS inference is the only part of Stillnote that is not Swift. The `mlx-audio` runtime
that loads this checkpoint has no Swift equivalent, so it runs in its own virtual
environment at `~/Library/Application Support/Stillnote/venv-moss` as a short-lived worker
process that the app starts for each transcription. The environment deliberately lives
there rather than in this checkout: a bundled app reading the Documents folder needs
permission macOS cannot grant while the app is still launching. The app decodes
audio, parses the transcript, and owns everything else; the worker receives 16 kHz mono
samples and returns MOSS's raw text. Isolation means a native model crash cannot take the
app down, and **Stop** during transcription terminates the worker and releases its memory
rather than unwinding in-process GPU work.

On the Apple GPU, MOSS quantizes only its decoder to 8-bit in memory; the encoder and
audio adaptor keep their original precision. Independent 30-second encoder windows run one
at a time while the full recording retains a single decoder context and speaker namespace.
Prompt processing uses 512-token steps with a 256 MiB reusable buffer cache and an MLX
allocation budget of up to 6 GiB, or 70% of the device's recommended working set, whichever
is smaller. That is an MLX allocation limit, not a whole-process RAM cap: the decoder's KV
cache still grows with meeting length, so a memory-limit error suggests a shorter recording
rather than silently retrying.

Model files are pinned to a publisher revision. Setup verifies sizes and SHA-256 digests,
and inference requires complete local files with Hugging Face offline mode enabled. There
is no cloud transcription fallback. Saved Whisper and VibeVoice selections migrate to MOSS
without changing existing recordings, transcripts, or preferences.

Speaker labels are estimates, not verified identities. Review text and attribution,
especially for overlapping voices or poor audio.

### Summaries

| Local agent | Default model | Default thinking | Setup |
| --- | --- | --- | --- |
| Codex (default) | `gpt-5.6-luna` | High | Install the Codex CLI and run `codex login`. |
| Claude Code | `claude-sonnet-5` | High | Install Claude Code and run `claude auth login`. |

Choose the agent in Settings. Stillnote checks whether its executable is available;
sign-in and model access are checked when a summary runs. You can change the model ID and
thinking effort. Authentication stays with the CLI; Stillnote has no API-key or endpoint
fields.

Stillnote launches `codex exec` or `claude --print` without a shell, passing the
speaker-labeled transcript through stdin, in its own session and a private temporary
directory. Codex runs read-only with shell and web search disabled and user config
ignored; Claude Code disables built-in tools, MCP servers, slash commands, and hooks.
Each section has a five-minute deadline, after which the whole process group is killed.
Raw CLI output never becomes an error message.

By default, only transcript text and speaker labels are supplied. **Send video path to
AI** is saved separately for each recording and adds its local screen-video path to every
summary section when enabled. This shares the path as text, not the video file; file
reading stays disabled, so it does not enable video analysis. Audio, context, links, and
meeting titles are never supplied. Long transcripts are summarized in sections and merged
locally.

If a CLI is not on the app's `PATH` — likely when Stillnote is launched from Finder — set
`STILLNOTE_CODEX_BIN` or `STILLNOTE_CLAUDE_BIN` to the executable's full path.

## Local storage and privacy boundary

```text
Microphone + system audio / imported file
  → Stillnote.app → ~/Library/Application Support/Stillnote/data/audio/<meeting-id>
  → local MOSS worker → SQLite transcript and speaker labels
  → optional local Codex / Claude Code CLI
  → hosted model (transcript only, explicit confirmation)
```

Under `~/Library/Application Support/Stillnote/`:

- `data/stillnote.sqlite3`: meetings, transcripts, summaries, notes, and preferences.
- `data/audio/`: original audio, one file per meeting.
- `data/video/`: optional screen video with the same mixed audio.
- `data/recordings/`: active or interrupted sessions; removed after save or discard.
- `data/media/`: symlinks that give stored media a file extension for AVFoundation.
- `models/`: the downloaded speech model.
- `venv-moss/`: the MOSS inference runtime, created by `./scripts/setup.sh`.

Back up the data directory while the app is closed. Audio and the database stay on your
disk until you delete them. Optional environment variables: `STILLNOTE_DATA_DIR`,
`STILLNOTE_MODEL_DIR`, `STILLNOTE_MOSS_PYTHON`, `STILLNOTE_CODEX_BIN`,
`STILLNOTE_CLAUDE_BIN`.

## Development

See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation contract,
[NATIVE_MIGRATION.md](NATIVE_MIGRATION.md) for migration pitfalls and handoff context,
[TODO.md](TODO.md) for open work, and [VALIDATION.md](VALIDATION.md) for verification history.

```bash
./scripts/check.sh            # swift build, swift test, MOSS worker tests and lint
./scripts/build-app.sh debug  # faster rebuild during development
swift test --filter StoreTests
```

To retain capture permissions across rebuilds, use an existing code-signing identity:

```bash
STILLNOTE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

Without that variable, builds use ad-hoc signing. The build script verifies the resulting signature.

After editing `sidecar/`, reinstall the worker into the runtime:

```bash
uv pip install --python "$HOME/Library/Application Support/Stillnote/venv-moss/bin/python" \
  --reinstall-package stillnote-moss-worker ./sidecar
```

`swift test` covers storage and legacy-document migration, capture timing and PCM
conversion, audio mixing, decoding, and video muxing, MOSS transcript parsing, transcript
validation, summary chunking/parsing/merging, exports, link titles, and the headless agent
adapters — including that a timed-out CLI's whole process group is killed.

Transcription against the real model is opt-in, because it needs the downloaded
checkpoint and occupies the GPU:

```bash
STILLNOTE_INTEGRATION=1 swift test --filter TranscriptionIntegrationTests
```

Real summary-agent checks use synthetic transcripts and your CLI accounts (and consume
their usage). Run a provider separately with
`STILLNOTE_AGENT_INTEGRATION=1 swift test --filter AgentIntegrationTests/savesARealCodexSummary`
or `AgentIntegrationTests/savesARealClaudeSummary`.

## Troubleshooting

- **Microphone or system audio denied**: allow Stillnote under System Settings → Privacy &
  Security → Microphone and Screen & System Audio Recording, then restart the app. Because
  the app is ad-hoc signed, a rebuild can reset these grants.
- **No system audio**: enable **Include system audio** and check both meters. Speakers are
  detected from the combined audio, not from participant names.
- **Setup failed**: check your connection to the public Hugging Face host, then retry.
  Partial files are never accepted as an installed model.
- **Transcription says the runtime is missing**: run `./scripts/setup.sh`, then use
  **Check Again** in Settings. `Stillnote.app --diagnose` shows which piece is missing.
- **No speech / wrong speakers**: use clearer audio, select the language, or supply the
  expected speaker count.
- **Agent failure**: check that `codex` or `claude` is installed, up to date, signed in,
  and has access to the selected model, and that the app can find it on `PATH`.
- **A recording will not play**: AVFoundation cannot open every container. WebM/Opus files
  saved by the retired browser recorder will not play, though their transcripts and
  exports are unaffected.
- **App interrupted during processing**: restart and retry; saved audio remains intact.
