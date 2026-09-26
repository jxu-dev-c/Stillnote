# Agent guide

Use this file as a signpost. Read the relevant sources below rather than duplicating
their details here.

## Where to look

- Product behavior and installation: [README.md](README.md).
- Development setup and verification: [CONTRIBUTING.md](CONTRIBUTING.md) and
  [scripts/check.sh](scripts/check.sh).
- Module map, data contracts, and runtime behavior: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Build targets and dependencies: [Package.swift](Package.swift).
- App state and UI entry points: [AppModel.swift](Sources/Stillnote/AppModel.swift)
  and [StillnoteApp.swift](Sources/Stillnote/StillnoteApp.swift).
- Command interface and the published agent skill: the Command interface section of
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [skills/README.md](skills/README.md), and
  [scripts/check-skill.sh](scripts/check-skill.sh).
- Speech changes and benchmarks: [docs/TRANSCRIPTION-PERFORMANCE.md](docs/TRANSCRIPTION-PERFORMANCE.md)
  and [Vendor/MossTranscribeDiarize/UPSTREAM.md](Vendor/MossTranscribeDiarize/UPSTREAM.md).
- Privacy and security: [docs/PRIVACY.md](docs/PRIVACY.md) and [SECURITY.md](SECURITY.md).
- Packaging and publishing: [docs/RELEASE.md](docs/RELEASE.md).

## Working agreements

- Complete authorized work end to end; make routine, reversible decisions without confirmation.
- Treat suggestions as guidance and use judgment when choosing an implementation.
- Never name branches `codex/...`.
- Keep edits focused and preserve unrelated changes.
- Follow the verification guidance above; expand testing only for failures or unresolved concerns.
- Report the result concisely, including verification and remaining blockers.
- Keep this guide short; update the linked source when details change.
