# Third-party components

Stillnote's original code is MIT licensed. Third-party code and separately downloaded
model weights retain their upstream licenses.

- MOSS native Swift implementation: vanch007/mlx-MOSS-Transcribe-Diarize, Apache-2.0.
  The source revision and local patches are in Vendor/MossTranscribeDiarize/UPSTREAM.md.
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
separately. The checkpoint is vanch007/mlx-MOSS-Transcribe-Diarize-8bit, derived from
OpenMOSS MOSS-Transcribe-Diarize; the 2.2 MB silence detector is mlx-community/silero-vad. Python and Python packages are not distributed.
