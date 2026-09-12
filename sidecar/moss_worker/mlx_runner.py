"""Apple Silicon MOSS adapter for the pinned MLX Audio runtime.

Keep one decoder context for the meeting. Only independent 30-second Whisper
encoder windows are batched separately; speaker identities never reset between
those windows. No model downloads or remote code are used by this adapter.

`run` returns MOSS's raw timestamped text. Parsing and speaker normalization live in
the Swift app so the transcript format is defined in exactly one place.
"""

from __future__ import annotations

import math
from pathlib import Path

PREFILL_STEP = 512
CACHE_BYTES = 256 * 1024**2
MAX_MEMORY_BYTES = 6 * 1024**3
DECODER_BITS = 8


def token_budget(duration: float, prompt_tokens: int, context_size: int) -> int:
    # Allow fast multilingual speech plus timestamp/speaker tokens, but don't
    # let a short/silent recording run on for 65,536 generated tokens.
    available = context_size - prompt_tokens - 1
    if available < 256:
        raise ValueError("This recording exceeds the MOSS context limit. Import a shorter recording.")
    return min(65536, available, max(2048, math.ceil(duration * 16) + 512))


def _prepare_audio(model, audio, prompt, progress):
    import mlx.core as mx
    import numpy as np

    extractor = model._feature_extractor
    window = int(extractor.n_samples)
    count = math.ceil(len(audio) / window)
    encoded_parts, audio_tokens = [], 0
    for index, start in enumerate(range(0, len(audio), window)):
        chunk = audio[start : start + window]
        length = model._compute_audio_token_length(len(chunk))
        features = extractor(
            chunk, sampling_rate=model.sample_rate, padding="max_length", return_tensors="np"
        )["input_features"]
        features = mx.array(features.transpose(0, 2, 1)).astype(
            model.model.whisper_encoder.conv1.weight.dtype
        )
        encoded = model.model.get_audio_features(
            features, mx.array([length], dtype=mx.int32), mx.array([0], dtype=mx.int32)
        )[0]
        # Eagerly materialize each small result so lazy graphs don't retain the
        # attention matrices for all encoder windows at once.
        mx.eval(encoded)
        encoded_parts.append(encoded)
        audio_tokens += length
        del features
        mx.clear_cache()
        progress(10 + 30 * (index + 1) / count, f"Encoding audio on Apple GPU · {index + 1}/{count}")

    input_ids = model._build_prompt(audio_tokens, prompt)[0]
    embeddings = model.model.language_model.embed_tokens(input_ids)
    audio_embeddings = mx.concatenate(encoded_parts, axis=1)[0].astype(embeddings.dtype)
    positions = np.flatnonzero(np.array(input_ids) == model.config.audio_token_id)
    if len(positions) != audio_embeddings.shape[0]:
        raise RuntimeError("MOSS audio tokens and encoded features do not match.")
    embeddings[mx.array(positions, dtype=mx.uint32)] = audio_embeddings
    mx.eval(embeddings)
    return input_ids, embeddings


def run(path: Path, audio, language, speaker_count, progress):
    try:
        return _run(path, audio, language, speaker_count, progress)
    except RuntimeError as error:
        if "memory" in str(error).lower() or "alloc" in str(error).lower():
            raise RuntimeError(
                "MOSS reached the Apple GPU memory budget. Import a shorter recording or close other GPU apps."
            ) from error
        raise


def _run(path: Path, audio, language, speaker_count, progress):
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_audio.lm.generate import generate_step
    from mlx_audio.stt.utils import load_model

    if not mx.metal.is_available():
        raise RuntimeError("The Apple GPU is unavailable. Use the PyTorch backend or check MLX setup.")
    recommended = mx.device_info()["max_recommended_working_set_size"]
    memory_limit = min(MAX_MEMORY_BYTES, int(recommended * 0.7))
    mx.set_memory_limit(memory_limit)
    mx.set_cache_limit(CACHE_BYTES)
    mx.reset_peak_memory()
    progress(8, "Loading MOSS with MLX on Apple GPU")
    # Passing a Path uses the already verified local checkpoint, bypassing Hub
    # resolution. Strict loading prevents partially loaded/random model weights.
    model = load_model(path, strict=True)
    nn.quantize(
        model,
        group_size=64,
        bits=DECODER_BITS,
        class_predicate=lambda name, layer: (
            hasattr(layer, "to_quantized") and model.model_quant_predicate(name, layer)
        ),
    )
    mx.eval(model.parameters())
    mx.clear_cache()
    prompt = (
        "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，"
        "正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"
    )
    if language not in ("auto", "", None):
        prompt += f" Audio language: {language}."
    if speaker_count:
        prompt += f" Expected speakers: {speaker_count}."
    input_ids, embeddings = _prepare_audio(model, audio, prompt, progress)
    duration = len(audio) / model.sample_rate
    limit = token_budget(duration, len(input_ids), model.config.text_config.max_position_embeddings)
    tokens = []
    ended = False
    eos = model._eos_token_ids()
    progress(40, "Processing the full meeting context on Apple GPU")
    generation = generate_step(
        prompt=input_ids,
        input_embeddings=embeddings,
        model=model,
        max_tokens=limit,
        prefill_step_size=PREFILL_STEP,
        prompt_progress_callback=lambda done, total: progress(
            40 + 15 * done / max(total, 1), f"Processing meeting context · {done}/{total} tokens"
        ),
    )
    try:
        for token, _ in generation:
            if int(token) in eos:
                ended = True
                break
            tokens.append(int(token))
            if len(tokens) % 32 == 0:
                # Decode the complete token sequence, not each token separately:
                # byte-split Unicode tokens otherwise corrupt non-English text.
                text = model._tokenizer.decode(tokens, skip_special_tokens=True)
                import re

                timestamps = re.findall(r"\[([0-9]+(?:\.[0-9]+)?)\]", text)
                elapsed = min(duration, max(map(float, timestamps), default=0))
                progress(
                    55 + 40 * elapsed / max(duration, 1),
                    f"Transcribing on Apple GPU · {int(elapsed)} / {int(duration)} seconds",
                )
                if len(tokens) >= 384 and tokens[-128:] == tokens[-256:-128] == tokens[-384:-256]:
                    raise RuntimeError(
                        "MOSS began repeating its output. Your recording is saved; retry transcription."
                    )
        if not ended:
            raise RuntimeError(
                "MOSS reached its output limit. Import a shorter recording; no partial transcript was saved."
            )
        return model._tokenizer.decode(tokens, skip_special_tokens=True).strip()
    finally:
        generation.close()
        mx.synchronize()
        mx.clear_cache()
