# Vendored MOSS Swift package

Source: https://github.com/vanch007/mlx-MOSS-Transcribe-Diarize
Revision: d2546316f76e93947e8d99a17fb88652f8ad6ab2
Vendored Swift package; Apache-2.0 (see LICENSE).

Local patches:
- Pin mlx-audio-swift to 01dec7c9bdce3088a6b6b7ab9f2e403458195efb; exclude the demo README from compilation.
- Encode 30-second windows sequentially, evaluating each before releasing intermediate
  tensors. Concatenate their embeddings into one decoder context for stable speakers.
- Report encoding, prefill, and complete decoded prefixes during generation.
- Stream only complete Unicode deltas from accumulated token decoding.
- Check cancellation between encoder windows, prefill steps, and generated tokens.
- Bound generation by available context; reject output exhaustion and repeated
  128-token blocks instead of returning partial text as success.

The app uses ModelLoader.load(directory:) and the synchronous generation callback in a
short-lived signed Swift helper. The upstream CLI, web studio, and FFmpeg features are
not invoked or packaged. Swift dependency versions are locked in the root Package.resolved.
Model weights download separately using Stillnote's revision/size/SHA-256 manifest.

Update procedure: compare this directory against the recorded upstream Swift/ tree,
carry forward only documented patches, resolve dependencies intentionally, and run
scripts/check.sh plus real packaged offline inference and cancellation verification.
