# Stillnote

A private meeting notebook that runs on your own computer. Record your microphone and system audio with optional screen video, import a recording, distinguish speakers, edit the transcript, and turn the conversation into useful notes.

**Audio recording, speech recognition, and speaker diarization run locally.** Optional summaries run through your installed Codex or Claude Code CLI, which may send transcript text to hosted models after you confirm that choice for the meeting.

## Run

Requirements: macOS, Linux, or Windows with Python 3.11–3.13 and Node.js 20.19+ (or 22.12+). macOS Apple silicon is tested. The shell scripts work in macOS/Linux; on Windows use the equivalent commands below in your terminal. `uv` is recommended for Python dependency installation. No system FFmpeg installation is required: PyAV includes the audio decoder.

```bash
./scripts/setup.sh
./scripts/start.sh
```

Open **http://127.0.0.1:8765**. The server listens only on loopback. In Settings, download the local speech models once; MOSS 0.9B is the default and downloads approximately 1.8 GB. The app then records and transcribes without an internet connection. Model setup is separate from transcription and never uploads meeting content.

Equivalent setup commands:

```bash
uv sync --extra dev
cd frontend
npm ci
npm run build
cd ..
uv run stillnote
```

If uv is unavailable, create `.venv` with Python, install `pip install -e '.[dev]'` inside it, build the frontend, and run `python -m meeting_app.main` from the activated environment. The source checkout is required to serve the bundled frontend.

## Use

1. **Record a meeting**: on macOS 15+, select a native microphone, optionally include system audio and screen video, then start and grant macOS capture permissions. Separate input meters show microphone and system audio. Pause/resume as needed and finish to save and transcribe. **Use browser recording** provides the existing microphone/shared-tab capture on other platforms. If models are not installed yet, recordings are saved for later transcription.
2. **Import audio**: choose WAV, MP3, M4A, WebM, FLAC, or a supported video container containing audio. Maximum file size is 2 GB.
3. **Review speakers**: automatic diarization assigns anonymous speaker labels. Provide an expected speaker-count hint when you know it; rename speakers and correct text or speaker assignments in the transcript. Click a timestamp to listen to that point.
4. **Generate a summary**: get an overview, key points, decisions, and action items. Choose a summary provider in Settings. Each recording's Summary tab has a **Send video path to AI** toggle, off by default, available when screen video is saved. Turning it on includes the absolute local video path in summary prompts. Remote providers require a sharing confirmation each time you generate a summary.
5. **Keep context or export**: use **Context** to add background and website links with optional labels. Background saves automatically; add, edit, or remove links using their controls. Existing personal notes appear here. Context and links are included in Markdown, plain text, and JSON exports; SRT contains subtitles only. Delete a meeting to remove its database record, original audio, and any screen video.

Leave a link's label blank to use its page title. Stillnote briefly fetches the public page without browser cookies; if a title cannot be retrieved, the website's domain remains the label. You can always enter your own label. Link icons load directly from each website's `/favicon.ico` without a referrer or a third-party icon service. If an icon is unavailable or you are offline, a globe appears instead. Linked pages are not included in summaries.

Native recordings write audio to disk during capture. Reopen **New recording** after a browser reload to reconnect; after a server interruption, save or discard the recovered session there. Optional screen video appears above the playback controls and is available in Export. Native recordings stop at 90 minutes. See [native recording setup and recovery](native/README.md).

Browser recordings stay in browser memory until you finish and save them. Keep the page open while recording and saving. If upload fails, the interface keeps the recording available to retry or download. Once saved, recordings persist on disk. Closing the app during transcription preserves audio and marks the interrupted job for retry on the next launch.

### Capturing an online meeting

On **macOS 15+**, build the native helper with `./scripts/build-capture.sh` (also included in setup when Swift is installed). Choose a microphone and enable **Include system audio** to capture remote participants from desktop apps such as Teams or Zoom. Enable **Record screen video** only when you want to save a selected display. macOS requires Microphone and Screen & System Audio Recording permissions; screen images are not saved in audio-only mode. Use headphones to reduce microphone echo. Native capture needs Xcode or Command Line Tools with a macOS 15+ SDK to build.

For the browser fallback, enable **Include shared audio**, choose the meeting's browser tab, and check the browser's audio-sharing option. Browser and OS support varies; native capture for Windows and Linux is not yet implemented. Speakers are detected from the combined audio, not from participant names or meeting accounts.

### Speech model

Stillnote uses **MOSS 0.9B** for local transcription and speaker attribution:

| Model | Hugging Face checkpoint | Download |
| --- | --- | --- |
| MOSS 0.9B | [OpenMOSS-Team/MOSS-Transcribe-Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | ~1.8 GB |

MOSS supports 50+ languages. Language and speaker-count selections are prompt hints, not enforced constraints; automatic mode preserves the original speech language without reporting a detected language code.

Setup creates `.venv` for the app and `.venv-moss` for MOSS (Transformers 5). The separate worker keeps native inference failures and cancellation isolated from the app. Both runtimes are installed by `scripts/setup.sh`. On Apple Silicon, MOSS uses the pinned MLX Audio runtime on the Apple GPU, loading the same verified checkpoint and quantizing only the decoder to 8-bit in memory. The encoder and audio adaptor keep their original precision. Independent 30-second encoder windows run one at a time; the full recording retains one decoder context and speaker namespace. Prompt processing uses 512-token steps, with a 256 MiB reusable buffer cache and an MLX allocation budget of up to 6 GiB (or 70% of the device's recommended working set, whichever is smaller). This is an MLX allocation limit, not a whole-process RAM cap; the decoder's KV cache still grows with meeting length. A memory-limit error suggests a shorter recording instead of silently retrying on the CPU.

Other platforms use PyTorch in an isolated worker: CUDA with bfloat16 when available, otherwise CPU with float32. Set `STILLNOTE_MOSS_BACKEND=torch` before starting the server to opt back into the reference MOSS backend. CPU inference can be slow and requires substantially more RAM than the download size. MOSS supports recordings up to 90 minutes and returns model timestamps. Transcription starts after recording stops. MOSS reports encoding, prompt processing, and decoded timestamp progress. Use **Stop** while transcribing to terminate the worker and release its memory; queued jobs can also be stopped. Stopping preserves the recording, notes, previous transcript, and summary.

MOSS model files are pinned to a publisher revision. Setup verifies checksums, and inference requires complete local files. MOSS loads its pinned custom Transformers code from disk. There is no cloud transcription fallback. Old saved Whisper and VibeVoice selections migrate to MOSS; existing recordings, transcripts, preferences, and downloaded legacy files are retained.

Speaker labels are estimates, not verified identities. Review text and attribution, especially for overlapping voices or poor audio.

### Summaries

| Local agent | Default model | Default thinking | Setup |
| --- | --- | --- | --- |
| Codex (default) | `gpt-5.6-luna` | High | Install Codex CLI and run `codex login`. |
| Claude Code | `claude-sonnet-5` (Sonnet 5) | High | Install Claude Code and run `claude auth login`. |

Choose the agent in Settings. Stillnote checks whether its executable is available; sign-in and model access are checked when a summary runs. You can change the model ID and thinking effort. Both CLIs must be recent enough to support the headless flags below. Authentication stays with the CLI; Stillnote has no API-key or endpoint fields.

Stillnote launches `codex exec` or `claude --print` without a shell, passing the speaker-labeled transcript through stdin. Codex uses `--output-schema`, `--output-last-message`, and `model_reasoning_effort`; Claude Code uses `--json-schema`, JSON output, and `--effort`. Each request runs in a private temporary directory with session persistence disabled. Codex uses a read-only sandbox with shell and web search disabled, and ignores user config and project instructions while retaining CLI authentication. Claude Code disables built-in tools, MCP servers, slash commands, and hooks. Its user settings remain available for CLI authentication configuration. Model availability and usage limits depend on your account; the app never silently substitutes a model.

By default, only transcript text and speaker labels are supplied from the meeting. **Send video path to AI** is saved separately for each recording and adds its local screen-video path to every summary section when enabled. Existing recordings also default to off. This shares the path as text, not the video file; file-reading tools remain disabled, so it does not enable video analysis. Audio, context, links, and meeting titles are not supplied to the agent. The CLIs may use hosted inference, so every summary requires a sharing confirmation that includes the video path when enabled. Long transcripts are summarized in sections and merged locally, with a five-minute timeout per section. Very large transcripts produce a size-limit error. CLI failures show an actionable message without exposing raw CLI logs, and preserve any earlier summary.

Old Anthropic settings migrate to Claude Code; other retired providers migrate to Codex. Migration uses the new default model and high thinking, removes obsolete API credentials and endpoint fields from the settings record, and preserves meetings and saved summaries.

The executable must be on the backend's `PATH`. For custom installations, set `STILLNOTE_CODEX_BIN` or `STILLNOTE_CLAUDE_BIN` to the executable's full path before starting the app. These variables accept an executable path, not a shell command or extra arguments.

CLI references: [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference), [Claude Code CLI](https://code.claude.com/docs/en/cli-reference), [Claude model configuration](https://code.claude.com/docs/en/model-config).

## Local storage and privacy boundary

```text
Native microphone + system audio / browser microphone / imported file
  → localhost API → data/audio/<meeting-id>
  → local speech models → SQLite transcript and speaker labels
  → optional local Codex / Claude Code CLI
  → hosted model (transcript only, explicit confirmation)
```

- `data/stillnote.sqlite3`: meetings, transcripts, summaries, notes, and provider settings.
- `data/audio/`: original audio, one file per meeting.
- `data/video/`: optional screen video with mixed audio.
- `data/recordings/`: active or interrupted native sessions; sources are removed after successful save or explicit discard.
- `models/`: downloaded speech and speaker models.
- `frontend/dist/`: locally bundled interface; no external fonts, scripts, or analytics.
- Browser local storage: unsaved note drafts, removed after successful save or meeting deletion in the interface.

`data/`, `models/`, dependencies, and build outputs are ignored by Git. Back up the data directory while the app is stopped. Audio and the database remain on your disk until deleted. This app is intended for one local user, not deployment on a shared server. It includes loopback host/origin checks and a restrictive browser content policy.

Optional environment variables: `STILLNOTE_DATA_DIR`, `STILLNOTE_MODEL_DIR`, `STILLNOTE_PORT` (default `8765`). Do not expose or proxy this unauthenticated local service to a network.

## Development and validation

```bash
# Run all checks
./scripts/check.sh

# Or run separately
# Backend + frontend tests/checks
.venv/bin/python -m pytest -q
.venv/bin/ruff check backend tests
cd frontend
npm run check
npm run build

# Frontend hot reload in a second terminal; backend still runs on 8765
npm run dev -- --host 127.0.0.1
```

The Vite dev server proxies `/api` to the local backend. For normal use, serve the compiled interface with `./scripts/start.sh` so everything shares one localhost origin.

Tests cover local persistence, audio upload/readback, transcript edits/exports, interrupted jobs, speaker/timestamp assignment, model readiness, agent-summary consent, headless CLI arguments/stdin/output, settings migration, timeouts, and error handling. The speech engine can additionally be validated using real downloaded models and synthetic two-voice audio, with network connections blocked during inference.

## Troubleshooting

- **Microphone denied**: allow microphone access for localhost in the browser and macOS privacy settings. Restart the browser after changing OS permissions.
- **No system audio**: for native recording, enable system audio and grant Screen & System Audio Recording access to Stillnote Capture in macOS settings. Check both input meters. For browser recording, select a browser tab and enable audio sharing.
- **Setup failed**: check your connection to the public Hugging Face and GitHub model hosts, then retry. Partial files are not accepted as installed models.
- **No speech / wrong speakers**: use clearer audio, select the language, or supply the expected speaker count.
- **Agent failure**: check that `codex` or `claude` is installed, up to date, signed in, and has access to the selected model. Check account usage limits. Use the executable environment variables above if the CLI is not on the server’s PATH.
- **App interrupted during processing**: restart and retry transcription or summary; saved audio remains intact.

## Model and library references

- [MOSS Transcribe Diarize](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)
- [pyannote segmentation model](https://huggingface.co/pyannote/segmentation-3.0) and [NeMo TitaNet small](https://catalog.ngc.nvidia.com/orgs/nvidia/nemo/models/titanet_small/)
- [FastAPI](https://fastapi.tiangolo.com/) and [Starlette's host protection](https://www.starlette.io/middleware/)

Downloaded model licenses remain applicable; the segmentation license is stored alongside its model.
