#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Use an installed simulator or an already cached GHDL image. Sources are
# read-only in Docker, and all compiler output stays in a temporary directory.
if ! command -v ghdl >/dev/null 2>&1; then
  if command -v docker >/dev/null 2>&1; then
    GHDL_IMAGE="$(docker images --filter 'reference=ghdl/ghdl*' --quiet | head -n 1)"
    if [[ -n "$GHDL_IMAGE" ]]; then
      exec docker run --rm -v "$PROJECT_DIR:/source:ro" -w /source \
        "$GHDL_IMAGE" bash scripts/test_serial_multiplayer.sh
    fi
  fi
  echo "GHDL is required (installed locally or cached as a ghdl/ghdl Docker image)." >&2
  exit 1
fi

SIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gba-multiplayer.XXXXXX")"
trap 'rm -rf "$SIM_DIR"' EXIT
cd "$SIM_DIR"

ghdl -a --std=08 \
  "$PROJECT_DIR/src/fpga/gba/proc_bus_gba.vhd" \
  "$PROJECT_DIR/src/fpga/gba/reggba_serial.vhd" \
  "$PROJECT_DIR/src/fpga/gba/gba_serial_normal.vhd" \
  "$PROJECT_DIR/src/fpga/gba/gba_serial_joybus.vhd" \
  "$PROJECT_DIR/src/fpga/gba/gba_serial.vhd" \
  "$PROJECT_DIR/tests/tb_gba_serial_multiplayer.vhd" \
  "$PROJECT_DIR/tests/tb_gba_serial_multiplayer_peer.vhd"
ghdl -e --std=08 tb_gba_serial_multiplayer
ghdl -r --std=08 tb_gba_serial_multiplayer --assert-level=error
ghdl -e --std=08 tb_gba_serial_multiplayer_peer
ghdl -r --std=08 tb_gba_serial_multiplayer_peer --assert-level=error
