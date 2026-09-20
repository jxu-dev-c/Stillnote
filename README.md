# Stillnote

A private meeting notebook for your Mac. Record meetings or import recordings,
turn speech into speaker-labeled transcripts, and keep summaries and notes together.

## Why Stillnote?

- **Local transcription.** Audio and speech recognition stay on your Mac, with offline transcription after the initial model download.
- **Capture the whole conversation.** Record microphone and system audio, with optional screen video.
- **Make meetings useful.** Edit transcripts, name speakers, add notes, and export your work.
- **Optional AI summaries.** Generate key points, decisions, and action items through Codex or Claude Code. Transcript text may be sent to hosted models with your confirmation.

## Installation

Stillnote is experimental. [Release downloads](https://github.com/jxu-dev-c/Stillnote/releases)
still need a separately installed speech runtime; use the source setup below to get started.

**Requirements:** Apple silicon Mac, macOS 15+, Xcode 26 or its Command Line Tools
(with the macOS 26 SDK), and Python 3.11–3.13 or `uv`.

```bash
git clone https://github.com/jxu-dev-c/Stillnote.git
cd Stillnote
./scripts/setup.sh
./scripts/start.sh
```

In **Settings**, download the speech model once (about 1.8 GB). Grant microphone
and screen/system audio permissions when prompted. For AI summaries, install and
sign in to the Codex or Claude Code CLI, then select it in Settings.

## Contributing

Bug reports, suggestions, and pull requests are welcome. Read the
[contributing guide](CONTRIBUTING.md), keep changes focused, and run
`./scripts/check.sh` before submitting a pull request. Use synthetic examples
instead of private meeting content.
