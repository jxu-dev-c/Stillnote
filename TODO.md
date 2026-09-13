# TODO

## Native migration follow-up

Source and pitfalls: [native migration handoff](NATIVE_MIGRATION.md). These checks apply
to the Swift app; older web-app/native-helper validation does not close them.

- [ ] Decode WebM/Opus imports, which AVFoundation cannot open. Recordings saved by the retired browser recorder currently cannot be played or re-transcribed. Verify both playback and retranscription while preserving existing transcripts, summaries, and exports; the handoff suggests a PyAV decode fallback as one option.
- [ ] Ship a signed app bundle so capture permissions survive a rebuild. The build accepts `STILLNOTE_SIGNING_IDENTITY` and verifies the signature; this Mac currently has no valid signing identity. Verify grants across rebuilds once configured.
- [ ] Verify live capture in the native app: microphone, audible system audio, screen video on each display, pause/resume, and save. September 12 attempt was denied by macOS TCC before capture started; retry after granting capture access.
- [x] Verify a real Codex summary with synthetic content: adapter integration, app sharing confirmation, rendered decisions/actions, and persistence after relaunch passed September 12.
- [ ] Verify a real Claude Code summary. The installed CLI failed September 12 with API DNS error `ENOTFOUND`; retry after its configured endpoint resolves. Opt-in integration coverage is in `AgentIntegrationTests`.
- [x] Interactively verify detail, transcript, summary, context, settings, and recording/import setup. Fixed custom-model reset, playback completion state, failed notes saves, and ignored transcription defaults. Live recording controls remain under the hardware check above.

## Features

- [ ] Add a **Refine** button that uses AI to refine the transcript and title.
- [ ] -- for the refine feature, we should extract 专有名词 first, then ask AI to audit and rewrite based on context provided
- [ ] Add/Integrate basic meeting summaries using macOS built-in Apple Intelligence.
- [ ] Support speaker identity memory across meetings so a speaker identified in one meeting can be recognized or assigned in another.
- [ ] Allow email addresses and phone numbers to be added to speaker profiles.
