`timescale 1ns / 1ps

module mic_ps_top (
    input wire sys_clk, input wire rst_n, input wire [3:0] mic_sd,
    output wire mic_bclk, output wire mic_ws, output wire led,
    input wire key, output wire ws2812_dout,
    output wire vibration_motor,
    input wire tjc_uart_rx, output wire tjc_uart_tx,
    inout wire [14:0] DDR_addr, inout wire [2:0] DDR_ba,
    inout wire DDR_cas_n, inout wire DDR_ck_n, inout wire DDR_ck_p,
    inout wire DDR_cke, inout wire DDR_cs_n, inout wire [3:0] DDR_dm,
    inout wire [31:0] DDR_dq, inout wire [3:0] DDR_dqs_n,
    inout wire [3:0] DDR_dqs_p, inout wire DDR_odt,
    inout wire DDR_ras_n, inout wire DDR_reset_n, inout wire DDR_we_n,
    inout wire FIXED_IO_ddr_vrn, inout wire FIXED_IO_ddr_vrp,
    inout wire [53:0] FIXED_IO_mio, inout wire FIXED_IO_ps_clk,
    inout wire FIXED_IO_ps_porb, inout wire FIXED_IO_ps_srstb
);

wire [10:0] matrix_read_address;
wire [31:0] matrix_read_data;
wire pl_clk_50m;

system_wrapper u_system_wrapper (
    .DDR_addr(DDR_addr), .DDR_ba(DDR_ba), .DDR_cas_n(DDR_cas_n),
    .DDR_ck_n(DDR_ck_n), .DDR_ck_p(DDR_ck_p), .DDR_cke(DDR_cke),
    .DDR_cs_n(DDR_cs_n), .DDR_dm(DDR_dm), .DDR_dq(DDR_dq),
    .DDR_dqs_n(DDR_dqs_n), .DDR_dqs_p(DDR_dqs_p), .DDR_odt(DDR_odt),
    .DDR_ras_n(DDR_ras_n), .DDR_reset_n(DDR_reset_n), .DDR_we_n(DDR_we_n),
    .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn), .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
    .FIXED_IO_mio(FIXED_IO_mio), .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
    .FIXED_IO_ps_porb(FIXED_IO_ps_porb), .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
    .UART_1_rxd(tjc_uart_rx), .UART_1_txd(tjc_uart_tx),
    .matrix_read_address(matrix_read_address),
    .matrix_read_data(matrix_read_data), .pl_clk_50m(pl_clk_50m)
);

// The production direction/alarm image omits ILA. Direction diagnostics are
// exported through the PS/JTAG variables, so keeping the debug core here only
// increases resource use and can stall Vivado while regenerating dbg_hub.
mic_test_top #(.INCLUDE_ILA(0)) u_mic_test_top (
    .sys_clk(sys_clk), .rst_n(rst_n), .mic_sd(mic_sd),
    .mic_bclk(mic_bclk), .mic_ws(mic_ws), .led(led),
    .matrix_read_clk(pl_clk_50m), .matrix_read_address(matrix_read_address),
    .matrix_read_data(matrix_read_data)
);

localparam [10:0] ALARM_COMMAND_BASE = 11'd2000;
localparam [10:0] ALARM_VISUAL_RED_COMMAND = 11'd2004;
localparam [10:0] DIRECTION_COMMAND_BASE = 11'd2010;
reg [10:0] command_address_meta;
reg [10:0] command_address_sync;
reg [10:0] command_address_previous;

always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        command_address_meta <= 11'd0;
        command_address_sync <= 11'd0;
        command_address_previous <= 11'd0;
    end else begin
        command_address_meta <= matrix_read_address;
        command_address_sync <= command_address_meta;
        command_address_previous <= command_address_sync;
    end
end

wire command_changed = command_address_sync != command_address_previous;
wire alarm_command_valid = command_changed &&
    (command_address_sync >= ALARM_COMMAND_BASE) &&
    (command_address_sync <= ALARM_COMMAND_BASE + 11'd3);
wire [1:0] alarm_action = command_address_sync - ALARM_COMMAND_BASE;
wire alarm_visual_only_valid = command_changed &&
    (command_address_sync == ALARM_VISUAL_RED_COMMAND);
wire direction_command_valid = command_changed &&
    (command_address_sync >= DIRECTION_COMMAND_BASE) &&
    (command_address_sync <= DIRECTION_COMMAND_BASE + 11'd7);
wire [2:0] direction_sector = command_address_sync - DIRECTION_COMMAND_BASE;
wire [2:0] ws2812_status_led_unused;
wire [1:0] ws2812_active_action_unused;
wire [2:0] ws2812_active_direction_unused;

ws2812_direction_alarm_top #(
    .CLK_FREQ_HZ(50_000_000), .LED_NUM(30), .BRIGHT_MAX(64)
) u_ws2812_direction_alarm_top (
    .clk(sys_clk), .rst_n(rst_n), .key(key),
    .alarm_action_valid(alarm_command_valid), .alarm_action(alarm_action),
    .alarm_visual_only_valid(alarm_visual_only_valid),
    .direction_valid(direction_command_valid),
    .direction_sector(direction_sector), .ws2812_dout(ws2812_dout),
    .vibration_motor(vibration_motor),
    .led(ws2812_status_led_unused),
    .active_action(ws2812_active_action_unused),
    .active_direction(ws2812_active_direction_unused)
);

endmodule
