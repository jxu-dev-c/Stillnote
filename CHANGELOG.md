# Changelog

## Unreleased

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
