# Contributing

Stillnote targets Apple silicon, macOS 15+, and the macOS 26 SDK. End-user installation is documented in README.md.
Run `./scripts/check.sh` before proposing a change. Keep changes focused and include
regression coverage for behavior changes. Use synthetic recordings and transcripts in
issues, tests, screenshots, and pull requests; never include private meeting content.

Explain the problem, resulting behavior, and verification in each pull request.
Real model and provider integration tests are opt-in; providers may consume account usage.
Contributions are provided under the MIT license. Third-party code retains its own license.

## Source setup

Install Xcode 26 or its Command Line Tools with the macOS 26 SDK, plus `uv`
(or Python 3.11–3.13), then:

```sh
git clone https://github.com/jxu-dev-c/Stillnote.git
cd Stillnote
./scripts/setup.sh
./scripts/start.sh
```

Source setup installs test tools and the runtime into Application Support. If a
Homebrew runtime is also installed, select the source runtime explicitly while
working on the worker:

```sh
export STILLNOTE_MOSS_PYTHON="$HOME/Library/Application Support/Stillnote/venv-moss/bin/python"
```
