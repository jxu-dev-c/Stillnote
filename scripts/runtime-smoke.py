"""Exercise the native runtime without downloading a model or accessing user data."""
import jinja2
import mlx.core as mx
import numpy as np
import transformers
from mlx_audio.lm.generate import generate_step
from mlx_audio.stt.utils import load_model
from moss_worker.mlx_runner import token_budget

assert transformers.__version__.split(".")[0] == "5"
assert jinja2.Template("{{ value }}").render(value="ok") == "ok"
assert np.array([1, 2]).sum() == 3
assert token_budget(1, 1, 4096) > 0
assert callable(generate_step) and callable(load_model)
# Hosted macOS runners may not expose a GPU. Native CPU computation still checks
# the installed MLX extension; real GPU transcription is a separate acceptance check.
mx.set_default_device(mx.cpu)
result = mx.array([1.0, 2.0]) + 1
mx.eval(result)
assert result.tolist() == [2.0, 3.0]
print("Stillnote runtime imports and native computation passed")
