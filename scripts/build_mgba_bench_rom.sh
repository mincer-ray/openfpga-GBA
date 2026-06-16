#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUITE_DIR="$PROJECT_DIR/reference/repos/mgba-suite"
PATCH_FILE="$PROJECT_DIR/benchmarks/mgba-suite/mgba-suite-bench.patch"
OUTPUT_DIR="$PROJECT_DIR/build_output/mgba-suite"
IMAGE="${MGBA_BENCH_DOCKER_IMAGE:-devkitpro/devkitarm}"
SUITE_COMMIT="2a8eca19d896720cfcd6a2da400f7ab722ddd60c"

mkdir -p "$(dirname "$SUITE_DIR")"

if [[ ! -d "$SUITE_DIR/.git" ]]; then
  git clone https://github.com/mgba-emu/suite.git "$SUITE_DIR"
  git -C "$SUITE_DIR" checkout "$SUITE_COMMIT"
fi

if git -C "$SUITE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  git -C "$SUITE_DIR" apply "$PATCH_FILE"
elif git -C "$SUITE_DIR" apply --check --reverse "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Benchmark patch already applied"
else
  echo "error: benchmark patch does not apply cleanly in $SUITE_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

BENCH_SUITE_COMMIT="$(git -C "$SUITE_DIR" rev-parse HEAD)"

docker run --rm \
  -v "$SUITE_DIR":/work \
  -w /work \
  "$IMAGE" \
  bash -lc "make clean && make BENCH_AUTORUN=1 BENCH_SUITE_COMMIT=$BENCH_SUITE_COMMIT"

cp "$SUITE_DIR/suite.gba" "$OUTPUT_DIR/suite-bench.gba"

echo "Built ROM: $OUTPUT_DIR/suite-bench.gba"
