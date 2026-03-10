package require ::quartus::project
package require ::quartus::flow

set seed [lindex $quartus(args) 0]
if {$seed eq ""} {
    post_message -type error "Usage: quartus_sh -t seed_sweep_build.tcl <seed>"
    exit 1
}

post_message "=== Building with fitter seed $seed ==="

project_open -revision ap_core src/fpga/build/gba_pocket.qpf
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name SEED $seed

# Clean incremental DB to force full fit with new seed
file delete -force src/fpga/build/db
file delete -force src/fpga/build/incremental_db

execute_flow -compile
project_close

# Run custom STA report
file mkdir build_output/reports
post_message "Running custom STA report for seed $seed..."
if {[catch {qexec "quartus_sta src/fpga/build/ap_core --report_script=/build/scripts/sta_custom_report.tcl"} result]} {
    post_message -type warning "Custom STA report failed: $result"
}
