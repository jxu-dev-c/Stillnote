import pytest

from moss_worker import mlx_runner as moss_mlx


def test_generation_budget_scales_with_audio_but_respects_context():
    assert moss_mlx.token_budget(3, 128, 131072) == 2048
    assert moss_mlx.token_budget(60, 900, 131072) == 2048
    assert moss_mlx.token_budget(600, 8000, 131072) == 10112
    assert moss_mlx.token_budget(5400, 70000, 131072) == 61071
    with pytest.raises(ValueError, match="context limit"):
        moss_mlx.token_budget(60, 999, 1024)


def test_encoder_batches_are_bounded_without_splitting_decoder_context(monkeypatch):
    import sys
    from types import SimpleNamespace

    import numpy as np

    calls = []
    prompts = []

    class Extractor:
        n_samples = 30 * 16000

        def __call__(self, chunk, **kwargs):
            assert len(chunk) <= self.n_samples
            calls.append(len(chunk))
            return {"input_features": np.zeros((1, 80, 3000), dtype=np.float32)}

    def encode(features, lengths, mapping):
        assert features.shape == (1, 3000, 80)
        assert mapping.tolist() == [0]
        return [np.full((1, int(lengths[0]), 4), len(calls), dtype=np.float32)]

    def build_prompt(count, prompt):
        prompts.append(count)
        return np.array([[1] + [99] * count + [2]], dtype=np.int32)

    model = SimpleNamespace(
        _feature_extractor=Extractor(),
        sample_rate=16000,
        _compute_audio_token_length=lambda size: (size - 1) // 1280 + 1,
        _build_prompt=build_prompt,
        config=SimpleNamespace(audio_token_id=99),
        model=SimpleNamespace(
            whisper_encoder=SimpleNamespace(conv1=SimpleNamespace(weight=np.zeros(1, dtype=np.float32))),
            get_audio_features=encode,
            language_model=SimpleNamespace(
                embed_tokens=lambda ids: np.zeros((len(ids), 4), dtype=np.float32)
            ),
        ),
    )
    fake_mx = SimpleNamespace(
        array=np.array,
        int32=np.int32,
        uint32=np.uint32,
        eval=lambda *a: None,
        clear_cache=lambda: None,
        concatenate=np.concatenate,
    )
    monkeypatch.setitem(sys.modules, "mlx", SimpleNamespace(core=fake_mx))
    monkeypatch.setitem(sys.modules, "mlx.core", fake_mx)
    ids, embeddings = moss_mlx._prepare_audio(model, np.zeros(61 * 16000), "prompt", lambda *a: None)
    assert calls == [480000, 480000, 16000]
    assert prompts == [763]  # One full-context prompt, never three separate transcripts.
    assert len(ids) == 765
    assert embeddings[1, 0] == 1
    assert embeddings[376, 0] == 2
    assert embeddings[751, 0] == 3
