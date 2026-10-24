#!/usr/bin/env bash
# Isolated synthetic libraries only. Reports Core loading and algorithm costs, not UI latency.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --target StillnoteCore
bin="$(swift build -c release --show-bin-path)"
mkdir -p build/library-performance
swiftc -O -parse-as-library -I "$bin/Modules" scripts/benchmark-library.swift \
  "$bin"/StillnoteCore.build/*.o -o build/library-performance/benchmark
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/stillnote-library-benchmark.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
sw_vers > build/library-performance/environment.txt
sysctl hw.model machdep.cpu.brand_string hw.memsize >> build/library-performance/environment.txt
swift --version >> build/library-performance/environment.txt
: > build/library-performance/results.jsonl
for count in 100 1000 5000; do
  fixture="$fixture_root/$count"
  build/library-performance/benchmark seed "$fixture" "$count"
  du -k "$fixture/stillnote.sqlite3" >> build/library-performance/environment.txt
  for repeat in 1 2 3; do
    for mode in baseline improved; do
      build/library-performance/benchmark "$mode" "$fixture" | tee -a build/library-performance/results.jsonl
    done
  done
done
