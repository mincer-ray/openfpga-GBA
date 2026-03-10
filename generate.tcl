package require ::quartus::project
package require ::quartus::flow

project_open -revision ap_core src/fpga/build/gba_pocket.qpf
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
execute_flow -compile
project_close

# Run custom STA report for detailed timing path analysis (after project_close)
file mkdir build_output/reports
post_message "Running custom STA report..."
if {[catch {qexec "quartus_sta src/fpga/build/ap_core --report_script=/build/scripts/sta_custom_report.tcl"} result]} {
    post_message -type warning "Custom STA report failed: $result"
}
