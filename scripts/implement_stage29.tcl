set verification_dir {C:/Users/L/Documents/Codex/2026-09-22/ni/stage22_project_link/verification_mic}
set input_dcp [file join $verification_dir stage29_retry_tjc_synth.dcp]
set routed_dcp [file join $verification_dir stage29_retry_tjc_routed.dcp]
set bit_file [file join $verification_dir stage29_retry_tjc.bit]
set ltx_file [file join $verification_dir stage29_retry_tjc.ltx]

set_param general.maxThreads 2
open_checkpoint $input_dcp
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $verification_dir stage29_retry_tjc_utilization_routed.rpt]
report_timing_summary -file [file join $verification_dir stage29_retry_tjc_timing_routed.rpt]
report_drc -file [file join $verification_dir stage29_retry_tjc_drc.rpt]

set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $setup_paths] > 0} {
    set slack [get_property SLACK [lindex $setup_paths 0]]
    puts "STAGE29_SETUP_WNS=$slack"
    if {$slack < 0.0} { error "Stage 29 setup timing failed: WNS=$slack" }
}
set hold_paths [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $hold_paths] > 0} {
    set slack [get_property SLACK [lindex $hold_paths 0]]
    puts "STAGE29_HOLD_WHS=$slack"
    if {$slack < 0.0} { error "Stage 29 hold timing failed: WHS=$slack" }
}

write_checkpoint -force $routed_dcp
if {[llength [get_debug_cores -quiet]] > 0} {
    write_debug_probes -force $ltx_file
}
write_bitstream -force $bit_file
puts {STAGE29_IMPLEMENTATION_STATUS=Complete}
puts "STAGE29_BIT_FILE=$bit_file"
close_design
exit
