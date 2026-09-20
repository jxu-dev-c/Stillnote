# Native macOS migration handoff

> Historical notes for the earlier UI migration. The current speech engine is bundled
> native Swift; see ARCHITECTURE.md and Vendor/MossTranscribeDiarize/UPSTREAM.md.

This records the migration's lessons and verification limits. It is a historical
snapshot, not evidence of a new test run. Use [ARCHITECTURE.md](ARCHITECTURE.md) for the
current implementation contract and [TODO.md](../TODO.md) for open work.

## Baseline and decisions

The handoff and the checkout at import both end at `427151b` on `swift-native-app`:

- `2c033f3` — Rewrite Stillnote as a native macOS Swift app.
- `4e95439` — Make the app launch cleanly from a bundle.
- `427151b` — Show speakers inline and harden the video muxer.

The handoff reported these three commits ahead of `master`, unpushed, with `master`
untouched. That describes the handoff's Git state, not a publishing instruction.

The migration replaced FastAPI on `127.0.0.1:8765` and React/Vite with SwiftUI. The old
backend, frontend, Python tests, and native-helper trees were removed; the app no longer
listens on a network port. The decisions to preserve are:

- Apple silicon and macOS 15+ only; no PyTorch backend or browser-recording fallback.
- SwiftPM plus a bundle-assembly script, with stock SwiftUI/AppKit controls and system
  appearance. Feature parity was the aim; the old palette and custom controls were
  deliberately retired. Migration phases each ended runnable.
- MOSS inference is a short-lived Python subprocess using the stdio `STILLNOTE_EVENT`
  protocol. Swift owns capture, storage, audio processing, transcript parsing, summaries,
  and exports.
- Keep the existing two-table SQLite JSON-document schema and adopt checkout data/models
  into `~/Library/Application Support/Stillnote/` on first launch.
- Normal GUI startup must reach a window before filesystem work begins. Keep the runtime
  under Application Support, not in the Documents checkout. The explicit `--diagnose`
  command is a separate headless path.

## Pitfalls and fixes to preserve

1. **LaunchServices hung before showing a window.** Probing the checkout's MOSS virtual
   environment from `App.init()` read a TCC-protected Documents folder. The permission
   prompt could not appear until the app had a window. Running the binary from Terminal
   worked because it inherited Terminal's grants, so that alone did not verify bundle
   launch. `lsappinfo list` showed `!cgsConnection`; `/usr/bin/sample <pid>` showed the
   main thread in `__open_nocancel`. Normal startup now defers I/O to `AppModel.load()`
   and runs path resolution and environment probes off the main actor. The runtime is
   installed in Application Support. Preserve this ordering when adding startup checks.
   See [StillnoteApp.swift](../Sources/Stillnote/StillnoteApp.swift),
   [AppModel.swift](../Sources/Stillnote/AppModel.swift), and [setup.sh](../scripts/setup.sh).

2. **Nested SwiftPM resource bundles also stalled launch.** A `.bundle` inside the
   assembled app's Resources hung `_CFBundleCreate` when launched through `open`.
   [build-app.sh](../scripts/build-app.sh) copies resources as plain files.
   [SpeechCatalog.swift](../Sources/StillnoteCore/Speech/SpeechCatalog.swift) checks the main
   bundle and executable-adjacent manifest first, using `Bundle.module` as a fallback
   outside the assembled app, including tests. Verify bundle launch after packaging edits.

3. **Case-insensitive deletion destroyed the new Swift tests.** Removing the retired
   lowercase `tests` directory also removed `Tests` on the Mac's case-insensitive
   filesystem; the suite had to be rewritten. Check case collisions before deleting or
   renaming old trees.

4. **Removing PyTorch also removed an implicit dependency.** Transformers still needed
   `jinja2` for MOSS's chat template. Only real inference in a freshly created runtime
   exposed the omission. the former `requirements-moss.txt` now declares it
   directly. Dependency cleanup needs a fresh-runtime inference check, not just imports.

5. **An unqualified `uv venv` selected Python 3.10.** It could not satisfy the locked
   `numpy==2.5.3`. The `uv` path in [setup.sh](../scripts/setup.sh) now selects Python 3.13
   explicitly. Its non-`uv` fallback uses `python3`, which must already be a compatible
   version; the worker declares Python 3.11–3.13.

6. **Extensionless stored media failed to open.** AVFoundation selected its demuxer from
   the path extension. [MediaFile.swift](../Sources/StillnoteCore/Audio/MediaFile.swift)
   supplies extension-bearing symlinks in `data/media/` while preserving the original
   storage layout for both audio and video. This does not add WebM/Opus decoding support.

7. **Mono downmixing required explicit channel metadata.** `AVAssetReaderAudioMixOutput`
   refused sources whose channel count differed from the requested output without an
   `AVChannelLayoutKey`. Keep the explicit mono layout in
   [AudioDecoder.swift](../Sources/StillnoteCore/Audio/AudioDecoder.swift).

8. **An open test writer left an unreadable audio header.** An `AVAudioFile` writer must
   leave scope before the generated file is read; otherwise `loadTracks` can fail on an
   unflushed header. This was a fixture-lifetime problem, not an app failure. See
   [CaptureSupportTests.swift](../Tests/StillnoteCoreTests/CaptureSupportTests.swift).

9. **Checkout discovery failed under `swift test`.** Six parent levels were insufficient
   for nested test bundles, and `Bundle.main` could point into the toolchain.
   [Paths.swift](../Sources/StillnoteCore/Store/Paths.swift) searches up to ten levels from
   the executable paths and the working directory. Preserve the working-directory
   fallback for the test runner.

10. **Video finalization could resume a continuation twice.**
    `requestMediaDataWhenReady` re-entered before `markAsFinished()` took effect, causing
    a checked-continuation trap. [VideoMuxer.swift](../Sources/StillnoteCore/Audio/VideoMuxer.swift)
    keeps completion behind a locked, reference-typed latch owned by the callback.

11. **A window on the second display looked like a blank launch.** The observed window
    was at `X=-354, Y=-873`. Use `CGWindowListCopyWindowInfo` to locate windows and, when
    diagnosing a two-display setup, `screencapture -x d1.png d2.png` to capture both.
    A screenshot of only the primary display did not establish a rendering failure.

## Verification boundary and remaining work

The handoff reports 48 passing Swift tests, two passing MOSS worker tests, and clean
ruff checks. Real inference on an 81-second recording returned 11 segments with one
speaker at 1.96–75.68 seconds; cancellation left no surviving worker. Bundle diagnostics
resolved the migrated data/models, ready runtime, installed model, both agent CLIs,
three microphones, and two displays. Launching with `open` showed the three existing
meetings and no runtime setup warning. Detailed verification notes remain in Git
history in `VALIDATION.md` at commit `259804c`.

The worker dependency set fell from 66 packages to 37, with MLX 0.32.2 and Transformers
5.16.1 pinned at the handoff. These are recorded versions, not a recommendation to update
dependencies during follow-up work.

The following remain open in [TODO.md](../TODO.md):

- **Legacy WebM/Opus playback and retranscription.** The handoff observed this on an
  existing browser recording; saved transcripts, summaries, and exports remained usable.
  It suggested a PyAV (`av`) decode fallback in the sidecar. That is a candidate approach,
  not an implemented fix or a locked decision; playback as well as transcription needs
  a supported media path.
- **Stable app signing.** Ad-hoc signing can reset microphone and screen-recording grants
  on rebuild. The handoff proposed using a stable signing identity.
- **Live capture in the native app.** Microphone, audible system audio, screen video,
  pause/resume, and save need hardware verification. Older helper-era capture results
  do not establish that the migrated app works end to end.
- **Real Codex and Claude Code summaries.** Stand-in CLI adapter tests do not verify
  authentication, model access, or a real summary. Follow-up checks can use a synthetic
  transcript and the normal sharing confirmation.
- **Interactive screens beyond the meeting list.** Detail, transcript, summary, context,
  settings, and the recording sheet had only compile-time/code-level review. They need
  interactive checks of navigation, playback, edits, and persistence.

The pre-existing Refine, Apple Intelligence summaries, speaker identity memory, and
speaker contact features also remain in TODO; the handoff did not implement them.
