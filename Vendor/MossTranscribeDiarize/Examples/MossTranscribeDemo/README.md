# MossTranscribeDemo

Minimal **macOS SwiftUI** demo for `MossTranscribeDiarize`.

## Run

From the `Swift/` package root (requires full Xcode / Metal):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# or: /Applications/Xcode-beta.app/Contents/Developer

swift run MossTranscribeDemo
```

The window embeds `TranscribeView`:

1. Choose a model variant (default **8-bit**) or paste a local path
   e.g. `../pretrained/mlx-moss-transcribe-diarize-8bit`
2. **Load Model**
3. Choose an audio/video file
4. **Transcribe** (optional: postprocess / burn ASS with ffmpeg)

## Notes

- This is an SPM executable App (`@main` + `WindowGroup`), not a full `.xcodeproj`.
- For Xcode: **File → Open** the parent `Swift/` folder as a package, then run the `MossTranscribeDemo` scheme.
- First load of a Hugging Face repo downloads weights; prefer a local converted checkpoint for offline demos.
