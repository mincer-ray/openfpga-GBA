#!/usr/bin/env bash
# Print timing summary from Quartus STA reports.
# Usage: print_timing.sh <sta_summary_file> [clock_summary_file]

set -euo pipefail

STA_FILE="${1:-}"
FMAX_FILE="${2:-}"

if [ -z "$STA_FILE" ] || [ ! -f "$STA_FILE" ]; then
  echo "=== Timing Summary ==="
  echo "  (sta.summary not found)"
  exit 0
fi

echo "=== Timing Summary ==="
echo ""

# Parse per-clock worst setup slack (across all corners) and overall worst hold slack.
# Also track worst TNS.
awk '
  function short_clock(raw,    c) {
    # Extract clock name from single quotes
    match(raw, /'"'"'[^'"'"']+'"'"'/)
    c = substr(raw, RSTART+1, RLENGTH-2)
    # Shorten PLL paths to readable names
    if (c ~ /sys_pll/)   return "sys_pll"
    if (c ~ /vid_pll/)   return "vid_pll"
    if (c ~ /audio_pll/) return "audio_pll"
    # Strip ic| prefix and trailing noise
    gsub(/^ic\|/, "", c)
    return c
  }

  function corner(raw,    c) {
    c = raw
    sub(/^Type *: */, "", c)
    sub(/ Model .*/, "", c)
    return c
  }

  /^Type/ { type_line = $0; next }

  /^Slack/ {
    sub(/^Slack *: */, "")
    slack = $0 + 0
    clk = short_clock(type_line)

    if (type_line ~ /Model Setup/) {
      # Track per-clock worst setup
      if (!(clk in ws) || slack < ws[clk]) {
        ws[clk] = slack
        ws_corner[clk] = corner(type_line)
      }
      # Track overall worst setup
      if (global_ws == "" || slack < global_ws) {
        global_ws = slack
        global_ws_clk = clk
        global_ws_corner = corner(type_line)
      }
      # Track overall best setup
      if (global_bs == "" || slack > global_bs) {
        global_bs = slack
        global_bs_clk = clk
        global_bs_corner = corner(type_line)
      }
    }

    if (type_line ~ /Model Hold/) {
      if (global_wh == "" || slack < global_wh) {
        global_wh = slack
        global_wh_clk = clk
        global_wh_corner = corner(type_line)
      }
    }

    type_line = ""
  }

  /^TNS/ {
    sub(/^TNS *: */, "")
    tns = $0 + 0
    if (global_wtns == "" || tns < global_wtns) global_wtns = tns
  }

  END {
    if (global_ws == "") { print "  No timing data found"; exit }

    printf "  %-14s %+8.3f ns  %-12s (%s)\n", "Setup worst:", global_ws, global_ws_clk, global_ws_corner
    printf "  %-14s %+8.3f ns  %-12s (%s)\n", "Setup best:", global_bs, global_bs_clk, global_bs_corner
    printf "  %-14s %+8.3f ns  %-12s (%s)\n", "Hold worst:", global_wh, global_wh_clk, global_wh_corner
    printf "  %-14s %+8.3f ns\n", "TNS worst:", global_wtns

    printf "\n  Per-clock worst setup:\n"
    for (c in ws)
      printf "    %-14s %+8.3f ns  (%s)\n", c, ws[c], ws_corner[c]

    if (global_ws + 0 < 0)
      printf "\n  *** TIMING NOT MET ***\n"
    else
      printf "\n  Timing met.\n"
  }
' "$STA_FILE"

# Print Fmax summary if available
if [ -n "$FMAX_FILE" ] && [ -f "$FMAX_FILE" ]; then
  echo ""
  echo "  Fmax by clock domain:"
  awk -F';' '
    /MHz/ && NF >= 4 {
      fmax = $2; gsub(/^ +| +$/, "", fmax)
      clock = $4; gsub(/^ +| +$/, "", clock)
      # Shorten PLL paths
      if (clock ~ /sys_pll/)   clock = "sys_pll"
      else if (clock ~ /vid_pll/)   clock = "vid_pll"
      else if (clock ~ /audio_pll/ && clock ~ /general\[0\]/) clock = "audio_pll"
      else if (clock ~ /audio_pll/ && clock ~ /general\[1\]/) clock = "audio_pll_x2"
      else { gsub(/^ic\|/, "", clock) }
      printf "    %-16s %s\n", clock, fmax
    }
  ' "$FMAX_FILE"
fi

REPORT_DIR="$(dirname "$STA_FILE")"
if [ -n "$FMAX_FILE" ] && [ -f "$FMAX_FILE" ]; then
  REPORT_DIR="$(dirname "$FMAX_FILE")"
fi

print_path_report_worst() {
  local label="$1"
  local file="$2"

  [ -f "$file" ] || return 0

  awk -v label="$label" '
    /Report Timing: Found/ {
      found = 1
      paths = $0
      sub(/^.*Found /, "", paths)
      sub(/ .*/, "", paths)

      if (match($0, /Worst case slack is [-+0-9.]+/)) {
        slack = substr($0, RSTART, RLENGTH)
        sub(/^Worst case slack is /, "", slack)
        printf "    %-20s %+8.3f ns  (%s paths)\n", label, slack + 0, paths
      } else {
        printf "    %-20s %8s     (%s paths)\n", label, "n/a", paths
      }
      exit
    }

    END {
      if (!found)
        printf "    %-20s %s\n", label, "no summary found"
    }
  ' "$file"
}

if [ -f "$REPORT_DIR/ap_core.sta.cram0_output_setup.rpt" ] || \
   [ -f "$REPORT_DIR/ap_core.sta.cram0_input_setup.rpt" ] || \
   [ -f "$REPORT_DIR/ap_core.sta.cram0_output_hold.rpt" ] || \
   [ -f "$REPORT_DIR/ap_core.sta.cram0_input_hold.rpt" ]; then
  echo ""
  echo "  CRAM0 path reports:"
  print_path_report_worst "output setup" "$REPORT_DIR/ap_core.sta.cram0_output_setup.rpt"
  print_path_report_worst "input setup"  "$REPORT_DIR/ap_core.sta.cram0_input_setup.rpt"
  print_path_report_worst "output hold"  "$REPORT_DIR/ap_core.sta.cram0_output_hold.rpt"
  print_path_report_worst "input hold"   "$REPORT_DIR/ap_core.sta.cram0_input_hold.rpt"
fi

echo ""
