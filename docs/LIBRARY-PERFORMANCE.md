# Library performance verification

Measured on 2026-10-24 against master `85e2a2b`, on an Apple M5 MacBook Pro,
32 GB RAM, macOS 26.5.1, Swift 6.3.1. Release builds, three fresh-process runs per
size/variant. These are warm filesystem-cache measurements on a working machine,
not cold-boot or frame-rate guarantees. All content is synthetic: 100, 1,000 or
5,000 meetings, each with 600 mixed English/Chinese transcript segments, one-hour
duration, summary and notes. No speech model/provider is invoked.

## Results

Core measurements isolate loading/recovery, search and in-memory list updates.
They do not include SwiftUI or the 200 ms search debounce.

| Meetings | Previous load | Current load | Previous resident memory | Current resident memory |
| --- | --- | --- | --- | --- |
| 100 | 155–176 ms | 33–35 ms | 43–44 MiB | 14 MiB |
| 1,000 | 1.55–1.63 s | 309–311 ms | 305–306 MiB | 19 MiB |
| 5,000 | 7.68–8.53 s | 1.49–1.51 s | 1,450–1,459 MiB | 32 MiB |

At 5,000 meetings, current Core peak RSS during load/search/detail access was
41 MiB. Loading an individual 600-segment detail took 1.37–1.49 ms. One hundred
metadata updates took about 0.015 ms, excluding database persistence and rendering.

The queries were `rollout`, `产品计划`, and `not-present-in-this-library`.
Previously the matching-results path performed two complete text scans; the
no-results path performed one. At 5,000 meetings those paths took approximately
12–13 seconds. Current database search took 177–196 ms, 188–190 ms, and 282–289 ms,
respectively. Including the intentional debounce gives approximately 0.38–0.49 s
before UI rendering. Query cancellation is checked during SQLite scanning as well
as between returned rows. The cache changes where work happens and avoids repeated
text construction; it is not an FTS index and scans still scale with total text size.

A separate full-app Release comparison sampled process RSS one second after its
command socket became available. This marks completion of `AppModel.load()`'s
library phase; it is **not** a measurement of the first rendered interactive frame.
The baseline executable used the master app sources and pre-change Core objects.

| Meetings | Previous app ready | Current app ready | Previous app RSS | Current app RSS |
| --- | --- | --- | --- | --- |
| 100 | 327–367 ms | 218–457 ms | 155 MiB | 122 MiB |
| 1,000 | 1.71–1.75 s | 476–501 ms | 426–427 MiB | 128 MiB |
| 5,000 | 8.01–8.23 s | 1.80–1.84 s | 1,555–1,560 MiB | 140–141 MiB |

The smallest app-ready measurements are dominated by launch noise. The large-library
memory reduction demonstrates that the improvement comes from separating metadata
and details, rather than hiding rows in the sidebar.

## First upgrade and tradeoffs

Building the derived metadata/search data for an existing library took about 0.31 s,
2.87 s and 14.99 s for the three sizes, with about 22 MiB resident memory in the
migration process. Subsequent launches reuse it. The window displays startup progress
while this work runs. Interrupted search-cache preparation resumes with remaining
invalidated rows; metadata creation is transactional.

For the 5,000-meeting fixture, source JSON occupies 578 MiB and normalized search
text adds approximately 382 MiB of content, plus metadata/SQLite overhead. This is
an intentional disk-for-memory and search-latency tradeoff. Original meetings and
media are preserved; no destructive data migration is required. Older versions can
still read/write the original schema, and triggers invalidate affected cache entries.

## Verification and reproduction

- `./scripts/check.sh`: 274 Core tests plus skill checks and the app-model lifecycle
  harness (`scripts/check-library-model.sh`). The harness checks metadata-only startup,
  detail loading/eviction, rapid selection, stale revisions, progress updates that do
  not invalidate search, live detail edits, CLI edits to unopened meetings, deletion,
  and missing details.
- Core regressions cover legacy migration/legacy writes, malformed documents,
  profile/split transactions, search cache invalidation, Unicode canonical equivalence
  (including combining marks, Hangul, emoji and embedded NUL), and cancellation.
- Native UI verification used a separately identified test app and synthetic library:
  0/49/50/51-row boundaries, finding/opening the 51st meeting, Selected Meeting highlight,
  complete on-demand transcript, deletion/navigation, Chinese search, clearing queries,
  and list/calendar switching. Continuous-transcription frame-time profiling was not
  performed; update cost is reported separately above.
- `./scripts/benchmark-library.sh` regenerates isolated fixtures and writes Core
  measurements under `build/library-performance/`, removing its temporary libraries
  afterward. Its baseline mode reproduces the old recovery/load/filter/sort algorithms;
  it does not launch the baseline UI. No existing user library is used.

Sanitized measurements are retained in [performance/library](performance/library/):
`baseline.jsonl`, `current.jsonl`, and `app-startup.jsonl`. Full-app startup was measured
by launching each executable with synthetic `STILLNOTE_DATA_DIR`/`STILLNOTE_MODEL_DIR`,
waiting for `cli.sock`, sampling RSS with `ps`, and terminating that test process.
