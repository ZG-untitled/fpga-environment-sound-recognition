connect -url tcp:127.0.0.1:3121
after 500
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}

puts {STAGE37_NOISE_MONITOR_BEGIN}
puts {LEAVE_THE_ROOM_AS_IT_IS_NO_TARGET_AUDIO}

for {set i 0} {$i < 120} {incr i} {
    set inference [lindex [mrd -value 0x001240a4 1] 0]
    set peak [lindex [mrd -value 0x001240b8 1] 0]
    set range [lindex [mrd -value 0x001240bc 1] 0]
    set raw_class [lindex [mrd -value 0x00124068 1] 0]
    set raw_conf [lindex [mrd -value 0x001240c0 1] 0]
    set final_class [lindex [mrd -value 0x001240a8 1] 0]
    set final_conf [lindex [mrd -value 0x001240ac 1] 0]
    set alarm_state [lindex [mrd -value 0x00124040 1] 0]
    set alarm_class [lindex [mrd -value 0x00124050 1] 0]
    set alarm_action [lindex [mrd -value 0x0012404c 1] 0]
    set knock_peak [lindex [mrd -value 0x00126f60 1] 0]
    set knock_mean [lindex [mrd -value 0x00126f64 1] 0]
    set knock_ratio [lindex [mrd -value 0x00126f68 1] 0]
    set knock_active [lindex [mrd -value 0x00126f6c 1] 0]
    set knock_rejects [lindex [mrd -value 0x00126f70 1] 0]

    puts [format "S=%02d I=%u ACT=%u/%u RAW=%u/%u FINAL=%u/%u ALARM=%u/%u/A%u PCM=%u/%u/R%u/F%u REJ=%u" \
        $i $inference $peak $range \
        $raw_class $raw_conf $final_class $final_conf \
        $alarm_state $alarm_class $alarm_action \
        $knock_peak $knock_mean $knock_ratio $knock_active $knock_rejects]
    after 500
}

puts {STAGE37_NOISE_MONITOR_END}
disconnect
exit
