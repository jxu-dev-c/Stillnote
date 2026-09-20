# Third-party components

The MIT license covers Stillnote's original code only. Model weights, Python, MLX,
MLX Audio, Transformers, and their transitive dependencies retain their upstream licenses.

The runtime dependency inventory is pinned in `requirements-moss.lock`. MOSS model files
are pinned in `Sources/StillnoteCore/Resources/speech_models.json`.
The Homebrew runtime archive retains the original dependency wheels, including their
upstream license files and package metadata. Installed copies retain those files in
`libexec/lib/python3.13/site-packages`. Python is installed separately by Homebrew and
is not redistributed in this archive. Model weights are downloaded separately in Settings.
This inventory does not replace the upstream licenses bundled with each dependency.

The tokenizers 0.23.2 wheel omits its Apache-2.0 license text. A copy from
https://github.com/huggingface/tokenizers/blob/v0.23.2/LICENSE is included at
`licenses/tokenizers-LICENSE` in the runtime archive and the formula's shared files.
Stillnote's worker is covered by the root MIT LICENSE included in the archive.
