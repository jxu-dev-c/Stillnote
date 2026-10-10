# Third-party components

Stillnote's original code is MIT licensed. Third-party code and separately downloaded
model weights retain their upstream licenses.

- Nemotron speech runtime: soniqo/speech-swift (the `AudioCommon`, `MLXCommon`, `SpeechVAD`,
  and `NemotronStreamingASR` targets), Apache-2.0. The source revision and local patches are in
  Vendor/NemotronSpeech/UPSTREAM.md.
- Nemotron 3.5 ASR and Nemotron 3 Diarization weights: NVIDIA, OpenMDW-1.1. Stillnote
  downloads the CoreML INT8 conversions `aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8`
  and `aufklarer/Nemotron-3-Diarization-100M-CoreML-INT8`, which carry the same license.
- MLX Swift and MLX Swift LM: Apple, MIT.
- MLX Audio Swift: Blaizzy and contributors, MIT. The worker links its `MLXAudioVAD`
  product for Silero voice activity detection.
- Silero VAD weights: `mlx-community/silero-vad`, converted from `onnx-community/silero-vad`,
  itself derived from snakers4/silero-vad, which is MIT. The conversion repository declares
  no license of its own; the upstream MIT terms are the ones that apply.
- Swift Transformers, Hugging Face Swift, and Swift Jinja: Hugging Face and contributors,
  Apache-2.0. Their transitive dependencies retain their own notices.

Package.resolved pins the complete Swift dependency graph. The app includes upstream
license files under Contents/Resources/licenses. Model files are pinned by revision,
size, and SHA-256 in Sources/StillnoteCore/Resources/speech_models.json and downloaded
separately: the two Nemotron bundles above (about 750 MB together) and the 2.2 MB silence
detector, mlx-community/silero-vad. Python and Python packages are not distributed.
