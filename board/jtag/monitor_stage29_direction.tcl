set direction_status_addr    0x0011cb80
set direction_phase_addr     0x001240f0
set direction_valid_addr     0x0012406c
set direction_sector_addr    0x00124070
set direction_angle_addr     0x001240e8
set direction_time_addr      0x001240ec
set direction_magnitude_addr 0x00126fac
set direction_residual_addr  0x00126fb0
set direction_rms_addr       0x00126fb4
set model_count_addr         0x001240a0
set model_class_addr         0x001240a4

connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}

set previous_count -1
set start_ms [clock milliseconds]
while {([clock milliseconds] - $start_ms) < 40000} {
    set count [lindex [mrd -value $model_count_addr 1] 0]
    if {$count != $previous_count} {
        set class_id [lindex [mrd -value $model_class_addr 1] 0]
        set status [lindex [mrd -value $direction_status_addr 1] 0]
        set valid [lindex [mrd -value $direction_valid_addr 1] 0]
        set sector [lindex [mrd -value $direction_sector_addr 1] 0]
        set angle [lindex [mrd -value $direction_angle_addr 1] 0]
        set magnitude [lindex [mrd -value $direction_magnitude_addr 1] 0]
        set residual [lindex [mrd -value $direction_residual_addr 1] 0]
        set rms [lindex [mrd -value $direction_rms_addr 1] 0]
        set time_us [lindex [mrd -value $direction_time_addr 1] 0]
        set phase [lindex [mrd -value $direction_phase_addr 1] 0]
        puts "STAGE29_DIRECTION,count=$count,class=$class_id,status=0x[format %08X $status],phase=$phase,valid=$valid,sector=$sector,angle_mdeg=$angle,magnitude_q16=$magnitude,residual_um=$residual,rms_q8=$rms,time_us=$time_us"
        set previous_count $count
    }
    after 250
}

puts {STAGE29_DIRECTION_MONITOR_STATUS=Complete}
disconnect
exit
