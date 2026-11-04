set output_file {D:/project_re (2) (1)/project_re/verification_mic/stage29_prediction_trace.csv}

set model_status_addr      0x0011cad0
set alarm_action_addr      0x00124058
set model_sequence_addr    0x0012409c
set model_count_addr       0x001240a0
set model_class_addr       0x001240a4
set model_confidence_addr  0x001240a8
set model_inference_addr   0x001240ac
set activity_peak_addr     0x001240b4
set activity_range_addr    0x001240b8
set raw_class_addr         0x00124068
set raw_confidence_addr    0x001240bc
set rejection_count_addr   0x001240c0
set retry_trigger_addr     0x001240c4
set retry_knock_addr       0x001240c8
set retry_first_addr       0x001240cc
set retry_second_addr      0x001240d0
set retry_second_conf_addr 0x001240d4
set retry_feature_us_addr  0x001240dc
set retry_inference_addr   0x001240e0
set retry_total_addr       0x001240e4
set direction_valid_addr   0x0012406c
set direction_sector_addr  0x00124070
set direction_angle_addr   0x001240e8

connect -url tcp:127.0.0.1:3121
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}

set handle [open $output_file w]
puts $handle {elapsed_ms,sequence,count,final_class,final_confidence_q8,raw_class,raw_confidence_q8,rejection_count,alarm_action,direction_valid,direction_sector,direction_angle_mdeg,activity_peak_q8_8,activity_range_q8_8,base_inference_us,retry_trigger_count,retry_knock_count,retry_first_class,retry_second_class,retry_second_confidence_q8,retry_feature_us,retry_inference_us,retry_total_us}

set start_ms [clock milliseconds]
set end_ms [expr {$start_ms + 60000}]
set previous_count -1

while {[clock milliseconds] < $end_ms} {
    set status [lindex [mrd -value $model_status_addr 1] 0]
    set count [lindex [mrd -value $model_count_addr 1] 0]
    if {$status == 0x52454144 && $count != $previous_count} {
        set elapsed [expr {[clock milliseconds] - $start_ms}]
        set sequence [lindex [mrd -value $model_sequence_addr 1] 0]
        set class_id [lindex [mrd -value $model_class_addr 1] 0]
        set confidence [lindex [mrd -value $model_confidence_addr 1] 0]
        set alarm_action [lindex [mrd -value $alarm_action_addr 1] 0]
        set activity_peak [lindex [mrd -value $activity_peak_addr 1] 0]
        set activity_range [lindex [mrd -value $activity_range_addr 1] 0]
        set raw_class [lindex [mrd -value $raw_class_addr 1] 0]
        set raw_confidence [lindex [mrd -value $raw_confidence_addr 1] 0]
        set rejection_count [lindex [mrd -value $rejection_count_addr 1] 0]
        set direction_valid [lindex [mrd -value $direction_valid_addr 1] 0]
        set direction_sector [lindex [mrd -value $direction_sector_addr 1] 0]
        set direction_angle [lindex [mrd -value $direction_angle_addr 1] 0]
        set inference_us [lindex [mrd -value $model_inference_addr 1] 0]
        set retry_trigger [lindex [mrd -value $retry_trigger_addr 1] 0]
        set retry_knock [lindex [mrd -value $retry_knock_addr 1] 0]
        set retry_first [lindex [mrd -value $retry_first_addr 1] 0]
        set retry_second [lindex [mrd -value $retry_second_addr 1] 0]
        set retry_second_conf [lindex [mrd -value $retry_second_conf_addr 1] 0]
        set retry_feature_us [lindex [mrd -value $retry_feature_us_addr 1] 0]
        set retry_inference_us [lindex [mrd -value $retry_inference_addr 1] 0]
        set retry_total_us [lindex [mrd -value $retry_total_addr 1] 0]
        puts $handle "$elapsed,$sequence,$count,$class_id,$confidence,$raw_class,$raw_confidence,$rejection_count,$alarm_action,$direction_valid,$direction_sector,$direction_angle,$activity_peak,$activity_range,$inference_us,$retry_trigger,$retry_knock,$retry_first,$retry_second,$retry_second_conf,$retry_feature_us,$retry_inference_us,$retry_total_us"
        flush $handle
        puts "STAGE29_PREDICTION,count=$count,class=$class_id,confidence=$confidence,raw_class=$raw_class,raw_confidence=$raw_confidence,rejections=$rejection_count,direction_valid=$direction_valid,direction_sector=$direction_sector,direction_angle_mdeg=$direction_angle,peak=$activity_peak,range=$activity_range"
        set previous_count $count
    }
    after 100
}

close $handle
puts {STAGE29_MONITOR_STATUS=Complete}
puts "STAGE29_MONITOR_CSV=$output_file"
disconnect
exit
