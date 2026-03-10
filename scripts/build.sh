#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RBF="$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf"
RBF_R="$PROJECT_DIR/pkg/Cores/mincer_ray.GBA/bitstream.rbf_r"

echo "=== Starting Quartus build via Docker ==="
docker run --rm \
  -v "$PROJECT_DIR":/build \
  -w /build \
  raetro/quartus:21.1 \
  quartus_sh -t generate.tcl

echo ""
echo "=== Build complete, reversing bitstream ==="
python3 "$SCRIPT_DIR/reverse_bitstream.py" "$RBF" "$RBF_R"

echo ""
echo "=== Done! ==="
echo "Bitstream: $RBF_R"
