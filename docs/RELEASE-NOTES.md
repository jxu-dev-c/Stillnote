# Stillnote

Local meeting recording and transcription for **Apple silicon Macs running macOS 15 or newer**.

## Installation

**Speech transcription requires a separate setup step.** The ZIP does not include the Python runtime or speech model.

1. Download `Stillnote-@VERSION@-macos-arm64.zip` from the assets below.
2. Extract the ZIP and move **Stillnote.app** into **Applications**.
3. Open the app. If macOS blocks it, follow [Apple’s Open Anyway instructions](https://support.apple.com/en-gb/102445).
4. Set up transcription once using the steps below, then open **Settings (⌘,)** and download the speech model.

### Set up transcription

If transcription already works, skip this step. Otherwise, with Python 3.11–3.13 and Git installed, run the following to install the speech runtime:

```sh
git clone --branch v@VERSION@ --depth 1 https://github.com/jxu-dev-c/Stillnote.git
cd Stillnote
runtime="$HOME/Library/Application Support/Stillnote/venv-moss"
python3 -m venv "$runtime"
"$runtime/bin/python" -m pip install -r requirements-moss.lock ./sidecar
```

After the model download completes, recording and transcription work offline.

### If the app stalls when opening

Quit Stillnote. If `Install-Stillnote.sh` is included in this release, run:

```sh
bash ~/Downloads/Install-Stillnote.sh ~/Downloads/Stillnote-@VERSION@-macos-arm64.zip
```

It installs into `~/Applications`, backs up the previous app, and preserves your meetings and models.

## Current limitations

- The app is ad-hoc signed and is not notarized by Apple.
- Speech runtime and model installation are separate; this is not yet a standalone installation.
- Updates must be installed manually and may require granting capture permissions again.
- Optional AI summaries use your configured Codex or Claude Code CLI and may send transcript text to hosted models after your confirmation.
