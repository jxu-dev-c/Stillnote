# Vendored Nemotron speech Swift package

Source: https://github.com/soniqo/speech-swift
Revision: cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa
Vendored Swift inference library; Apache-2.0 (see LICENSE).

Upstream is a monorepo of ~60 model targets whose package-level dependencies include
hummingbird, WhisperKit, and the MCP SDK. SwiftPM resolves every dependency a package
declares, not only those reachable from the products in use, so depending on it directly
would pull that whole graph into the root Package.resolved. This copy carries four targets
and two dependencies, both of which the root already locks.

Vendored targets:
- `AudioCommon` — shared value types (`TimedWord`, `DiarizedSegment`, `TranscriptionResult`),
  audio loading, logging.
- `MLXCommon` — MLX helpers shared by the MLX backends.
- `SpeechVAD` — Nemotron 3 Diarization CoreML and MLX backends, plus the Sortformer mel
  extraction and streaming-state machinery Nemotron 3 reuses.
- `NemotronStreamingASR` — Nemotron 3.5 ASR streaming CoreML and MLX backends, RNN-T greedy
  decoder, word boosting, SentencePiece tokenizer.

Local patches:
- Remove `MLXCommon/MetalBudget.swift`. It is the only `import Cmlx` in the vendored tree, and
  `Cmlx` is an internal mlx-swift target rather than a product. Nothing in these four targets
  references `MetalBudget`.
- Drop the remaining ~56 model targets, the CLI, server, SwiftUI views, and benchmark runners.

Stillnote uses only the local-directory loaders, so no vendored code reaches the network:
- `NemotronStreamingASRModel.fromLocal(bundleDir:computeUnits:progressHandler:)`
- `Nemotron3Diarizer.fromCoreMLDirectory(_:computeUnits:)`

The `fromPretrained` entry points and `AudioCommon/HuggingFaceDownloader.swift` are retained
unpatched so re-pinning stays mechanical. They are never called, and the worker process already
runs with `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, and `HF_HUB_DISABLE_TELEMETRY=1`
(`SpeechWorkerProcess.swift`). Model weights download separately through Stillnote's
revision/size/SHA-256 manifest. Swift dependency versions are locked in the root
Package.resolved.

Both runtimes serialize their own inference and are documented as unsafe for concurrent use, so
the worker confines each to one serial executor.

Update procedure: compare this directory against the recorded upstream `Sources/` tree for the
four targets, carry forward only the documented patches, resolve dependencies intentionally, and
run scripts/check.sh plus scripts/verify-native.py and real packaged offline inference and
cancellation verification.
