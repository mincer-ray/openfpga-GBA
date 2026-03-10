# Custom STA report script sourced by quartus_sta --report_script
# Netlist is already loaded and timing updated by the default STA flow.

set out_setup "/build/build_output/reports/ap_core.sta.paths_setup.rpt"
set out_hold  "/build/build_output/reports/ap_core.sta.paths_hold.rpt"
set out_sum   "/build/build_output/reports/ap_core.sta.clock_summary.rpt"

post_message "Writing setup paths to $out_setup"
post_message "Writing hold paths to $out_hold"
post_message "Writing clock summary to $out_sum"

# Worst setup/hold paths across full design
report_timing -setup -npaths 80 -detail full_path -file $out_setup
report_timing -hold  -npaths 40 -detail full_path -file $out_hold

# Useful high-level summary by clock domain
report_clock_fmax_summary -file $out_sum
