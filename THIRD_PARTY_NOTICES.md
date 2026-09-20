# Third-party components

Stillnote's original code is MIT licensed. Third-party code and separately downloaded
model weights retain their upstream licenses.

- MOSS native Swift implementation: vanch007/mlx-MOSS-Transcribe-Diarize, Apache-2.0.
  The source revision and local patches are in Vendor/MossTranscribeDiarize/UPSTREAM.md.
- MLX Swift and MLX Swift LM: Apple, MIT.
- MLX Audio Swift: Blaizzy and contributors, MIT.
- Swift Transformers, Hugging Face Swift, and Swift Jinja: Hugging Face and contributors,
  Apache-2.0. Their transitive dependencies retain their own notices.

Package.resolved pins the complete Swift dependency graph. The app includes upstream
license files under Contents/Resources/licenses. Model files are pinned by revision,
size, and SHA-256 in Sources/StillnoteCore/Resources/speech_models.json and downloaded
separately. The checkpoint is vanch007/mlx-MOSS-Transcribe-Diarize-8bit, derived from
OpenMOSS MOSS-Transcribe-Diarize. Python and Python packages are not distributed.
