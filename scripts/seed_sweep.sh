#!/usr/bin/env bash
set -euo pipefail

# Seed sweep: tries fitter seeds 1-10 and reports timing slack for each.
# Usage: ./scripts/seed_sweep.sh [start_seed] [end_seed]
#   Defaults: seeds 1 through 10
#
# Results are saved to build_output/seed_sweep_results.txt
# Best bitstream is copied to build_output/best_seed/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

START_SEED=${1:-1}
END_SEED=${2:-10}

RESULTS_DIR="$PROJECT_DIR/build_output/seed_sweep"
RESULTS_FILE="$RESULTS_DIR/results.txt"
mkdir -p "$RESULTS_DIR"

echo "=== Fitter Seed Sweep: seeds $START_SEED to $END_SEED ===" | tee "$RESULTS_FILE"
echo "Started: $(date)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

BEST_SEED=0
BEST_SLACK=-999.0

for seed in $(seq "$START_SEED" "$END_SEED"); do
    echo "--------------------------------------" | tee -a "$RESULTS_FILE"
    echo "Seed $seed: starting build at $(date)" | tee -a "$RESULTS_FILE"

    # Run build with this seed via Docker
    docker run --rm \
      -v "$PROJECT_DIR":/build \
      -w /build \
      raetro/quartus:21.1 \
      quartus_sh -t scripts/seed_sweep_build.tcl "$seed" 2>&1 | tail -20

    # Extract worst-case setup slack from the STA summary
    # Format: first "Slack : X.XXX" line is the worst (Slow 85C clk_sys)
    STA_FILE="$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary"
    if [[ -f "$STA_FILE" ]]; then
        SLACK=$(grep "^Slack" "$STA_FILE" | head -1 | grep -oE '[-]?[0-9]+\.[0-9]+' || echo "N/A")
    else
        SLACK="N/A"
    fi

    echo "Seed $seed: worst setup slack = $SLACK ns" | tee -a "$RESULTS_FILE"

    # Save this seed's reports
    SEED_DIR="$RESULTS_DIR/seed_$seed"
    mkdir -p "$SEED_DIR"
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary" "$SEED_DIR/" 2>/dev/null || true
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary" "$SEED_DIR/" 2>/dev/null || true

    # Track best seed
    if [[ "$SLACK" != "N/A" ]]; then
        IS_BETTER=$(awk "BEGIN {print ($SLACK > $BEST_SLACK) ? 1 : 0}")
        if [[ "$IS_BETTER" == "1" ]]; then
            BEST_SLACK="$SLACK"
            BEST_SEED="$seed"
            # Save the best bitstream
            mkdir -p "$RESULTS_DIR/best"
            cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf" "$RESULTS_DIR/best/" 2>/dev/null || true
            echo "  -> New best! Seed $seed with slack $SLACK ns" | tee -a "$RESULTS_FILE"
        fi
    fi

    echo "" | tee -a "$RESULTS_FILE"
done

echo "======================================" | tee -a "$RESULTS_FILE"
echo "BEST: Seed $BEST_SEED with slack $BEST_SLACK ns" | tee -a "$RESULTS_FILE"
echo "Finished: $(date)" | tee -a "$RESULTS_FILE"

if [[ -f "$RESULTS_DIR/best/ap_core.rbf" ]]; then
    echo ""
    echo "Best bitstream saved to: $RESULTS_DIR/best/ap_core.rbf"
    echo "To deploy: python3 scripts/reverse_bitstream.py $RESULTS_DIR/best/ap_core.rbf pkg/Cores/mincer_ray.GBA/bitstream.rbf_r"
fi
