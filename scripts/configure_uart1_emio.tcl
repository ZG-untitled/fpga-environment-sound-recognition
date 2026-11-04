set project_file {C:/Users/L/Documents/Codex/2026-09-22/ni/stage22_project_link/project_re.xpr}

open_project $project_file
set bd_file [get_files -quiet */system.bd]
if {[llength $bd_file] != 1} {
    error "Expected one system.bd, found [llength $bd_file]"
}
open_bd_design $bd_file
set ps [get_bd_cells processing_system7_0]
set_property -dict [list \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {EMIO} \
] $ps

if {[llength [get_bd_intf_ports -quiet UART_1]] == 0} {
    make_bd_intf_pins_external [get_bd_intf_pins $ps/UART_1]
    set_property name UART_1 [get_bd_intf_ports UART_1_0]
}

validate_bd_design
save_bd_design
set_property synth_checkpoint_mode None $bd_file
reset_target all $bd_file
generate_target all $bd_file
make_wrapper -files $bd_file -top
set_property top mic_ps_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts {STAGE29_UART1_EMIO_CONFIGURATION_STATUS=Complete}
puts "UART_PORT=[get_bd_intf_ports UART_1]"
close_project
exit
