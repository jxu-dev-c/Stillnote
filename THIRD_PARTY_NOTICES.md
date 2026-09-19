# Third-party components

The MIT license covers Stillnote's original code only. Model weights, Python, MLX,
MLX Audio, Transformers, and their transitive dependencies retain their upstream licenses.

The runtime dependency inventory is pinned in `requirements-moss.lock`. MOSS model files
are pinned in `Sources/StillnoteCore/Resources/speech_models.json`.
Before redistributing a runtime, collect the license texts and notices from every built
wheel and the standalone Python distribution, and verify the pinned model's license.
This document is an inventory entry point, not a completed redistribution audit.
