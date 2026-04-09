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

echo "=== Fitter Seed Sweep: seeds $START_SEED to $END_SEED ==="
echo "Run started: $(date)"
echo ""

for seed in $(seq "$START_SEED" "$END_SEED"); do
    SEED_DIR="$RESULTS_DIR/seed_$seed"

    # Skip seeds that already have results
    if [[ -f "$SEED_DIR/ap_core.sta.summary" ]]; then
        echo "--- Seed $seed: already complete, skipping"
        continue
    fi

    echo "--- Seed $seed: starting build at $(date)"

    # Run build with this seed via Docker
    docker run --rm \
      -v "$PROJECT_DIR":/build \
      -w /build \
      raetro/quartus:21.1 \
      quartus_sh -t scripts/seed_sweep_build.tcl "$seed" 2>&1 | tail -20

    # Parse timing from sta.summary - extract setup slack and TNS per slow corner
    SLOW_85C="N/A"; SLOW_0C="N/A"; TNS_85C="N/A"; TNS_0C="N/A"

    STA_FILE="$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary"
    if [[ -f "$STA_FILE" ]]; then
        read -r SLOW_85C SLOW_0C TNS_85C TNS_0C < <(awk '
            /Type.*Slow.*85C.*Setup/ { corner="85c" }
            /Type.*Slow.*0C.*Setup/  { corner="0c" }
            /^Slack/ && corner != "" {
                match($0, /[-]?[0-9]+\.[0-9]+/)
                val = substr($0, RSTART, RLENGTH)
                if (corner == "85c" && (s85 == "" || val+0 < s85+0)) s85 = val
                if (corner == "0c"  && (s0  == "" || val+0 < s0+0))  s0  = val
            }
            /^TNS/ && corner != "" {
                match($0, /[-]?[0-9]+\.[0-9]+/)
                val = substr($0, RSTART, RLENGTH)
                if (corner == "85c") tns85 += val+0
                if (corner == "0c")  tns0  += val+0
                corner = ""
            }
            END {
                if (s85 == "") s85 = "N/A"
                if (s0  == "") s0  = "N/A"
                printf "%s %s %.3f %.3f\n", s85, s0, tns85+0, tns0+0
            }
        ' "$STA_FILE")
    fi

    # Parse SDRAM slack from custom STA reports
    SDRAM_RD="N/A"
    SDRAM_WR="N/A"

    REPORTS_DIR="$PROJECT_DIR/build_output/reports"
    SDRAM_RD_RPT="$REPORTS_DIR/ap_core.sta.sdram_read.rpt"
    SDRAM_WR_RPT="$REPORTS_DIR/ap_core.sta.sdram_write.rpt"

    if [[ -f "$SDRAM_RD_RPT" ]]; then
        SDRAM_RD=$(sed -n 's/.*Worst case slack is \([-]*[0-9]*\.[0-9]*\).*/\1/p' "$SDRAM_RD_RPT" | head -1 || true)
        [[ -z "$SDRAM_RD" ]] && SDRAM_RD="N/A"
    fi
    if [[ -f "$SDRAM_WR_RPT" ]]; then
        SDRAM_WR=$(sed -n 's/.*Worst case slack is \([-]*[0-9]*\.[0-9]*\).*/\1/p' "$SDRAM_WR_RPT" | head -1 || true)
        [[ -z "$SDRAM_WR" ]] && SDRAM_WR="N/A"
    fi

    # Parse ALM usage from fit.summary
    ALMS="N/A"
    FIT_FILE="$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary"
    if [[ -f "$FIT_FILE" ]]; then
        ALMS=$(grep "Logic utilization.*ALMs" "$FIT_FILE" | grep -oE '[0-9,]+ /' | grep -oE '[0-9,]+' | head -1 || true)
        [[ -z "$ALMS" ]] && ALMS="N/A"
    fi

    # Save this seed's reports and bitstream
    mkdir -p "$SEED_DIR"
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary" "$SEED_DIR/" 2>/dev/null || true
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary" "$SEED_DIR/" 2>/dev/null || true
    cp -f "$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf" "$SEED_DIR/" 2>/dev/null || true
    cp -f "$REPORTS_DIR"/ap_core.sta.sdram_read.rpt "$SEED_DIR/" 2>/dev/null || true
    cp -f "$REPORTS_DIR"/ap_core.sta.sdram_write.rpt "$SEED_DIR/" 2>/dev/null || true
    cp -f "$REPORTS_DIR"/ap_core.sta.paths_setup.rpt "$SEED_DIR/" 2>/dev/null || true

    echo "    => tns: $TNS_85C / $TNS_0C  slack: $SLOW_85C / $SLOW_0C  sdram: rd=$SDRAM_RD wr=$SDRAM_WR  ALMs: $ALMS"
done

# Rebuild results table from ALL completed seed directories
# Scoring priority: 1) SDRAM paths positive  2) best (closest to 0) TNS  3) SDRAM margin
BEST_SEED=0
BEST_SDRAM_WORST=-999.0
BEST_TNS=-999999.0

echo "=== Fitter Seed Sweep ===" > "$RESULTS_FILE"
echo "seed | tns_85c | tns_0c | sdram_rd | sdram_wr | slack_85c | slack_0c | ALMs" >> "$RESULTS_FILE"
echo "---- | ------- | ------ | -------- | -------- | --------- | -------- | ----" >> "$RESULTS_FILE"

for seed_dir in $(printf '%s\n' "$RESULTS_DIR"/seed_* | sort -t_ -k2 -n); do
    [[ -d "$seed_dir" ]] || continue
    sta="$seed_dir/ap_core.sta.summary"
    [[ -f "$sta" ]] || continue

    seed=$(basename "$seed_dir" | sed 's/seed_//')

    # Parse corner slack and TNS (summed across all setup clocks per corner)
    read -r s85 s0 tns85 tns0 < <(awk '
        /Type.*Slow.*85C.*Setup/ { corner="85c" }
        /Type.*Slow.*0C.*Setup/  { corner="0c" }
        /^Slack/ && corner != "" {
            match($0, /[-]?[0-9]+\.[0-9]+/)
            val = substr($0, RSTART, RLENGTH)
            if (corner == "85c" && (s85 == "" || val+0 < s85+0)) s85 = val
            if (corner == "0c"  && (s0  == "" || val+0 < s0+0))  s0  = val
        }
        /^TNS/ && corner != "" {
            match($0, /[-]?[0-9]+\.[0-9]+/)
            val = substr($0, RSTART, RLENGTH)
            if (corner == "85c") tns85 += val+0
            if (corner == "0c")  tns0  += val+0
            corner = ""
        }
        END {
            if (s85 == "") s85 = "N/A"
            if (s0  == "") s0  = "N/A"
            printf "%s %s %.3f %.3f\n", s85, s0, tns85+0, tns0+0
        }
    ' "$sta")

    # Parse SDRAM slack from saved reports
    sdram_rd="N/A"
    sdram_wr="N/A"
    if [[ -f "$seed_dir/ap_core.sta.sdram_read.rpt" ]]; then
        sdram_rd=$(sed -n 's/.*Worst case slack is \([-]*[0-9]*\.[0-9]*\).*/\1/p' "$seed_dir/ap_core.sta.sdram_read.rpt" | head -1 || true)
        [[ -z "$sdram_rd" ]] && sdram_rd="N/A"
    fi
    if [[ -f "$seed_dir/ap_core.sta.sdram_write.rpt" ]]; then
        sdram_wr=$(sed -n 's/.*Worst case slack is \([-]*[0-9]*\.[0-9]*\).*/\1/p' "$seed_dir/ap_core.sta.sdram_write.rpt" | head -1 || true)
        [[ -z "$sdram_wr" ]] && sdram_wr="N/A"
    fi

    # Parse ALM usage
    alms="N/A"
    if [[ -f "$seed_dir/ap_core.fit.summary" ]]; then
        alms=$(grep "Logic utilization.*ALMs" "$seed_dir/ap_core.fit.summary" | grep -oE '[0-9,]+ /' | grep -oE '[0-9,]+' | head -1 || true)
        [[ -z "$alms" ]] && alms="N/A"
    fi

    echo "$seed | $tns85 | $tns0 | $sdram_rd | $sdram_wr | $s85 | $s0 | $alms" >> "$RESULTS_FILE"

    [[ "$s85" == "N/A" || "$s0" == "N/A" ]] && continue

    # Worst TNS across slow corners (most negative)
    worst_tns=$(awk "BEGIN {print ($tns85 < $tns0) ? $tns85 : $tns0}")

    # SDRAM worst slack (min of read/write cross-domain paths)
    sdram_worst=-999.0
    if [[ "$sdram_rd" != "N/A" && "$sdram_wr" != "N/A" ]]; then
        sdram_worst=$(awk "BEGIN {print ($sdram_rd < $sdram_wr) ? $sdram_rd : $sdram_wr}")
    fi

    # Tiered comparison: SDRAM positive > best TNS > SDRAM margin
    is_better=$(awk "BEGIN {
        new_ok = ($sdram_worst > 0) ? 1 : 0
        best_ok = ($BEST_SDRAM_WORST > 0) ? 1 : 0
        if (new_ok > best_ok) { print 1; exit }
        if (new_ok < best_ok) { print 0; exit }
        if ($worst_tns > $BEST_TNS) { print 1; exit }
        if ($worst_tns < $BEST_TNS) { print 0; exit }
        if ($sdram_worst > $BEST_SDRAM_WORST) { print 1; exit }
        print 0
    }")

    if [[ "$is_better" == "1" ]]; then
        BEST_SEED="$seed"
        BEST_TNS="$worst_tns"
        BEST_SDRAM_WORST="$sdram_worst"
    fi
done

echo "" >> "$RESULTS_FILE"
if awk "BEGIN {exit ($BEST_SDRAM_WORST > 0) ? 0 : 1}"; then
    SDRAM_STATUS="SDRAM met ($BEST_SDRAM_WORST ns)"
else
    SDRAM_STATUS="SDRAM NOT met ($BEST_SDRAM_WORST ns)"
fi
echo "**BEST: Seed $BEST_SEED — $SDRAM_STATUS, TNS $BEST_TNS ns**" | tee -a "$RESULTS_FILE"
echo "Finished: $(date)" >> "$RESULTS_FILE"

# Copy best bitstream from that seed's saved directory
if [[ "$BEST_SEED" -gt 0 && -f "$RESULTS_DIR/seed_$BEST_SEED/ap_core.rbf" ]]; then
    mkdir -p "$RESULTS_DIR/best"
    cp -f "$RESULTS_DIR/seed_$BEST_SEED/ap_core.rbf" "$RESULTS_DIR/best/"
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
