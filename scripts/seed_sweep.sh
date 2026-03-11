#!/usr/bin/env bash
set -euo pipefail

# Seed sweep: tries fitter seeds and reports timing slack for each.
# Usage: ./scripts/seed_sweep.sh [start_seed] [end_seed]
#   Defaults: seeds 1 through 10
#
# Results are saved to build_output/seed_sweep/results.md
# Best bitstream is copied to build_output/seed_sweep/best/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

START_SEED=${1:-1}
END_SEED=${2:-10}

RESULTS_DIR="$PROJECT_DIR/build_output/seed_sweep"
RESULTS_FILE="$RESULTS_DIR/results.md"
mkdir -p "$RESULTS_DIR"

echo "=== Fitter Seed Sweep: seeds $START_SEED to $END_SEED ===" | tee "$RESULTS_FILE"
echo "Started: $(date)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"
echo "seed | slow_85c | slow_0c | fast | ALMs" | tee -a "$RESULTS_FILE"
echo "---- | -------- | ------- | ---- | ----" | tee -a "$RESULTS_FILE"

BEST_SEED=0
BEST_SLACK=-999.0

for seed in $(seq "$START_SEED" "$END_SEED"); do
    echo "--- Seed $seed: starting build at $(date)"

    # Run build with this seed via Docker
    docker run --rm \
      -v "$PROJECT_DIR":/build \
      -w /build \
      raetro/quartus:21.1 \
      quartus_sh -t scripts/seed_sweep_build.tcl "$seed" 2>&1 | tail -20

    # Parse timing from sta.summary - extract setup slack per corner
    SLOW_85C="N/A"
    SLOW_0C="N/A"
    FAST="N/A"

    STA_FILE="$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary"
    if [[ -f "$STA_FILE" ]]; then
        read -r SLOW_85C SLOW_0C FAST < <(awk '
            /Type.*Slow.*85C.*Setup/ { corner="85c" }
            /Type.*Slow.*0C.*Setup/  { corner="0c" }
            /Type.*Fast.*Setup/      { corner="fast" }
            /^Slack/ && corner != "" {
                match($0, /[-]?[0-9]+\.[0-9]+/)
                val = substr($0, RSTART, RLENGTH)
                if (corner == "85c" && (s85 == "" || val+0 < s85+0)) s85 = val
                if (corner == "0c"  && (s0  == "" || val+0 < s0+0))  s0  = val
                if (corner == "fast"&& (sf  == "" || val+0 < sf+0))  sf  = val
                corner = ""
            }
            END {
                if (s85 == "") s85 = "N/A"
                if (s0  == "") s0  = "N/A"
                if (sf  == "") sf  = "N/A"
                print s85, s0, sf
            }
        ' "$STA_FILE")
    fi

    # Parse ALM usage from fit.summary
    ALMS="N/A"
    FIT_FILE="$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary"
    if [[ -f "$FIT_FILE" ]]; then
        ALMS=$(grep "Logic utilization.*ALMs" "$FIT_FILE" | grep -oE '[0-9,]+ /' | grep -oE '[0-9,]+' | head -1 || true)
        [[ -z "$ALMS" ]] && ALMS="N/A"
    fi

    echo "$seed | $SLOW_85C | $SLOW_0C | $FAST | $ALMS" | tee -a "$RESULTS_FILE"

    # Save this seed's reports
    SEED_DIR="$RESULTS_DIR/seed_$seed"
    mkdir -p "$SEED_DIR"
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary" "$SEED_DIR/" 2>/dev/null || true
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary" "$SEED_DIR/" 2>/dev/null || true

    # Track best seed (using slow 85C as worst case)
    if [[ "$SLOW_85C" != "N/A" ]]; then
        IS_BETTER=$(awk "BEGIN {print ($SLOW_85C > $BEST_SLACK) ? 1 : 0}")
        if [[ "$IS_BETTER" == "1" ]]; then
            BEST_SLACK="$SLOW_85C"
            BEST_SEED="$seed"
            mkdir -p "$RESULTS_DIR/best"
            cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf" "$RESULTS_DIR/best/" 2>/dev/null || true
        fi
    fi
done

echo "" | tee -a "$RESULTS_FILE"
echo "**BEST: Seed $BEST_SEED with slack $BEST_SLACK ns (slow 85C)**" | tee -a "$RESULTS_FILE"
echo "Finished: $(date)" | tee -a "$RESULTS_FILE"

if [[ -f "$RESULTS_DIR/best/ap_core.rbf" ]]; then
    echo ""
    echo "Best bitstream saved to: $RESULTS_DIR/best/ap_core.rbf"
    echo "To deploy: python3 scripts/reverse_bitstream.py $RESULTS_DIR/best/ap_core.rbf pkg/Cores/mincer_ray.GBA/bitstream.rbf_r"
fi

# Update the QSF with the best seed
if [[ "$BEST_SEED" -gt 0 ]]; then
    QSF_FILE="$PROJECT_DIR/src/fpga/build/ap_core.qsf"
    sed -i '' "s/set_global_assignment -name SEED .*/set_global_assignment -name SEED $BEST_SEED/" "$QSF_FILE"
    echo "Updated $QSF_FILE with SEED $BEST_SEED"
fi
