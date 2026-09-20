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
