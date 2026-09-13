## Native app follow-up fixes — September 12, 2026

- Fixed opening Summary Settings overwriting a saved custom Claude model. Reproduced with a synthetic library before the change; opening Settings now preserves the model, while an explicit provider switch resets it to that provider's default.
- Notes now retain a recoverable draft on failed writes, display "Not saved", and offer Retry. Three regression tests cover failure/recovery/retry, edits during a save, and the character limit. A SQLite trigger in the isolated QA library forced a real UI save failure; the original notes remained intact, the draft stayed visible, and Retry persisted it after removing the trigger. Notes and links survived relaunch.
- Fixed the audio transport remaining on Pause at end of playback by observing `AVPlayer.timeControlStatus`. Verified playback, transcript timestamp seeking, and the return to Play at the end of a synthetic 12-second WAV.
- Recording and import now initialize language and speaker count from Settings. Verified English and two speakers in both sheets. The screen-video form expands to fit its display selector. Recording setup/save transitions disable conflicting actions and interactive dismissal.
- Real Codex summaries passed both the opt-in adapter/store integration check and the app's sharing confirmation → generation → rendered overview/decisions/actions → relaunch flow, using synthetic transcripts only. Claude Code's real adapter failed; a direct diagnostic returned `ENOTFOUND` reaching its configured API server. It remains an external connectivity blocker, not a successful summary check.
- Native recording startup was attempted with microphone, system audio, and screen video in the isolated library. macOS TCC denied capture before any recording began. Live pause/resume/save and both-display checks remain open. `security find-identity -v -p codesigning` found zero valid identities. The build now accepts `STILLNOTE_SIGNING_IDENTITY` and verifies its signature; stable-identity permission retention remains unverified.
- `scripts/check.sh` passes (Swift build/tests, MOSS worker tests, ruff), including the new notes tests; real-agent and real-model suites remain opt-in. The rebuilt debug app launches through `open`; shell syntax and diff whitespace checks pass. All interactive mutations used a separate temporary library; the user's meetings were not edited.

## Native migration handoff documentation — September 12, 2026

- Imported the Notion handoff into [NATIVE_MIGRATION.md](NATIVE_MIGRATION.md), preserving all eleven pitfalls, migration decisions, baseline commits, and verification limits. Added the missing native-app hardware, real-agent, and interactive UI checks to [TODO.md](TODO.md).
- Cross-checked the handoff against `427151b` on `swift-native-app`, including startup ordering, bundle resources, runtime setup, media symlinks, mono channel layout, checkout discovery, and the video-mux completion latch. Corrected the runtime path in the native-app entry below to match the final migration layout.
- Verified all 24 relative Markdown links across the four edited documents resolve, all eleven pitfalls are present, and the diff has no whitespace errors. Documentation-only change; the historical test and inference results below were not rerun. Open verification tasks remain unchecked.

## Native macOS Swift app — September 12, 2026

- Replaced the FastAPI server and React interface with a native SwiftUI app (SwiftPM, macOS 15+, Apple silicon, no external Swift dependencies). Capture, storage, audio decoding/mixing/muxing, model download, summaries, exports, and link titles are now Swift and run in process; nothing listens on a network port. MOSS 0.9B inference remains Python in `~/Library/Application Support/Stillnote/venv-moss`, reduced to a `moss_worker` package the app starts per transcription.
- 48 Swift tests pass, covering storage and legacy-document/settings migration, capture timing, PCM conversion across channel layouts, live WAV recovery, audio mixing, decoding to 16 kHz mono, muxing captured H.264 with mixed audio (video copied, not re-encoded), MOSS transcript parsing, transcript validation, summary chunking/parsing/merging, all four exports, link titles, and the headless Codex/Claude Code adapters. The adapter tests use a stand-in CLI to assert the real argv, that the transcript travels on stdin and never as an argument, that CLI output never reaches an error message, and that a timed-out CLI's whole process group is killed. Two MOSS worker tests and ruff pass in the Application Support MOSS runtime.
- Real MLX inference passed end to end through the Swift pipeline: decode → worker → parse, on an existing 81-second recording, returning 11 segments with one speaker and timestamps 1.96–75.68 seconds, matching the worker's raw output exactly. Cancelling mid-run terminated the worker with no surviving `moss_worker` process. Both are opt-in (`STILLNOTE_INTEGRATION=1`).
- `Stillnote.app --diagnose` on the built bundle resolves the checkout, migrated data and models, the MOSS runtime (ready), the installed model, both agent CLIs, 3 microphones, and 2 displays. First launch moved the existing `data/` and `models/` directories to `~/Library/Application Support/Stillnote/` with all three meetings intact.
- Launching the built bundle through LaunchServices first hung before drawing: `App.init()` probed `.venv-moss` inside the checkout, and reading the Documents folder blocked on a permission prompt that cannot be shown until the app has a window. Fixed by moving every filesystem read off the launch path and installing the MOSS runtime under Application Support instead of the checkout. The app now opens from `open build/Stillnote.app`, lists all three meetings, and reports the runtime ready.
- MOSS worker dependencies dropped from 66 to 37 packages: PyTorch, PyAV, librosa, numba, and soundfile are gone, since the app decodes audio and parses transcripts. `mlx` 0.32.2 and `transformers` 5.16.1 stay pinned to the verified versions. Dropping PyTorch also removed `jinja2`, which Transformers needs for MOSS's chat template; it is now a direct requirement, found by running real inference in a freshly created runtime.
- Known gap: AVFoundation cannot open WebM/Opus, so recordings saved by the retired browser recorder cannot be played or re-transcribed. Their transcripts, summaries, and exports are unaffected. Import now advertises WAV, MP3, M4A, AAC, FLAC, AIFF, MP4, and MOV.
- Not verified in this change: live hardware capture (microphone, system audio, screen video, pause/resume/save) and a real summary through either CLI. The interface was not exercised interactively.

## MOSS-only speech model — September 12, 2026

- Removed the speech-model selector and retired VibeVoice 1.5B/7B from the active catalog, settings API, install API, and inference entry points. Saved VibeVoice selections migrate to MOSS while preserving other preferences and meeting data. VibeVoice-specific parsing, streaming inference, dispatch, and app dependencies remain commented out for reference.
- 167 Python tests pass in a freshly installed app environment with no Torch, Transformers, VibeVoice, or librosa. Coverage includes retired-model rejection before download/worker launch, persisted settings migration, post-migration transcription, default/explicit MOSS installation, recording recovery, worker cancellation, and existing data preservation. Ruff, TypeScript, production build, and locked dependency validation pass. The two existing Starlette/httpx/AnyIO deprecation warnings remain.
- Real MLX inference through the unchanged `.venv-moss` worker passed import → transcription → audio readback → SRT export from that minimal app environment. A 3.213-second synthetic recording returned “Hello everyone. We will review the meeting notes tomorrow.” with one speaker and timestamps 0.04–2.98 seconds. No user meeting audio was used. This is a functional smoke test, not an accuracy benchmark.
- Browser checks confirmed no speech-model dropdown, MOSS model details/readiness, language and speaker-count persistence after reload, and usable desktop/390-pixel layouts without horizontal overflow.
- Restarted the idle local app on port 8765. Health reports only MOSS, ready on Apple GPU; all three existing meetings and transcription/summary preferences match the pre-restart API state. Temporary QA data and the QA server were removed. Physical recording and full PyTorch inference were not repeated for this change.

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
