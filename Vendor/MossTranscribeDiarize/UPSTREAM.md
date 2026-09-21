# Vendored MOSS Swift package

Source: https://github.com/vanch007/mlx-MOSS-Transcribe-Diarize
Revision: d2546316f76e93947e8d99a17fb88652f8ad6ab2
Vendored Swift inference library; Apache-2.0 (see LICENSE).

Local patches:
- Pin mlx-audio-swift to 01dec7c9bdce3088a6b6b7ab9f2e403458195efb.
- Remove unused CLI/demo products, SwiftUI views, session/pipeline wrappers, web studio,
  benchmark runner, FFmpeg/subtitle tools, and their dedicated tests. Keep the model
  configuration and transcript parser tests; both support retained inference code.
- Read PCM files in bounded 30-second windows without retaining a complete waveform.
- Skip vocabulary projection during intermediate prefill; evaluate KV state explicitly.
- Pipeline greedy decoding; release prompt embeddings after prefill and synchronize on exit.
- Use bounded allocation reuse, stage timings, and projected memory-budget guards.
- Support 8-bit KV and 4-bit KV with the first/last two layers protected at 8-bit.
  Uniform 4-bit KV returned an empty transcript on a real speech fixture.
- Supply additive negative-infinity masks to the pinned quantized attention helper.
- Encode 30-second windows sequentially, evaluating each before releasing intermediate
  tensors. Concatenate their embeddings into one decoder context for stable speakers.
- Report encoding, prefill, and complete decoded prefixes during generation.
- Stream only complete Unicode deltas from accumulated token decoding.
- Check cancellation between encoder windows, prefill steps, and generated tokens.
- Bound generation by available context; reject output exhaustion and repeated
  128-token blocks instead of returning partial text as success.

The app uses ModelLoader.load(directory:) and the synchronous generation callback in a
short-lived signed Swift helper. The upstream application/tooling features are omitted from this vendor copy. Swift dependency versions are locked in the root Package.resolved.
Model weights download separately using Stillnote's revision/size/SHA-256 manifest.

Update procedure: compare this directory against the recorded upstream Swift/ tree,
carry forward only documented patches, resolve dependencies intentionally, and run
scripts/check.sh plus real packaged offline inference and cancellation verification.
