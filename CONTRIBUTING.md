# Contributing

Stillnote targets Apple silicon, macOS 15+, and the macOS 26 SDK. End-user installation is documented in README.md.
Run `./scripts/check.sh` before proposing a change; it builds, tests, and validates the published skills under `skills/`. Keep changes focused and include
regression coverage for behavior changes. Use synthetic recordings and transcripts in
issues, tests, screenshots, and pull requests; never include private meeting content.

Explain the problem, resulting behavior, and verification in each pull request.
Real model and provider integration tests are opt-in; providers may consume account usage.
Contributions are provided under the MIT license. Third-party code retains its own license.

## Source setup

Install full Xcode 26 with Swift 6.2 or newer, select it with `xcode-select`, and install
its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`). Command Line Tools
alone cannot build the MLX kernels. Then:

```sh
git clone https://github.com/jxu-dev-c/Stillnote.git
cd Stillnote
./scripts/setup.sh
./scripts/start.sh
```

`./scripts/check.sh` builds the native worker and Metal library and runs Swift tests.
`STILLNOTE_INTEGRATION=1 ./scripts/check.sh` also runs real local inference tests
against the downloaded model. No Python speech environment is used. Python 3 is
needed only for maintainer utilities such as generating the Homebrew cask.

After `./scripts/package-app.sh` and the model download, run `python3 scripts/verify-native.py`
for packaged acceptance: synthetic short/two-speaker audio, signatures, library paths,
network/checkout/child-process denial, app diagnostics, and service cancellation.
Logs and timing/memory measurements are written under `build/native-validation/`.
