## Per-recording video path in summaries — September 12, 2026

- Added a saved **Send video path to AI** toggle in each recording's Summary tab, defaulting to off for new and existing meetings. The sharing confirmation reflects the choice. Audio-only recordings show the control disabled.
- 84 focused API, summarization, agent-adapter, and recording tests pass. Coverage includes per-meeting persistence, legacy defaults, opt-in and opt-out for both providers, JSON encoding, every transcript section, missing video, and consent before CLI launch. Ruff and the production frontend build pass.
- Browser checks used an isolated store with synthetic recordings and a fake CLI. Verified default off, persistence after reload, conditional consent copy, and actual CLI stdin containing the absolute video path only when enabled. Desktop and 390-pixel layouts were visually checked with no horizontal overflow.
- The running app was restarted while idle; its three existing meetings were preserved and all default to off. Only a path is sent as text; video analysis and file-reading tools remain disabled. No real meeting content was sent to a provider during validation.

## Native capture fixes — September 12, 2026

- The 11:38 macOS crash report identifies a null-format crash in `AVAudioPCMBuffer.initWithPCMFormat:frameCapacity:` on the microphone callback. Synthetic PCM descriptions with missing multichannel or inconsistent mono/stereo layout metadata reproduce a nil result from the previous `AVAudioFormat(cmAudioFormatDescription:)` initializer. The replacement builds a checked format from the PCM stream description and handles both cases; unusable transitional buffers are skipped.
- Swift regression checks pass for mono float, interleaved stereo Int16, multichannel PCM copying/conversion, inconsistent layouts, unready/invalid/empty buffers, and the existing timing/WAV recovery cases. All 12 Python recording tests and focused Ruff checks pass (existing dependency deprecation warnings remain).
- The rebuilt, signed production helper and running API report **Built-in Retina Display (main)** and **G24F 2**, preserving their capture IDs.
- Live verification also reproduced external-display video finalization failure after pause/resume (`AVFoundation -11800`, underlying `-16341`). Disabling H.264 frame reordering resolved repeated reproductions on the external display and passed the built-in display check. Specific capture errors are now preserved when video finalization also fails.
- Final hardware checks used temporary stores with the production helper: microphone plus system audio, screen video on each display, and the Microsoft Teams virtual microphone. All four passed pause/resume, clean process exit, save, and 48 kHz mono WAV validation. Saved videos contain AAC audio and decoded frames after resume (44 built-in / 46 external frames in the final short checks). Temporary media was removed; the running app has no active recording.
- These were short hardware checks. Audible system playback, device disconnection, and long-running synchronization remain unverified.

## Native recording — September 12, 2026

- Added native microphone/system-audio capture and optional screen video for macOS 15+, keeping the browser recorder as a fallback.
- The Swift helper compiles and is ad-hoc signed on macOS 26.5.1 / Apple silicon. Native device discovery finds the built-in microphone, connected audio inputs, and both displays without recording.
- Swift checks pass for pause/resume timing, rejecting stale paused buffers, stereo-to-mono resampling, RMS/peak levels, silence alignment, and reading WAV data before capture finalization.
- 156 Python tests pass, including 12 native-capture tests. Those tests use a real synthetic helper subprocess for start/pause/resume/stop/discard, denied permissions, unexpected exits, server restart recovery, failed-save retries, idempotent saves, bounded audio mixing, video/audio muxing, range playback, and deletion.
- Ruff and TypeScript checks and the Vite production build pass. The existing Starlette/httpx deprecation warnings remain.
- The browser flow was checked with an isolated synthetic capture server: source options, optional display selection, input meters, pause, page reload/reconnect, resume, saving, screen video playback, and screen export. Video decoded and advanced in the browser. Desktop and 390-pixel modal layouts were visually checked; the narrow modal scrolls without horizontal overflow.
- Native setup verified on this Mac: macOS reported microphone and screen/system audio permission already granted. A brief capture through the running API received 48 kHz microphone and system streams (204,906 and 203,790 frames), with nonzero microphone input. Pause held the timer steady and resume continued capture. System audio was silent during this check. The test session was discarded and the two existing saved meetings were preserved.
- Audible system sound, screen-video capture, permission-denial prompts, display disconnection, and long-running hardware synchronization still require hardware checks. Native Windows/Linux capture is not implemented.

# Validation record

## Apple Silicon MOSS optimization — September 8, 2026

Hardware: Apple M5, 32 GiB unified memory. MLX 0.32.2; MLX Audio revision `17001a6950956302f15b53d86b601324efe716ba`. Same verified upstream MOSS checkpoint; decoder quantized locally to 8-bit, encoder/adaptor retain checkpoint precision.

- The original 23.8-minute transcription was explicitly stopped. Its worker had run approximately 25 minutes and showed ~7.4 GiB RSS when stopped. Existing audio, transcript, notes, and summary were retained.
- On the same local 60-second excerpt, the CPU float32 backend took 17.37 seconds with 5.63 GiB peak process RSS. MLX took 6.17 seconds with 2.34 GiB peak process RSS and 2.15 GiB peak MLX allocation: about 2.8× faster and 58% less process RSS. Both returned eight segments and one speaker; text differed, so this does not establish equal transcription accuracy. One measured run per backend; startup included, filesystem/shader caches may be warm.
- The 2.922-second synthetic smoke test returned the exact spoken sentence and matching timestamps through MLX.
- A full-recording encoding/prefill-only check processed 48 encoder windows and 18,890 prompt tokens in 13.75 seconds. Peak MLX allocation was 3.58 GiB; peak process RSS was 2.30 GiB. Only the first generated token was requested, and no transcript was saved. Full-recording generation was not benchmarked; KV memory grows as output continues. Metal allocations and process RSS are different measurements and must not be added or treated as interchangeable.
- 122 tests pass, including cancellation of active native workers, immediate cancellation of queued jobs, preservation of previous work, backend selection, output budget limits, and encoder batching with one decoder context. Ruff, TypeScript, and Vite build pass.
- Browser verification used a temporary data directory on port 8766. Real MLX worker transcription completed; clicking Stop during another run terminated processing and preserved its prior transcript.

Research used: [OpenMOSS source and usage](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize), [MLX Audio MOSS implementation](https://github.com/Blaizzy/mlx-audio/blob/17001a6950956302f15b53d86b601324efe716ba/mlx_audio/stt/models/moss_transcribe_diarize/moss_transcribe_diarize.py), [MLX memory controls](https://ml-explore.github.io/mlx/build/html/python/memory_management.html). The original OpenMOSS automatic device selection chooses CUDA or CPU; it does not select the Mac GPU. MLX Audio supports the original checkpoint and exposes encoder, prefill, and generation operations used by this adapter.


## Current speech roster — September 8, 2026

- Replaced the roster with MOSS 0.9B → VibeVoice 1.5B → VibeVoice 7B; MOSS is the default.
- 115 Python tests cover API acceptance/rejection, migration of all six old selections, offline readiness, checksum repair, partial downloads, native worker isolation, timestamp normalization, speaker changes, and both VibeVoice adapters.
- Ruff, TypeScript checking, and the Vite production build pass.
- MOSS's ~1.8 GB checkpoint is installed locally. Actual inference through the isolated `.venv-moss` worker (Transformers 5.16.1, PyTorch 2.14.0, CPU) succeeded on a synthetic 2.922-second recording. It returned “Hello everyone. We will review the meeting notes tomorrow.” with one speaker and timestamps 0.06–2.92 seconds. Hugging Face and Transformers offline flags were enabled. This is a functional smoke test, not an accuracy or speed benchmark.
- The app/VibeVoice runtime uses Transformers 4.57.6. Its real model/processor imports passed; both streaming adapters were checked with controlled outputs and trained chunk geometry. VibeVoice weights were not downloaded and full inference for those two checkpoints remains untested.
- No new browser interaction test was performed for this change. The older browser and Whisper checks below are historical and do not establish accuracy or speed for the replacement models.

## Previous implementation validation


Validated on macOS Apple silicon, Python 3.13, Node 20.19.3.

## Automated checks

`./scripts/check.sh` passes:

- 91 Python tests: API/storage, imports/exports, recovery, speaker alignment, offline readiness, native-worker failures, provider requests, consent, and regression cases.
- Ruff checks on backend and tests.
- TypeScript check and Vite production build.
- Frontend dependency install reported zero audit vulnerabilities.

Two upstream Starlette/httpx deprecation warnings are emitted by TestClient. They do not affect the app runtime or test results.

## Actual speech inference

A locally generated 31.335-second meeting with two voices and four alternating turns was transcribed using installed Whisper Tiny, local pyannote segmentation, and NeMo TitaNet embeddings. The engine detected English and two consistent speakers automatically. The isolated worker processed the fixture in 2.25 seconds in the measured run. This synthetic fixture is a smoke test, not an accuracy benchmark for real meetings or overlapping voices.

Python socket connections were blocked inside the worker with a test-only `sitecustomize.py`. The engine additionally restricts native media protocols and external media references. The model/tokenizer paths are local and Hugging Face offline mode is set. This checks the implemented offline path; it is not an OS packet-capture audit.

A full API test also passed import → isolated speech worker → four speaker segments → local summary → SRT export, using a temporary data directory.

## Browser verification

Verified through the actual localhost interface:

- Empty library and installed model readiness.
- File import and real two-speaker transcription.
- Local summary creation, speaker rename, transcript correction, and updated Markdown export.
- Notes persist across sidebar navigation and page reload.
- Remote provider preferences save; summary confirmation displays the destination and model. Canceled before sending; no actual remote provider calls or credentials used.
- Browser MediaRecorder start, pause, resume, stop, simulated failed save, retry, and saved audio persistence. Synthetic Web Audio replaced microphone input for this test; no real microphone was opened.
- Unload guard remains active while recording and while the failed recording awaits retry.
- A synthetic tone correctly returns “No speech detected” while keeping its original audio.
- Desktop and 390px-wide transcript layouts visually checked.
- No browser errors during tested recording flow; fresh app resource requests used only the localhost origin.

All generated QA meetings were removed. Default summary is local; Tiny and speaker models remain installed for immediate use.

## Not exercised with external services/hardware

Real microphone permissions, OS-specific shared audio, non-English meeting accuracy, and authenticated remote summaries depend on user hardware/configuration and were not tested with real user audio or provider accounts. Remote adapters were tested against mocked HTTP responses. Native desktop-wide system audio capture and live transcription are outside this version.
