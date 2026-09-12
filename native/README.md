# Native recording helper

Stillnote uses a small Swift helper on **macOS 15+** to capture the selected microphone and optional system audio with ScreenCaptureKit. Screen video is optional and off by default. The React interface and Python API remain a localhost application. Other platforms can use the existing browser recorder or import files.

## Build

Install Xcode or the Xcode Command Line Tools with a macOS 15+ SDK, then run:

```bash
./scripts/build-capture.sh
```

The script compiles and ad-hoc signs `native/build/Stillnote Capture.app`. `scripts/setup.sh` also builds it when Swift is available on macOS. Compiled output is ignored by Git. Rebuild after changing the Swift sources; Python never downloads or compiles executable code at recording time.

Open **New recording**, select the microphone, leave **Include system audio** enabled for online meetings, and optionally turn on **Record screen video** and select a display. The helper asks macOS for microphone and screen/system audio permission only when you start recording. In System Settings → Privacy & Security, allow **Stillnote Capture** (or the terminal/app launching Stillnote, depending on macOS attribution). If a permission change requires relaunching, stop and restart Stillnote.

ScreenCaptureKit requires screen recording permission for system audio and its microphone stream, including audio-only sessions. Audio-only sessions attach no screen output and write no screen images. No camera access is requested. The helper’s `permissions` command reports the current grants; `authorize` opens the macOS prompts without starting a recording. Permissions cannot be granted by the web page. Use headphones to keep speaker playback out of the microphone; there is no acoustic echo cancellation in the native helper.

## Capture and recovery

- `devices` returns microphone IDs and display IDs with macOS monitor names without starting a stream.
- `record <session-directory>` reads server-generated `options.json`, writes PCM to disk, and emits JSON lines on stdout. Stdin accepts `pause`, `resume`, and `stop`; EOF also ends capture.
- A serial callback queue normalizes both sources to mono 48 kHz PCM, reports RMS/peak levels every 200 ms, and aligns samples using host-clock timestamps. Paused time is removed from every source. Sparse gaps contain silence.
- WAV headers update during recording. Screen video uses fragmented H.264 MP4 at up to 1920 pixels wide and 15 fps, with frame reordering disabled so pause/resume timestamps remain safe to finalize. Capture stops if usable microphone callbacks cease for eight seconds or after 90 minutes of recorded time.
- The Python API owns one capture session at a time. Browser reloads reconnect through `/api/recordings/current`. Capture continues until stopped, discarded, interrupted, or the server exits; it is never started automatically from another app's microphone activity.
- Finishing mixes audio in one-second blocks with equal gains to leave clipping headroom, then muxes a copy into the optional screen MP4. Speech inference reads only the WAV. The original source WAVs are removed after the meeting is saved successfully.
- Unsaved sessions live in `data/recordings/<id>/`. After an interrupted server run, **New recording** offers to save recovered audio or discard the session. Recoverable video fragments are retained when they can be decoded; otherwise the meeting shows a warning and keeps its audio. A hard crash can lose the last audio write or incomplete video fragment.
- Saved audio lives in `data/audio/<id>`; screen video with the same mixed audio lives in `data/video/<id>`. Playback, seeking, speed controls, download, and meeting deletion handle both files. Video is never supplied to transcription or summaries.

Native capture currently targets macOS only. Windows WASAPI and Linux loopback backends are not implemented. The browser fallback retains its existing microphone/shared-tab behavior and does not save screen video.

## Verification

```bash
.venv/bin/python -m pytest -q tests/test_recording.py
xcrun swiftc -swift-version 5 -module-cache-path native/build/module-cache \
  native/macos/CaptureSupport.swift native/macos/CaptureTests.swift \
  -o native/build/capture-tests
native/build/capture-tests
```

The Swift checks exercise PCM sample copying, missing/inconsistent channel layouts, empty/invalid buffers, multichannel conversion, pause timing, stereo-to-mono sample-rate conversion, signal levels, timestamp-aligned silence, and readable WAV headers before finalization. Python tests run a synthetic helper subprocess to check lifecycle, recovery, permissions failures, retry safety, audio mixing, MP4 video/audio muxing, range playback, and deletion. They do not replace a live OS-permission and hardware capture check.

## Implementation references

The design was informed by [Meetily's native audio tap](https://github.com/Zackriya-Solutions/meetily/blob/main/frontend/src-tauri/src/audio/capture/core_audio.rs) and [per-source level monitoring](https://github.com/Zackriya-Solutions/meetily/blob/main/frontend/src-tauri/src/audio/level_monitor.rs). Stillnote uses its own implementation around [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), including its macOS 15 microphone output, to share one timing source with optional video. No Meetily source code is vendored.
