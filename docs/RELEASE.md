# Release preparation

Candidate releases target the repository containing the workflow, currently
`jxu-dev-c/Stillnote`: Apple silicon, macOS 15+. Standalone public distribution
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

## Automatic GitHub releases

Every push to `master` runs checks on macOS 26, builds an ad-hoc-signed Apple silicon
app, verifies the extracted ZIP and checksum, then publishes a visible GitHub
prerelease. Each push gets a unique tag, `v<app-version>-dev.<workflow-run-number>`,
pointing at the exact built commit. The app's build number is the workflow run number;
the marketing version remains `CFBundleShortVersionString` from `Resources/Info.plist`.
No version-bump commit is needed for each push.

Find downloads under [GitHub Releases](https://github.com/jxu-dev-c/Stillnote/releases).
Each release contains the app ZIP, `Install-Stillnote.sh`, `SHA256SUMS`, license, third-party notices, and
these release notes. Assets are uploaded to a draft first, then the complete release
is published automatically. Failed checks prevent publication. Reruns can finish an
incomplete draft; already published releases and their assets stay unchanged.

Strict `vX.Y.Z` tag pushes also publish development prereleases, after checking the
tag matches the app's marketing version. Automatic tags created with the workflow's
GitHub token do not trigger another release run. No Apple account, signing secret,
or notarization is required. Only the publication job receives `contents: write`.
These development builds are marked as prereleases, not stable/latest releases.

Download the ZIP, `Install-Stillnote.sh`, and `SHA256SUMS` into the same directory, run
`shasum -a 256 -c SHA256SUMS`, extract the ZIP, and move `Stillnote.app` to Applications.
Follow Apple's Open Anyway instructions above when required. This is a development
candidate: transcription requires the separate Python/MOSS runtime. From a checkout
of the same release tag, run `./scripts/setup.sh` (requires the development tools in
the README), then download the speech model in Settings. The ZIP does not install
that runtime, bundle model weights, or provide automatic updates.

### Personal installation when Open Anyway stalls

These ad-hoc builds are intended for personal development. On some Macs the
downloaded copy can stall before entering app code even after Open Anyway. After
verifying the checksums above, quit Stillnote and run the downloaded installer:

```sh
bash ~/Downloads/Install-Stillnote.sh ~/Downloads/Stillnote-0.1.0-dev.2-macos-arm64.zip
```

Use the ZIP filename you downloaded. For older releases without the installer asset,
use `./scripts/install-app.sh ZIP_PATH` from this checkout.
The installer verifies the bundle signature,
makes a local copy without imported download metadata, and installs it in
`~/Applications`. It preserves the exact executable, saves the previous app as a
backup, and leaves meetings, models, and system security settings untouched.
This is a personal-install workaround; general distribution still requires
Developer ID signing and Apple notarization.
