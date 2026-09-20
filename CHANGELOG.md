# Changelog

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
