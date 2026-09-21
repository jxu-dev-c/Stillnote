# MOSS performance and verification

All modes use the pinned local 8-bit model weights and preserve the whole meeting
in one decoder context. Quality retains the checkpoint's context precision.
Balanced uses 8-bit affine KV storage with groups of 64. Low Memory uses 4-bit
storage except the first and last two decoder layers, which retain 8-bit storage.
Uniform 4-bit KV returned an empty transcript on the 35-second real-speech fixture;
boundary-layer protection restored a complete transcript. Low Memory can change
wording, timestamps, and speaker assignments.

Prefill sizes are 512, 128, and 64 tokens respectively. Intermediate prefill evaluates
KV state without projecting every position to 151,936 vocabulary logits. PCM files
are read in 30-second windows. Greedy decoding overlaps GPU work and CPU token
handling, and prompt embeddings are released after prefill. Other sampling settings
retain the history-dependent path.

The worker budget is min(60% of physical RAM, 70% of recommended GPU working set).
A conservative estimate includes weights, cache allocation rounded to 256 tokens,
cache growth, prompt assembly, attention scratch, and a 256 MiB allocation pool.
The check runs before encoding and prefill and as output grows. It does not reserve
the maximum output-token allowance or silently change modes. This is an estimate,
not an operating-system memory reservation or a guarantee against external pressure.

## Reproduce

Run `scripts/check.sh` for the unit suite, including GPU attention and PCM tests.
The script places the Metal library beside the XCTest bundle's executable.
Build the packaged worker with `scripts/build-app.sh release`.

Before editing the pipeline, copy the baseline release worker and its `mlx.metallib`
to `.build/moss-baseline/`. Prepare a mono 16 kHz float32 PCM fixture, then run:

```sh
python3 scripts/benchmark-moss.py /path/to/audio.f32 --model /path/to/model-directory
```

The runner launches three fresh workers per mode, saves raw results locally, and
prints medians. Keep the Mac plugged in and avoid concurrent GPU work. An empty
transcript or failed process must not count as a speed improvement. Results contain
transcript text; they stay in the ignored `.build/` directory.

Set `STILLNOTE_METRICS=1` for structured worker events containing stage durations,
token counts, MLX memory, and process peak RSS. MLX allocation accounting differs
from process RSS; report both without adding their overlapping allocations. Model loading is separate from encoding, prefill,
and decoding. `STILLNOTE_MEMORY_BUDGET_MB` can lower the worker budget for tests;
it cannot increase the device-derived budget. Such runs do not substitute for
measurements on a physical 16 GB Mac.

The app's existing opt-in integration suite accepts `STILLNOTE_INTEGRATION_AUDIO`
and `STILLNOTE_TEST_WORKER`. It covers offline transcription, silence, and process
cancellation without changing existing meeting transcripts.

To validate saved benchmark outputs with the app's actual transcript parser, set
`STILLNOTE_BENCHMARK_RESULTS` to the result JSON when running
`swift test --skip-build --filter recordedBenchmarksPassTheAppParser` after building
the test bundle with `scripts/check.sh`.

## Measurements — September 20, 2026

Apple M5 MacBook Pro, 32 GB, AC power; pinned MOSS checkpoint. Three fresh
processes per mode on the same 22-minute local recording. Values are decimal GB.

| Mode | Median seconds | Range seconds | Median peak process RSS GB | MLX peak GB |
| --- | ---: | ---: | ---: | ---: |
| baseline | 312.7 | 265.5–358.4 | 1.674 | Not instrumented |
| quality | 314.3 | 240.4–344.2 | 1.506 | 4.445 |
| balanced | 231.8 | 194.3–273.9 | 1.508 | 3.315 |
| low-memory | 152.0 | 110.1–161.6 | 1.507 | 2.545 |

Quality's median time was effectively unchanged (+0.5%); its process peak RSS fell
10.1%. The 10% Quality speed target was **not established**. Balanced was 25.9%
faster and Low Memory 51.4% faster by median wall time. Both compressed modes
change output, so these are end-to-end measurements, not equal-token throughput
claims. Background CPU activity was substantial; the first sweep also overlapped
build/test work. Later repeats ran without other agent GPU jobs. These are local,
noisy measurements rather than controlled cross-device performance guarantees.

At the same cached-token count, 8-bit storage uses 53.1% of the original KV bytes
(46.9% reduction); protected 4-bit storage uses 31.7% (68.3% reduction). GPU tests
check these storage targets. At completion, observed caches were 2.877 GB Quality,
1.529 GB Balanced, and 0.838 GB Low Memory; the latter generated fewer tokens.

All repeated Quality transcripts matched the baseline byte-for-byte (250 segments,
2,300 whitespace-separated words, five speaker tags). Balanced returned 240 segments,
2,299 words, and five tags; Low Memory returned 149 segments, 2,180 words, and five
tags. Their final spoken timestamps were within 0.03 seconds of the baseline.
Every output passed the app's transcript parser. Word-sequence similarity to the
baseline was 97.5% Balanced and 91.7% Low Memory; this is **not** WER, diarization
accuracy, or a comparison with human ground truth. Segment counts and speaker IDs
do not establish that every speaker assignment is correct.

A separate final three-run 35-second benchmark measured medians of 2.948 seconds
baseline, 2.800 Quality, 2.883 Balanced, and 2.870 Low Memory. Quality remained
byte-identical to baseline. Raw transcripts and measurements remain local under
`.build/moss-bench/`; they are not included in source control.
