# MOSS inference library for Stillnote

This directory contains the subset of the upstream Swift package used by
`StillnoteSpeechWorker`. See [UPSTREAM.md](UPSTREAM.md) for the source revision,
local patches, omitted features, and update procedure, and [LICENSE](LICENSE)
for the Apache-2.0 license.

Stillnote loads verified local model weights with `ModelLoader.load(directory:)`
and calls `MossModel.generate(audio:parameters:progress:)` with 16 kHz PCM audio.
The retained code includes model loading, audio/text inference, prompt construction,
and transcript parsing. Stillnote provides its own download, audio decoding,
transcription service, UI, and export implementations.

Run `./scripts/check.sh` from the repository root to build and test Stillnote.
The retained upstream configuration and parser tests live in this package's
`Tests/MossTranscribeDiarizeTests` directory.
