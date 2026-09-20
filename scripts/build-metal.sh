#!/usr/bin/env bash
# SwiftPM's CLI does not compile .metal resources. Build MLX's pinned generated kernels.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
bin="$(swift build -c "$configuration" --show-bin-path)"
source_dir="$PWD/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
output="$bin/mlx.metallib"
# Include changes in headers as well as kernel sources in the cache key.
stamp=$(find "$source_dir" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d ' ' -f 1)
stamp="$stamp-$(xcrun metal --version | shasum -a 256 | cut -d ' ' -f 1)"
if [[ -f "$output" && -f "$output.sha256" && "$(cat "$output.sha256")" == "$stamp" ]]; then exit 0; fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
while IFS= read -r -d '' source; do
  name="${source#"$source_dir"/}"
  name="${name//\//_}"
  xcrun -sdk macosx metal -std=metal3.2 -mmacosx-version-min=15.0 -O2 -I "$source_dir" -c "$source" -o "$scratch/$name.air"
done < <(find "$source_dir" -name '*.metal' -print0)
xcrun -sdk macosx metallib "$scratch"/*.air -o "$output"
printf '%s' "$stamp" > "$output.sha256"
