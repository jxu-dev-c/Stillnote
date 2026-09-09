"""Verified local speech models with native speaker attribution and isolated inference."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import math
import os
import platform
import re
import subprocess
import sys
import tempfile
import threading
import urllib.request
from collections.abc import Callable
from pathlib import Path

Progress = Callable[[float, str], None]
SAMPLE_RATE = 16_000
DEFAULT_MODEL = "moss-0.9b"
MODELS = json.loads(Path(__file__).with_name("speech_models.json").read_text())
_INSTALL_LOCK = threading.Lock()
_STATE_LOCK = threading.Lock()
_INSTALL_STATES: dict[str, dict] = {}
_INFERENCE_LOCK = threading.Lock()
MEDIA_OPEN_OPTIONS = {
    "protocol_whitelist": "pipe",
    "format_whitelist": "wav,mp3,flac,ogg,matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,aiff,aac,asf,avi",
    "enable_drefs": "0",
    "use_absolute_path": "0",
}


def _deny_external_media(url: str, flags: int, options: dict):
    raise ValueError("Recordings must contain their own audio; external media references are disabled.")


def _decode_audio(audio_path: Path, sample_rate: int = SAMPLE_RATE):
    """Decode a self-contained local media file; refuse protocols and playlists."""
    import av
    import numpy as np

    raw = io.BytesIO()
    resampler = av.AudioResampler(format="s16", layout="mono", rate=sample_rate)
    # A file object bypasses URL interpretation. FFmpeg also gets a demuxer
    # allowlist, no network/file protocols, and a callback denying nested opens.
    with (
        Path(audio_path).open("rb") as source,
        av.open(
            source,
            mode="r",
            metadata_errors="ignore",
            options=MEDIA_OPEN_OPTIONS,
            io_open=_deny_external_media,
        ) as container,
    ):
        for frame in container.decode(audio=0):
            frame.pts = None
            for converted in resampler.resample(frame):
                raw.write(converted.to_ndarray().tobytes())
        for converted in resampler.resample(None):
            raw.write(converted.to_ndarray().tobytes())
    return np.frombuffer(raw.getbuffer(), dtype=np.int16).astype(np.float32) / 32768.0


def _spec(model_name: str) -> dict:
    if model_name not in MODELS:
        raise ValueError(f"Unsupported transcription model. Choose one of: {', '.join(MODELS)}.")
    return MODELS[model_name]


def _model_path(model_dir: Path, model_name: str) -> Path:
    _spec(model_name)
    return Path(model_dir) / "speech" / model_name


def _has_size(path: Path, size: int) -> bool:
    try:
        return path.is_file() and path.stat().st_size == size
    except OSError:
        return False


def _installed(model_dir: Path, model_name: str) -> bool:
    path = _model_path(model_dir, model_name)
    spec = _spec(model_name)
    try:
        if (path / ".verified").read_text() != spec["revision"]:
            return False
    except OSError:
        return False
    return all(_has_size(path / name, file["size"]) for name, file in spec["files"].items())


def _moss_python() -> Path:
    return (
        Path(__file__).resolve().parents[2]
        / ".venv-moss"
        / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    )


def _moss_runtime_ready() -> bool:
    root = _moss_python().parent.parent
    sites = list(root.glob("lib/python*/site-packages")) + [root / "Lib/site-packages"]
    return _moss_python().is_file() and any(
        list(site.glob("transformers-5*.dist-info"))
        and all(
            (site / module).is_dir()
            for module in (
                ("mlx", "mlx_audio", "av", "numpy")
                if _moss_backend() == "mlx"
                else ("torch", "av", "numpy", "librosa")
            )
        )
        for site in sites
    )


def speech_status(model_dir: Path, model_name: str = DEFAULT_MODEL) -> dict:
    spec = _spec(model_name)
    installed = _installed(model_dir, model_name)
    dependencies = ["torch", "transformers", "numpy", "av", "librosa"]
    if model_name.startswith("vibevoice"):
        dependencies.append("vibevoice")
    missing = [name for name in dependencies if importlib.util.find_spec(name) is None]
    if model_name == DEFAULT_MODEL and not _moss_runtime_ready():
        missing.append("MOSS runtime (.venv-moss)")
    with _STATE_LOCK:
        state = dict(_INSTALL_STATES.get(str(Path(model_dir).resolve()), {}))
    engine = (
        "MLX · Apple GPU · 8-bit decoder"
        if model_name == DEFAULT_MODEL and _moss_backend() == "mlx"
        else "PyTorch"
    )
    detail = f"{spec['name']} is ready for local transcription and speaker detection. {engine}."
    if missing:
        detail = "Install the Python speech dependencies with the project setup script."
    elif not installed:
        detail = "Download the speech models once in Settings to enable offline transcription."
    if state.get("installing"):
        detail = state["detail"]
    return {
        "ready": installed and not missing,
        "transcription_ready": installed,
        "diarization_ready": installed,
        "dependencies_ready": not missing,
        "missing_dependencies": missing,
        "model": model_name,
        "engine": engine,
        "installing": state.get("installing", False),
        "installing_model": state.get("model"),
        "progress": state.get("progress", 0),
        "error": state.get("error"),
        "detail": detail,
        "models": [
            {
                "id": name,
                "name": item["name"],
                "tier": item["tier"],
                "installed": _installed(model_dir, name),
                "download_mb": round(sum(f["size"] for f in item["files"].values()) / 1_000_000),
                "url": f"https://huggingface.co/{item['repo']}",
                "languages": "50+ languages" if name == DEFAULT_MODEL else "10 languages",
                "timing": "Model timestamps" if name == DEFAULT_MODEL else "Approximate chunk timestamps",
            }
            for name, item in MODELS.items()
        ],
        "diarization": "Built into the selected speech model",
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _download(
    url: str, destination: Path, size: int, sha256: str | None, progress: Callable[[float], None]
) -> None:
    """GET public model bytes only, atomically; partial/corrupt files stay unready."""
    if _has_size(destination, size) and (not sha256 or _sha256(destination) == sha256):
        progress(1)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "Stillnote-local-model-setup/1"})
    try:
        received = 0
        digest = hashlib.sha256()
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as target:
            if not response.geturl().startswith("https://"):
                raise RuntimeError("Model download redirected to an insecure URL.")
            while block := response.read(1024 * 1024):
                received += len(block)
                if received > size:
                    raise RuntimeError("Model download exceeded its expected size.")
                target.write(block)
                digest.update(block)
                progress(received / size)
        if received != size or (sha256 and digest.hexdigest() != sha256):
            raise RuntimeError("Model download failed verification. Please retry setup.")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def install_models(model_dir: Path, model_name: str, progress: Progress) -> None:
    """Only this explicit setup operation accesses Hugging Face."""
    spec = _spec(model_name)
    if not _INSTALL_LOCK.acquire(blocking=False):
        raise RuntimeError("A model download is already in progress.")
    root = Path(model_dir).resolve()
    key = str(root)

    def report(value: float, detail: str) -> None:
        with _STATE_LOCK:
            _INSTALL_STATES[key] = dict(
                installing=True, model=model_name, progress=value, detail=detail, error=None
            )
        progress(value, detail)

    try:
        report(0, "Downloading speech models. No recordings or transcripts are sent.")
        path = _model_path(root, model_name)
        path.mkdir(parents=True, exist_ok=True)
        (path / ".verified").unlink(missing_ok=True)
        total = sum(f["size"] for f in spec["files"].values())
        completed = 0
        for filename, file in spec["files"].items():
            size = file["size"]
            _download(
                f"https://huggingface.co/{spec['repo']}/resolve/{spec['revision']}/{filename}",
                path / filename,
                size,
                file["sha256"],
                lambda fraction, completed=completed, size=size, filename=filename: report(
                    (completed + fraction * size) / total * 99,
                    f"Downloading {spec['name']}: {filename}",
                ),
            )
            if filename.endswith(".json"):
                json.loads((path / filename).read_text())
            completed += size
        (path / ".verified").write_text(spec["revision"])
        report(100, "Speech model installed. Recording and transcription run locally.")
        with _STATE_LOCK:
            _INSTALL_STATES[key]["installing"] = False
    except Exception:
        with _STATE_LOCK:
            _INSTALL_STATES[key] = {
                **_INSTALL_STATES.get(key, {}),
                "installing": False,
                "error": "Model setup failed. Check your internet connection and free disk space, then retry.",
            }
        raise
    finally:
        _INSTALL_LOCK.release()


def _normalize_segments(rows: list[dict], duration: float) -> dict:
    labels, segments = {}, []
    for row in rows:
        start, end = float(row["start"]), float(row["end"])
        if not math.isfinite(start) or not math.isfinite(end) or end < start:
            raise RuntimeError("The model returned invalid timestamps. Please retry transcription.")
        text = str(row["text"]).strip()
        if not text:
            continue
        raw = str(row.get("speaker", "unknown"))
        if raw not in labels:
            labels[raw] = "speaker_unknown" if raw == "unknown" else f"speaker_{len(labels) + 1}"
        segments.append(
            dict(
                id=f"segment_{len(segments) + 1}",
                start=round(max(0, min(start, duration)), 3),
                end=round(max(0, min(end, duration)), 3),
                speaker=labels[raw],
                text=text,
            )
        )
    return {
        "segments": segments,
        "speakers": {
            v: ("Unknown speaker" if v == "speaker_unknown" else f"Speaker {i + 1}")
            for i, v in enumerate(labels.values())
        },
    }


def _parse_moss(text: str) -> list[dict]:
    pattern = r"\[([0-9.]+)\]\[(S\d+)\](.*?)\[([0-9.]+)\]"
    matches = list(re.finditer(pattern, text, re.DOTALL))
    if text.strip() and (not matches or re.sub(pattern, "", text, flags=re.DOTALL).strip()):
        raise RuntimeError("MOSS returned an incomplete transcript. Please retry transcription.")
    return [dict(start=float(m[1]), end=float(m[4]), speaker=m[2], text=m[3]) for m in matches]


def _moss_backend() -> str:
    default = "mlx" if sys.platform == "darwin" and platform.machine() == "arm64" else "torch"
    backend = os.environ.get("STILLNOTE_MOSS_BACKEND", default)
    if backend not in {"mlx", "torch"}:
        raise ValueError("STILLNOTE_MOSS_BACKEND must be mlx or torch.")
    return backend


def _run_moss(path, audio, language, speaker_count, progress):
    if _moss_backend() == "mlx":
        from .moss_mlx import run

        try:
            return run(path, audio, language, speaker_count, progress)
        except RuntimeError as error:
            if "memory" in str(error).lower() or "alloc" in str(error).lower():
                raise RuntimeError(
                    "MOSS reached the Apple GPU memory budget. Import a shorter recording or close other GPU apps."
                ) from error
            raise
    return _run_moss_torch(path, audio, language, speaker_count, progress)


def _run_moss_torch(path: Path, audio, language: str, speaker_count: int | None, progress: Progress):
    import torch
    from transformers import AutoModelForCausalLM, AutoProcessor
    from transformers.generation.streamers import BaseStreamer

    device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cpu":
        torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
    dtype = torch.bfloat16 if device == "cuda" else torch.float32
    processor = AutoProcessor.from_pretrained(
        str(path),
        trust_remote_code=True,
        local_files_only=True,
    )
    model = (
        AutoModelForCausalLM.from_pretrained(
            str(path),
            trust_remote_code=True,
            local_files_only=True,
            dtype=dtype,
            attn_implementation="sdpa",
        )
        .to(device)
        .eval()
    )
    prompt = "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"
    if language not in ("auto", "", None):
        prompt += f" Audio language: {language}."
    if speaker_count:
        prompt += f" Expected speakers: {speaker_count}."
    messages = [
        {
            "role": "user",
            "content": [{"type": "audio", "audio": "local.wav"}, {"type": "text", "text": prompt}],
        }
    ]
    text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=text, audio=[audio], return_tensors="pt").to(device)
    if "input_features" in inputs:
        inputs["input_features"] = inputs["input_features"].to(dtype)
    progress(20, "Transcribing and identifying speakers locally with MOSS")

    class TokenProgress(BaseStreamer):
        def __init__(self):
            self.prompt_seen = False
            self.count = 0

        def put(self, value):
            if not self.prompt_seen:
                self.prompt_seen = True
                return
            self.count += value.numel()
            if self.count % 32 == 0:
                progress(20, f"Transcribing locally with MOSS · {self.count} tokens generated")

        def end(self):
            pass

    with torch.inference_mode():
        output = model.generate(**inputs, max_new_tokens=65536, do_sample=False, streamer=TokenProgress())
    generated = output[0][inputs["input_ids"].shape[1] :]
    if len(generated) >= 65536:
        raise RuntimeError("The transcript exceeded the model output limit. Import a shorter recording.")
    return _parse_moss(processor.tokenizer.decode(generated, skip_special_tokens=True))


def _parse_vibe_chunk(text: str, start: float, end: float, previous_speaker: str):
    """Streaming output uses speaker/content fields; timing is the audio chunk interval."""
    if not text.strip():
        return [], previous_speaker
    pieces = re.split(r"Speaker\s+(\d+)\s*:", text)
    rows = []
    if pieces[0].strip():
        rows.append(dict(start=start, end=end, speaker=previous_speaker, text=pieces[0]))
    for index in range(1, len(pieces), 2):
        previous_speaker = pieces[index]
        if pieces[index + 1].strip():
            rows.append(dict(start=start, end=end, speaker=previous_speaker, text=pieces[index + 1]))
    return rows, previous_speaker


def _run_vibevoice(path: Path, audio, language: str, speaker_count: int | None, progress: Progress):
    import torch
    from vibevoice.modular.modeling_vibevoice_asr import VibeVoiceASRForConditionalGeneration
    from vibevoice.processor.vibevoice_asr_processor import VibeVoiceASRProcessor

    config = json.loads((path / "preprocessor_config.json").read_text())
    rate = config["target_sample_rate"]
    frame = config["speech_tok_compress_ratio"] / rate
    chunk_duration = config["chunk_frames"] * frame
    device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cpu":
        torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
    processor = VibeVoiceASRProcessor.from_pretrained(str(path), local_files_only=True)
    model = (
        VibeVoiceASRForConditionalGeneration.from_pretrained(
            str(path),
            local_files_only=True,
            dtype=torch.bfloat16 if device == "cuda" else torch.float32,
            attn_implementation="sdpa",
        )
        .to(device)
        .eval()
    )
    hints = []
    if language not in ("auto", "", None):
        hints.append(f"Audio language: {language}")
    if speaker_count:
        hints.append(f"Expected speakers: {speaker_count}")
    rows, speaker = [], "unknown"
    with torch.inference_mode():
        for index, total, text in model.streaming_generate(
            audio_tensor=torch.from_numpy(audio),
            tokenizer=processor.tokenizer,
            chunk_duration=chunk_duration,
            text_audio_delay=config["lookahead_frames"] * frame,
            sample_rate=rate,
            max_new_tokens_per_chunk=256,
            temperature=0,
            context_info=". ".join(hints) or None,
        ):
            chunk_rows, speaker = _parse_vibe_chunk(
                text, index * chunk_duration, (index + 1) * chunk_duration, speaker
            )
            rows.extend(chunk_rows)
            progress(20 + 75 * (index + 1) / max(total, 1), "Transcribing and identifying speakers locally")
    return rows


def _transcribe_in_process(
    audio_path: Path,
    model_dir: Path,
    model_name: str,
    language: str,
    speaker_count: int | None,
    progress: Progress,
) -> dict:
    spec = _spec(model_name)
    if speaker_count is not None and (type(speaker_count) is not int or not 1 <= speaker_count <= 20):
        raise ValueError("Speaker count must be between 1 and 20, or automatic.")
    status = speech_status(model_dir, model_name)
    if not status["ready"]:
        raise RuntimeError(status["detail"])
    if not Path(audio_path).is_file():
        raise ValueError("The local audio file could not be found.")
    import numpy as np

    path = _model_path(model_dir, model_name)
    rate = (
        SAMPLE_RATE
        if model_name == DEFAULT_MODEL
        else json.loads((path / "preprocessor_config.json").read_text())["target_sample_rate"]
    )
    with _INFERENCE_LOCK:
        progress(2, "Decoding the local audio file")
        try:
            audio = _decode_audio(audio_path, rate)
        except Exception as error:
            raise ValueError("Could not decode this audio. Try WAV, MP3, M4A, OGG, or WebM.") from error
        duration = len(audio) / rate
        if not duration or not np.isfinite(audio).all():
            raise ValueError("This recording contains no valid audio.")
        if duration > 90 * 60 and model_name == DEFAULT_MODEL:
            raise ValueError("MOSS supports recordings up to 90 minutes. Import a shorter recording.")
        if duration < 0.1 or np.max(np.abs(audio)) < 1e-5:
            return {"duration": duration, "language": language or "auto", "speakers": {}, "segments": []}
        progress(8, f"Loading {spec['name']} locally")
        runner = _run_moss if model_name == DEFAULT_MODEL else _run_vibevoice
        rows = runner(path, audio, language, speaker_count, progress)
        result = _normalize_segments(rows, duration)
        progress(100, "Local transcription complete")
        return {"duration": round(duration, 3), "language": language or "auto", **result}


class TranscriptionCancelled(RuntimeError):
    pass


def transcribe_audio(
    audio_path: Path,
    model_dir: Path,
    model_name: str,
    language: str,
    speaker_count: int | None,
    progress: Progress,
    cancel_event: threading.Event | None = None,
) -> dict:
    """Run native inference in a child process so a native crash cannot kill the app."""
    cancel_event = cancel_event or threading.Event()
    if cancel_event.is_set():
        raise TranscriptionCancelled("Transcription stopped.")
    _spec(model_name)
    if speaker_count is not None and (type(speaker_count) is not int or not 1 <= speaker_count <= 20):
        raise ValueError("Speaker count must be between 1 and 20, or automatic.")
    status = speech_status(model_dir, model_name)
    if not status["ready"]:
        raise RuntimeError(status["detail"])
    if not Path(audio_path).is_file():
        raise ValueError("The local audio file could not be found.")
    # An explicit module path works both in the editable development tree and in
    # an installed wheel, including when called from a FastAPI background thread.
    environment = dict(os.environ)
    package_root = str(Path(__file__).resolve().parent.parent)
    environment["PYTHONPATH"] = os.pathsep.join([package_root, environment.get("PYTHONPATH", "")]).rstrip(
        os.pathsep
    )
    environment.update(
        {
            "HF_HUB_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "ORT_DISABLE_TELEMETRY": "1",
            "TRANSFORMERS_OFFLINE": "1",
        }
    )
    if model_name == DEFAULT_MODEL and _moss_backend() == "mlx":
        environment["USE_TORCH"] = "0"
    command = [
        str(_moss_python()) if model_name == DEFAULT_MODEL else sys.executable,
        "-m",
        "meeting_app.speech_worker",
        str(Path(audio_path).resolve()),
        str(Path(model_dir).resolve()),
        model_name,
        language or "auto",
        str(speaker_count or 0),
    ]
    result = None
    error = None
    with _INFERENCE_LOCK, tempfile.TemporaryFile(mode="w+b") as stderr:
        if cancel_event.is_set():
            raise TranscriptionCancelled("Transcription stopped.")
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=stderr,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            env=environment,
        )
        finished = threading.Event()

        def watch_cancel():
            while not finished.wait(0.1):
                if cancel_event.is_set():
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            process.kill()
                    return

        watcher = threading.Thread(target=watch_cancel, daemon=True)
        watcher.start()
        try:
            assert process.stdout is not None
            for line in process.stdout:
                # Native libraries may print diagnostic lines. They are never
                # interpreted as worker messages or exposed as meeting content.
                if not line.startswith("STILLNOTE_EVENT "):
                    continue
                event = json.loads(line.removeprefix("STILLNOTE_EVENT "))
                if event["type"] == "progress":
                    progress(event["progress"], event["detail"])
                elif event["type"] == "result":
                    result = event["result"]
                elif event["type"] == "error":
                    error = event["message"]
            code = process.wait()
            if cancel_event.is_set():
                raise TranscriptionCancelled("Transcription stopped.")
            if error:
                raise RuntimeError(error)
            if code != 0 or result is None:
                raise RuntimeError(
                    "The local speech worker stopped unexpectedly. Your recording is saved. "
                    "Try again, use a smaller model, or reinstall the speech models."
                )
            return result
        finally:
            finished.set()
            watcher.join(timeout=3)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if process.stdout:
                process.stdout.close()
