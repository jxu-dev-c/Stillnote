# Release preparation

User-facing installation notes live in [RELEASE-NOTES.md](RELEASE-NOTES.md).
Packaging substitutes the app version for `@VERSION@` and includes those notes
in the release assets and GitHub release body. Keep this maintainer checklist out
of the published release notes.

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

Releases use numeric `MAJOR.MINOR.PATCH` versions and `vMAJOR.MINOR.PATCH` Git tags,
following [Semantic Versioning](https://semver.org/). Major version zero denotes
initial development. Use patch increments for fixes and minor increments for new
features; reserve 1.0.0 for a stable public compatibility contract. Do not reuse or
move published tags, or add `dev` suffixes to release versions.

To release, update `CFBundleShortVersionString` in `Resources/Info.plist`, commit
that change with the intended release contents, then create and push a matching
annotated tag (for example, `git tag -a v0.1.1 -m "Release v0.1.1"` followed by
`git push origin v0.1.1`). Choose a new version for each release.

Only tag pushes publish releases. Ordinary branch pushes still run CI checks.
The release workflow validates that the tag is numeric and matches the app version,
runs checks on macOS 26, builds an ad-hoc-signed Apple silicon app, and verifies the
extracted ZIP and checksum. The app's build number is the workflow run number;
the app version and archive filename use the numeric version from the tag.

Find downloads under [GitHub Releases](https://github.com/jxu-dev-c/Stillnote/releases).
Each release contains the app ZIP, `Install-Stillnote.sh`, `SHA256SUMS`, license, third-party notices, and
these release notes. Assets are uploaded to a draft first, then the complete release
is published automatically. Failed checks prevent publication. Reruns can finish an
incomplete draft; already published releases and their assets stay unchanged.

Releases are published with the tag as their title (for example, `v0.1.1`), without
the prerelease flag. GitHub determines the latest release automatically. Numeric
versioning does not remove the runtime requirements or distribution gates above.
No Apple account, signing secret, or notarization is required by this workflow.
Only the publication job receives `contents: write`.

For end-user installation and runtime setup, see [RELEASE-NOTES.md](RELEASE-NOTES.md).
Checksums remain part of automated release verification; users are not required to
run checksum commands or rebuild the downloaded app.
