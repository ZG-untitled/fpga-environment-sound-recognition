# ALIENTEK Qimingxing ZYNQ V2.3.2, XC7Z020CLG400-2
# Four independent INMP441 microphones on OLED&CAMERA connector P2.
# Sources:
#   Qimingxing ZYNQ baseboard schematic V2.3.2, sheet 3 (P2 pinout)
#   Qimingxing ZYNQ IO pin-assignment workbook, PL IO table

# 50 MHz PL clock, active-low PL reset, and PL LED0.
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]
# clk_wiz_0 already supplies the 20 ns input-clock constraint.
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports rst_n]

# Stage 29 TJC 800x480 display, PS UART1 through EMIO (115200 8N1).
# U4 pin 4 / UART3_TX -> display RX; U4 pin 3 / UART3_RX <- display TX.
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports tjc_uart_tx]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports tjc_uart_rx]
set_false_path -from [get_ports tjc_uart_rx]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports led]

# OLED&CAMERA header P2 (even-numbered row):
#   P2-8  = CMOS_D0 = R14 -> INMP441 SCK/BCLK
#   P2-10 = CMOS_D2 = V13 -> INMP441 WS/LRCLK
#   P2-12 = CMOS_D4 = U14 -> INMP441 CH0 SD
#   P2-13 = CMOS_D5 = W13 -> INMP441 CH1 SD
#   P2-14 = CMOS_D6 = V12 -> INMP441 CH2 SD
#   P2-15 = CMOS_D7 = Y14 -> INMP441 CH3 SD
#   P2-1  = +3.3 V; P2-2 = GND
# All microphones share SCK and WS.  Every L/R pin is tied to GND.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports mic_bclk]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports mic_ws]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {mic_sd[0]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {mic_sd[1]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {mic_sd[2]}]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 PULLDOWN TRUE} [get_ports {mic_sd[3]}]

# Stage 16 WS2812 test integration
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports key]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST} [get_ports ws2812_dout]
# EXT_IO J2-17 = B35_L8_N = M18. Connect this pin only to the vibration
# module's IN pin; the module motor is powered separately through VCC/GND.
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports vibration_motor]
set_false_path -from [get_ports key]
set_false_path -to [get_ports ws2812_dout]
set_false_path -to [get_ports vibration_motor]
