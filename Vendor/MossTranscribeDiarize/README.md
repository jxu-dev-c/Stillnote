# MossTranscribeDiarize (Swift)

Swift Package for full on-device **MLX** use of this project on Apple Silicon.

Python remains the complete project surface (HF/vLLM backends, convert/quantize/upload). Swift **adds** a native path with runtime feature parity for MLX inference, subtitles, burn-in, benchmark, and local studio.

Architecture references [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift).

## Feature matrix

| Feature | Python | Swift |
|---|:---:|:---:|
| MLX load FP / 8bit / 4bit | ✅ | ✅ `ModelLoader` |
| Transcribe + diarize timestamps | ✅ | ✅ `MossModel` / `TranscribePipeline` |
| Prompt + hotwords | ✅ | ✅ `GenerateParameters` / `PromptBuilder` |
| top-p / top-k / temperature | ✅ | ✅ |
| Streaming tokens | ✅ | ✅ `generateStream` |
| Transcript parser | ✅ | ✅ `TranscriptStreamParser` |
| Subtitle JSON / SRT / ASS | ✅ | ✅ `SubtitleExport` |
| Subtitle postprocess | ✅ | ✅ `SubtitlePostprocess` |
| FFmpeg video size + ASS burn-in | ✅ | ✅ `FFmpegTools` |
| Full job artifacts (`raw`/`segments`/`srt`/`ass`/`mp4`) | ✅ | ✅ `TranscribePipeline` |
| CLI | ✅ `mtd-mlx` / `mtd-subtitle` | ✅ `moss-transcribe` |
| Local web studio | ✅ `mtd-subtitle-web` | ✅ `moss-transcribe serve` / `LocalStudioServer` |
| SwiftUI studio | — | ✅ `TranscribeView` |
| SGLang-shaped benchmark | ✅ | ✅ `moss-transcribe bench` |
| HF / vLLM backends | ✅ | — (MLX only) |
| Convert HF → MLX / quantize / upload | ✅ | — (maintainer, Python) |

## Requirements

- macOS 14+ (Apple Silicon recommended) or iOS 17+
- **Full Xcode** (Metal toolchain) — not Command Line Tools alone
- Optional: `ffmpeg` + `ffprobe` for `--render` / burn-in

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Layout

```text
Swift/
  Package.swift
  Sources/MossTranscribeDiarize/
    Model/          # config, Whisper, Qwen3, quantize loader, sampling
    Transcript/     # streaming parser
    Subtitle/       # export + postprocess
    FFmpeg/         # detect / probe / burn
    Pipeline/       # prompt + full job runner
    Benchmark/      # raw/speed/evaluation JSON
    Web/            # LocalStudioServer
    Session/        # @Observable Transcriber
    UI/             # TranscribeView, SegmentRowView
  Sources/MossTranscribeCLI/
  Tests/
```

## CLI

```bash
cd Swift
swift build
swift test

# Same role as mtd-mlx / mtd-subtitle
swift run moss-transcribe /path/to/audio.wav \
  --model vanch007/mlx-MOSS-Transcribe-Diarize-8bit \
  --out-dir ../runs/swift_example \
  --max-new-tokens 2048 \
  --hotwords "OpenMOSS,MLX" \
  --postprocess

# Burn subtitles (needs ffmpeg)
swift run moss-transcribe /path/to/video.mp4 \
  --model ../pretrained/mlx-moss-transcribe-diarize-8bit \
  --out-dir ../runs/swift_render \
  --render

# Benchmark (raw_asr_results / speed_results / evaluation)
swift run moss-transcribe bench \
  --model vanch007/mlx-MOSS-Transcribe-Diarize-8bit \
  --input ../runs/qwen3_forced_aligner_benchmark_manifest.json \
  --out-dir ../runs/swift_bench

# Local web studio (Python mtd-subtitle-web equivalent, MLX-only)
swift run moss-transcribe serve --port 7860 --model vanch007/mlx-MOSS-Transcribe-Diarize-8bit
# open http://127.0.0.1:7860
```

## Library

```swift
import MossTranscribeDiarize

let model = try await ModelLoader.load("vanch007/mlx-MOSS-Transcribe-Diarize-8bit")

let parameters = GenerateParameters(
    maxTokens: 2048,
    temperature: 0,
    topP: 1,
    hotwords: ["OpenMOSS", "MLX"]
)

// One-shot artifacts like mtd-mlx
let artifacts = try TranscribePipeline(model: model).run(
    inputURL: audioURL,
    outDirectory: outDir,
    options: PipelineOptions(
        parameters: parameters,
        postprocessSubtitles: true,
        burnSubtitles: false
    )
)
print(artifacts.result.text)
print(artifacts.srtURL.path)
```

### SwiftUI

```swift
import SwiftUI
import MossTranscribeDiarize

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup { TranscribeView() }
    }
}
```

### Minimal Demo App (included)

```bash
cd Swift
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run MossTranscribeDemo
```

Sources: [`Examples/MossTranscribeDemo/`](Examples/MossTranscribeDemo/).

## Models

| Variant | Repo |
|---|---|
| FP | `vanch007/mlx-MOSS-Transcribe-Diarize` |
| 8bit (default) | `vanch007/mlx-MOSS-Transcribe-Diarize-8bit` |
| 4bit | `vanch007/mlx-MOSS-Transcribe-Diarize-4bit` |

Quantization keeps `model.whisper_encoder` and `model.vq_adaptor` full precision (same as Python).

## Credits

- Model: OpenMOSS MOSS-Transcribe-Diarize
- Patterns: [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
- Runtime: MLX Swift, swift-transformers, swift-huggingface

## License

Same as the parent repository.
