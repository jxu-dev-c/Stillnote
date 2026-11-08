# Release preparation

User-facing installation notes live in [RELEASE-NOTES.md](RELEASE-NOTES.md).
Packaging substitutes the app version for `@VERSION@` and includes those notes
in the release assets and GitHub release body. Keep this maintainer checklist out
of the published release notes.

Candidate releases target the repository containing the workflow, currently
`jxu-dev-c/Stillnote`: Apple silicon, macOS 15+. Standalone public distribution
remains subject to the gates below; publishing source history is a separate operation.

## Required gates

- [ ] Native worker, `stillnote` command, Metal library, and dependency licenses bundled and signed.
- [ ] `stillnote` reports the release version, and the published skill matches the command catalog.
- [ ] Relocated app self-test and offline real-model inference pass.
- [ ] Dependency/model license audit and redistribution notices complete.
- [ ] Clean-account installation without developer tools on macOS 15 and 26.
- [ ] Gatekeeper opening, setup, offline transcription, playback, export, and relaunch.
- [ ] Live microphone/system audio, video, pause/resume, and denied-permission checks.
- [ ] Review automated checks and source/history privacy audit findings.
- [ ] Configure private vulnerability reporting on the future public repository.

## Candidate app

Run `./scripts/package-app.sh` to build a development candidate ZIP and checksum. It is
ad-hoc signed unless `STILLNOTE_SIGNING_IDENTITY` is set (see Release signing). The app ZIP
includes the native speech worker and Metal kernels. Only the verified model weights are
downloaded separately.

No notarization or auto-update is provided. Users must follow Apple's Open Anyway flow:
https://support.apple.com/en-gb/102445 . Do not recommend disabling Gatekeeper globally.

## Release signing

macOS keys microphone and screen/system audio grants on the app's designated requirement.
An ad-hoc signature's requirement is its own code hash, so every ad-hoc build looks like a new
app and loses its grants. Releases are therefore signed with one persistent self-signed
certificate, giving the requirement
`identifier "local.stillnote.app" and certificate leaf = H"<sha1>"` in every build. It needs no
Apple account and does not change Gatekeeper: the app is still not notarized.

- `packaging/signing/stillnote-release.cer` is the public certificate. It pins the identity:
  `./scripts/import-signing-identity.sh` refuses a secret holding a different certificate, and
  `./scripts/verify-candidate.sh` refuses a release that does not satisfy the pinned requirement.
- The private key lives only in the `STILLNOTE_SIGNING_P12_BASE64` and
  `STILLNOTE_SIGNING_P12_PASSWORD` Actions secrets and in an offline backup. A release fails
  when they are missing; merges that do not release build ad-hoc without them.
- `./scripts/create-signing-identity.sh OUTPUT_DIR` created it once. OUTPUT_DIR must be outside
  the repository; the script prints the `gh secret set` commands.

Never rotate the certificate casually. A new one changes the requirement, so every user must
grant capture permissions again, exactly once. If the key is lost or compromised, rerun the
generator with `STILLNOTE_ROTATE_SIGNING_IDENTITY=true`, commit the new certificate, replace both
secrets, and say in the release notes that permissions must be granted again.

To sign a local build with the release identity, export both secrets into the environment, then
`eval "$(./scripts/import-signing-identity.sh)"` before `./scripts/package-app.sh`. Remove the
temporary keychain afterwards with `security delete-keychain "$STILLNOTE_SIGNING_KEYCHAIN"`.

## Fresh history

Use `./scripts/export-source.py DESTINATION` after reviewing all intended source changes.
It exports tracked files and explicit release-preparation additions, excluding Git history
and generated/private local content, then creates one commit on main with the GitHub
noreply identity. The destination must not exist. Inspect the exported tree before publishing.
The existing private repository and remote remain untouched.

## Releasing

Releases use numeric `MAJOR.MINOR.PATCH` versions and `vMAJOR.MINOR.PATCH` Git tags,
following [Semantic Versioning](https://semver.org/). Major version zero denotes
initial development. Use patch increments for fixes and minor increments for new
features; reserve 1.0.0 for a stable public compatibility contract. Do not reuse or
move published tags, or add `dev` suffixes to release versions.

`CFBundleShortVersionString` in `Resources/Info.plist` is the release trigger. A release is
one pull request that bumps it, closes the changelog's Unreleased section, and updates
`docs/RELEASE-NOTES.md`. Merging that pull request to `master` publishes the release end to
end; no tag is created by hand. A merge that leaves the version alone only runs the checks.

The Release workflow on a `master` push:

1. Validates the version, and decides whether `v$version` is already released.
2. Runs `./scripts/check.sh`, imports the release signing identity, builds the signed Apple
   silicon app with `./scripts/package-app.sh`, generates the cask, and runs
   `./scripts/verify-candidate.sh` against the extracted ZIP, its checksums, and the pinned
   signing certificate.
3. Installs, upgrades, and uninstalls the candidate cask on macOS 15 and 26
   (`./scripts/check-homebrew.sh`).
4. Publishes the GitHub release, which creates the tag on the released commit, then advances
   the public Homebrew tap.

Steps 3 and 4 run only for a new version. Failed checks prevent publication, and the tap is
never advanced for a candidate that did not pass. The app version and archive filename come
from `Resources/Info.plist`; the build number is the workflow run number. Releases are titled
with their tag (for example, `v0.1.1`), without the prerelease flag, so GitHub determines the
latest release automatically. Only the publication job receives `contents: write`. No Apple
account or notarization is required; signing uses the self-signed identity above.

Find downloads under [GitHub Releases](https://github.com/jxu-dev-c/Stillnote/releases).
Each release contains the app ZIP, `Install-Stillnote.sh`, `SHA256SUMS`, license,
third-party notices, and the release notes. Checksums remain part of automated release
verification; users are not required to run checksum commands or rebuild the downloaded app.

Numeric versioning does not remove the runtime requirements or distribution gates above.
For end-user installation and runtime setup, see [RELEASE-NOTES.md](RELEASE-NOTES.md).

## Homebrew releases

The source repository and agent skill are public. Public binary downloads live in
`jxu-dev-c/homebrew-stillnote` releases; never point public formula URLs at private assets.
The tap is what `brew install` reads, so a source release without it ships a version nobody
can install, and the publication job fails rather than skipping the tap quietly.

Packaging builds `Stillnote-homebrew.tar.gz` containing the app cask. Full Xcode and its Metal
toolchain build the worker and `mlx.metallib`; no Python runtime archive is produced. The
archive carries upstream licenses and `Package.resolved` pins the Swift dependency graph.
The cask, its URLs, and the tap README come from `packaging/homebrew/`.

Publication needs the `HOMEBREW_TAP_TOKEN` Actions secret: a token with contents write access
to `jxu-dev-c/homebrew-stillnote` and read access to this repository, because the workflow's
own `github.token` is scoped to this repository alone.

A maintainer with `gh` access to both repositories can republish or backfill the tap for an
already published tag without rebuilding, which downloads that release's own assets:

```sh
./scripts/publish-homebrew.sh v0.6.0
```

Existing published assets are immutable, and reruns must match their checksums. Real GPU
transcription and Finder first-launch approval still require acceptance testing. Quit
Stillnote before testing app upgrades.

To package locally, use full Xcode with the Metal toolchain; cask generation uses Python 3:

```sh
./scripts/package-app.sh
python3 scripts/prepare-homebrew.py
```

The Homebrew lifecycle script is restricted to disposable CI runners because it installs
and removes the app. Local unit and worker checks remain in `./scripts/check.sh`.

The app cask has no dependency on the legacy `stillnote-runtime` formula. Existing
legacy installations are left alone so older app versions can still use them.
