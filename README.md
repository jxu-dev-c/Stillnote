# Stillnote

A private meeting notebook that runs on your own computer. Record your microphone, import a recording, distinguish speakers, edit the transcript, and turn the conversation into useful notes.

**Audio recording, speech recognition, and speaker diarization run locally.** Optional remote summaries send only transcript text after you confirm that choice for the meeting. The default summary never uses the network.

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

1. **Record a meeting**: grant microphone access, optionally select a browser tab and enable its shared audio, then start. Pause/resume as needed and finish to save and transcribe. If models are not installed yet, the audio is saved for later transcription.
2. **Import audio**: choose WAV, MP3, M4A, WebM, FLAC, or a supported video container containing audio. Maximum file size is 2 GB.
3. **Review speakers**: automatic diarization assigns anonymous speaker labels. Provide an expected speaker-count hint when you know it; rename speakers and correct text or speaker assignments in the transcript. Click a timestamp to listen to that point.
4. **Generate a summary**: get an overview, key points, decisions, and action items. Choose a summary provider in Settings. Remote providers require a transcript-sharing confirmation each time you generate a summary.
5. **Keep or export**: add personal notes and export Markdown, plain text, JSON, or speaker-labeled SRT subtitles. Delete a meeting to remove its database record and original audio.

Recordings stay in browser memory until you finish and save them. Keep the page open while recording and saving. If upload fails, the interface keeps the recording available to retry or download. Once saved, recordings persist on disk. Closing the app during transcription preserves audio and marks the interrupted job for retry on the next launch.

### Capturing an online meeting

Microphone recording captures what the selected input actually hears. For remote participants, enable **Include shared audio**, choose the meeting's browser tab, and check the browser's audio-sharing option. Browser and OS support varies. This version does not capture arbitrary desktop applications' system audio natively; use an audio loopback device as the microphone input or import a recording from that application. Speakers are detected from the combined audio, not from participant names or meeting accounts.

### Speech models

The roster runs from **Fast / light ←→ Quality**:

| Model | Hugging Face checkpoint | Download |
| --- | --- | --- |
| MOSS 0.9B (default) | [OpenMOSS-Team/MOSS-Transcribe-Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | ~1.8 GB |
| VibeVoice 1.5B | [microsoft/VibeVoice-ASR-Streaming-1.5B](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-1.5B) | ~5.6 GB |
| VibeVoice 7B | [microsoft/VibeVoice-ASR-Streaming-7B](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-7B) | ~17.4 GB |

These are speech-to-text models with built-in speaker attribution. The VibeVoice names refer to their language backbone sizes; total checkpoint sizes include audio encoders. The ordering is a selection guide, not a measured accuracy guarantee. MOSS supports 50+ languages; VibeVoice supports Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Russian, and Spanish. Language and speaker-count selections are prompt hints, not enforced constraints; automatic mode preserves the original speech language without reporting a detected language code.

Setup creates `.venv` for the app and VibeVoice (Transformers 4), and `.venv-moss` for MOSS (Transformers 5), whose upstream requirements differ. Both runtimes are installed by `scripts/setup.sh`. On Apple Silicon, MOSS uses the pinned MLX Audio runtime on the Apple GPU, loading the same verified checkpoint and quantizing only the decoder to 8-bit in memory. The encoder and audio adaptor keep their original precision. Independent 30-second encoder windows run one at a time; the full recording retains one decoder context and speaker namespace. Prompt processing uses 512-token steps, with a 256 MiB reusable buffer cache and an MLX allocation budget of up to 6 GiB (or 70% of the device's recommended working set, whichever is smaller). This is an MLX allocation limit, not a whole-process RAM cap; the decoder's KV cache still grows with meeting length. A memory-limit error suggests a shorter recording instead of silently retrying on the CPU.

Other platforms use PyTorch in an isolated worker: CUDA with bfloat16 when available, otherwise CPU with float32. VibeVoice retains its existing PyTorch backend. Set `STILLNOTE_MOSS_BACKEND=torch` before starting the server to opt back into the reference MOSS backend. CPU inference can be slow and requires substantially more RAM than the download size. MOSS supports recordings up to 90 minutes and returns model timestamps. VibeVoice uses approximate audio-chunk timestamps; speaker changes within a chunk share its interval. Transcription starts after recording stops. MOSS reports encoding, prompt processing, and decoded timestamp progress. Use **Stop** while transcribing to terminate the worker and release its memory; queued jobs can also be stopped. Stopping preserves the recording, notes, previous transcript, and summary.

Model files and the VibeVoice runtime are pinned to publisher revisions. Setup verifies checksums, and inference requires complete local files. MOSS loads its pinned custom Transformers code from disk. There is no cloud transcription fallback. Old saved Whisper selections migrate to MOSS; existing recordings, transcripts, preferences, and downloaded legacy files are retained.

Speaker labels are estimates, not verified identities. Review text and attribution, especially for overlapping voices or poor audio.

### Summaries

| Provider | Where processing runs | Setup |
| --- | --- | --- |
| Built-in local | In this Python process | None. Extracts important sentences and explicit commitments; not a generative language model. |
| Ollama | A local loopback Ollama server | Pull a local model with Ollama, enter its name and local URL. Cloud-backed Ollama models are rejected. |
| OpenAI-compatible | Your chosen HTTPS provider | Configure the API base URL, model ID, and key. Uses Chat Completions. |
| Anthropic | Your chosen HTTPS Anthropic-compatible endpoint | Configure the base URL, model ID, and API key. Uses Messages. |

No provider receives audio, notes, filenames, or other meeting metadata. Summary providers receive the speaker-labeled transcript and summary instructions. Long transcripts are summarized in sections, and results are merged locally. A remote provider may charge for multiple section requests. Very large transcripts receive an explicit size-limit error rather than silent truncation. Local extraction's action/decision detection works best with English. For generative local summaries, use Ollama.

Provider keys remain on the backend, in the local SQLite settings record; the API returns only whether a key is configured. The SQLite file and audio files are created with owner-only file permissions on macOS/Linux. Keys are not encrypted or stored in the system keychain. Do not share or commit the data directory. Changing a provider/endpoint clears the previous key unless you provide a new key.

## Local storage and privacy boundary

```text
Browser microphone / imported file
  → localhost API → data/audio/<meeting-id>
  → local speech models → SQLite transcript and speaker labels
  → built-in local summary / local Ollama
  → optional remote summary (transcript only, explicit confirmation)
```

- `data/stillnote.sqlite3`: meetings, transcripts, summaries, notes, and provider settings.
- `data/audio/`: original audio, one file per meeting.
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

Tests cover local persistence, audio upload/readback, transcript edits/exports, interrupted jobs, speaker/timestamp assignment, model readiness, remote-summary consent, provider payloads, and error handling. The speech engine can additionally be validated using real downloaded models and synthetic two-voice audio, with network connections blocked during inference.

## Troubleshooting

- **Microphone denied**: allow microphone access for localhost in the browser and macOS privacy settings. Restart the browser after changing OS permissions.
- **No shared audio**: select a browser tab and enable audio sharing. Native meeting app audio may require a virtual audio input or an imported file.
- **Setup failed**: check your connection to the public Hugging Face and GitHub model hosts, then retry. Partial files are not accepted as installed models.
- **No speech / wrong speakers**: use clearer audio, select the language, or supply the expected speaker count. Try VibeVoice 1.5B or 7B and compare recognition on your recordings.
- **Provider failure**: verify the endpoint, model name, and key. Remote endpoints require HTTPS. Ollama must run on a loopback address with a local model.
- **App interrupted during processing**: restart and retry transcription or summary; saved audio remains intact.

## Model and library references

- [MOSS Transcribe Diarize](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)
- [VibeVoice ASR Streaming](https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr-streaming.md)
- [pyannote segmentation model](https://huggingface.co/pyannote/segmentation-3.0) and [NeMo TitaNet small](https://catalog.ngc.nvidia.com/orgs/nvidia/nemo/models/titanet_small/)
- [FastAPI](https://fastapi.tiangolo.com/) and [Starlette's host protection](https://www.starlette.io/middleware/)

Downloaded model licenses remain applicable; the segmentation license is stored alongside its model.
