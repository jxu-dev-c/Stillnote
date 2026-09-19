# Release preparation

Candidate releases target the repository containing the workflow, currently
`jxu-dev-c/meeting-note-app`: Apple silicon, macOS 15+. Standalone public distribution
remains subject to the gates below; publishing source history is a separate operation.

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

## GitHub draft releases

Update `CFBundleShortVersionString` in `Resources/Info.plist`, commit the change and
workflow, then push that commit before creating a matching version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Use the actual version being released. Only strict `vX.Y.Z` tags are accepted; a
version mismatch stops the workflow before building. The workflow runs the existing
checks on macOS 26, builds an ad-hoc-signed app, verifies the extracted ZIP, and
creates a draft prerelease in the same repository. No Apple account, signing secret,
or notarization is required. Only the publication job receives `contents: write`.

Find the draft under GitHub Releases. It contains the app ZIP, `SHA256SUMS`, license,
third-party notices, and these release notes. Review before publishing. Rerunning a
failed workflow replaces assets on its draft only; published releases are never
updated by the workflow. Use a new version tag for changes after publication.

Download the ZIP and `SHA256SUMS` into the same directory, run
`shasum -a 256 -c SHA256SUMS`, extract the ZIP, and move `Stillnote.app` to Applications.
Follow Apple's Open Anyway instructions above when required. This is a development
candidate: transcription requires the separate Python/MOSS runtime. From a checkout
of the same release tag, run `./scripts/setup.sh` (requires the development tools in
the README), then download the speech model in Settings. The ZIP does not install
that runtime, bundle model weights, or provide automatic updates.
