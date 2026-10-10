#!/usr/bin/env python3
"""Benchmark the Nemotron worker: three fresh processes, median wall time, RTF, and peak memory.

Usage:
    python3 scripts/benchmark-nemotron.py /path/to/audio.f32 [--worker PATH] [--runs 3]

The fixture is raw 16 kHz mono float32, the format `AudioDecoder` writes. Build the worker
with `swift build -c release --product StillnoteSpeechWorker && ./scripts/build-metal.sh release`
first. Raw results contain transcript text, so they stay in the ignored `.build/` directory.
A failed process or an empty transcript is reported as a failure, never as a fast run.
"""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".build/nemotron-bench"


def run_once(worker, request):
    started = time.monotonic()
    run = subprocess.run(["/usr/bin/time", "-l", str(worker), "nemotron", json.dumps(request)],
                         text=True, capture_output=True, timeout=3600)
    elapsed = time.monotonic() - started
    if run.returncode != 0:
        raise SystemExit(f"worker exited {run.returncode}:\n{run.stderr[-4000:]}")
    events = [json.loads(line.removeprefix("STILLNOTE_EVENT ")) for line in run.stdout.splitlines()
              if line.startswith("STILLNOTE_EVENT ")]
    transcripts = [event["transcript"] for event in events if event["type"] == "transcript"]
    if len(transcripts) != 1 or not transcripts[0]["words"]:
        raise SystemExit("worker returned no transcript")
    footprint = int(re.search(r"([0-9]+)\s+peak memory footprint", run.stderr)[1])
    transcript = transcripts[0]
    return {
        "elapsed_seconds": elapsed,
        "peak_footprint_bytes": footprint,
        "words": len(transcript["words"]),
        "channels": len({span["speaker"] for span in transcript["activity"]}),
        "gpu_fallback": any("GPU" in event.get("detail", "") for event in events),
        "transcript": transcript,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pcm", type=Path)
    parser.add_argument("--worker", type=Path, default=ROOT / ".build/release/StillnoteSpeechWorker")
    parser.add_argument("--models", type=Path, default=Path(os.environ.get(
        "STILLNOTE_MODEL_DIR", str(Path.home() / "Library/Application Support/Stillnote/models"))))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--language", default="auto")
    args = parser.parse_args()

    size = args.pcm.stat().st_size
    assert size > 0 and size % 4 == 0, "expected raw float32 PCM"
    duration = size / 4 / 16000
    request = {"asrModelPath": str(args.models / "speech/nemotron-asr-0.6b"),
               "diarizerModelPath": str(args.models / "speech/nemotron-diarize-100m"),
               "pcmPath": str(args.pcm.resolve()), "language": args.language,
               "hotWords": [], "geometry": "offline"}
    runs = []
    for index in range(args.runs):
        result = run_once(args.worker, request)
        runs.append(result)
        print(f"run {index + 1}: {result['elapsed_seconds']:.1f} s, "
              f"{result['peak_footprint_bytes'] / 1e9:.3f} GB peak, {result['words']} words, "
              f"{result['channels']} channels", flush=True)

    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / f"{args.pcm.stem}.json").write_text(json.dumps(runs, indent=2) + "\n")
    elapsed = [run["elapsed_seconds"] for run in runs]
    summary = {
        "audio_seconds": round(duration, 1),
        "median_seconds": round(statistics.median(elapsed), 1),
        "range_seconds": [round(min(elapsed), 1), round(max(elapsed), 1)],
        "median_rtf": round(statistics.median(elapsed) / duration, 4),
        "median_peak_footprint_gb": round(statistics.median(run["peak_footprint_bytes"] for run in runs) / 1e9, 3),
        "words": sorted({run["words"] for run in runs}),
        "channels": sorted({run["channels"] for run in runs}),
        "gpu_fallback": any(run["gpu_fallback"] for run in runs),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
