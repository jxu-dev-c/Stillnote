# Release preparation

Target: `jxu-dev-c/stillnote`, version 0.1.0, Apple silicon, macOS 15+.
Publication is a separate operation. Do not push the historical private repository.

## Required gates

- [ ] In-app runtime setup with progress, cancellation, repair, and rollback.
- [ ] Pinned relocatable Python runtime and dependency wheels, with verified hashes.
- [ ] Runtime manifest embedded in app and candidate runtime archived alongside it.
- [ ] Dependency/model license audit and redistribution notices complete.
- [ ] Clean-account installation without developer tools on macOS 15 and 26.
- [ ] Gatekeeper opening, setup, offline transcription, playback, export, and relaunch.
- [ ] Live microphone/system audio, video, pause/resume, and denied-permission checks.
- [ ] Review automated checks and source/history privacy audit findings.
- [ ] Configure private vulnerability reporting on the future public repository.

## Candidate app

Run `./scripts/package-app.sh` to build an ad-hoc-signed development candidate ZIP
and checksum. This candidate still requires the developer-installed speech runtime;
it is not the planned standalone release and must not be advertised as ready.

No notarization or auto-update is provided. Users must follow Apple's Open Anyway flow:
https://support.apple.com/en-gb/102445 . Updates may reset capture permission grants.
Do not recommend disabling Gatekeeper globally.

## Fresh history

Use `./scripts/export-source.py DESTINATION` after reviewing all intended source changes.
It exports tracked files and explicit release-preparation additions, excluding Git history
and generated/private local content, then creates one commit on main with the GitHub
noreply identity. The destination must not exist. Inspect the exported tree before publishing.
The existing private repository and remote remain untouched.
