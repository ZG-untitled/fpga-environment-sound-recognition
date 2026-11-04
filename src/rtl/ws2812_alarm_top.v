`timescale 1ns / 1ps

// Stage 17 WS2812 alarm renderer.
//
// The PS owns class mapping, confidence thresholds and confirmation policy.
// PL receives only a compact, already-confirmed action:
//   0 = idle, green breathing
//   1 = ordinary blue notification
//   2 = ordinary yellow notification
//   3 = emergency red indication
//
// KEY0 is kept as a local emergency acknowledge input. It clears the visual
// action without depending on the PS software or a UART connection.
module ws2812_alarm_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer LED_NUM     = 30,
    parameter integer BRIGHT_MAX  = 64
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key,
    input  wire        alarm_action_valid,
    input  wire [1:0]  alarm_action,
    output wire        ws2812_dout,
    output wire [2:0]  led,
    output wire [1:0]  active_action
);

localparam [1:0] ACTION_IDLE   = 2'd0;
localparam [1:0] ACTION_BLUE   = 2'd1;
localparam [1:0] ACTION_YELLOW = 2'd2;
localparam [1:0] ACTION_RED    = 2'd3;

// Synchronize and debounce the active-low confirmation key.
reg key_s0;
reg key_s1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_s0 <= 1'b1;
        key_s1 <= 1'b1;
    end else begin
        key_s0 <= key;
        key_s1 <= key_s0;
    end
end

localparam integer DEB_CNT = CLK_FREQ_HZ / 50;

reg [19:0] deb_cnt;
reg        key_stable;
reg        key_stable_d;
wire       key_press;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        deb_cnt    <= 20'd0;
        key_stable <= 1'b1;
    end else if (key_s1 != key_stable) begin
        if (deb_cnt >= DEB_CNT - 1) begin
            deb_cnt    <= 20'd0;
            key_stable <= key_s1;
        end else begin
            deb_cnt <= deb_cnt + 1'b1;
        end
    end else begin
        deb_cnt <= 20'd0;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        key_stable_d <= 1'b1;
    else
        key_stable_d <= key_stable;
end

assign key_press = key_stable_d & ~key_stable;

reg [1:0] action_latched;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        action_latched <= ACTION_IDLE;
    else if (key_press)
        action_latched <= ACTION_IDLE;
    else if (alarm_action_valid)
        action_latched <= alarm_action;
end

assign active_action = action_latched;

reg [26:0] pwm_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        pwm_cnt <= 27'd0;
    else
        pwm_cnt <= pwm_cnt + 1'b1;
end

wire [8:0] tri_raw = pwm_cnt[26:18];
wire [8:0] breath9 = tri_raw[8] ? (9'd511 - tri_raw) : tri_raw;
wire [7:0] breath  = breath9[7:0];
wire [7:0] strobe  = (pwm_cnt[23:21] < 3'd4) ? 8'hFF : 8'h00;

reg [LED_NUM*24-1:0] led_data;
reg [7:0] er;
reg [7:0] eg;
reg [7:0] eb;
integer i;

always @(*) begin
    led_data = {(LED_NUM*24){1'b0}};

    case (action_latched)
        ACTION_BLUE: begin
            er = 8'h00;
            eg = 8'h00;
            eb = strobe;
        end

        ACTION_YELLOW: begin
            er = breath;
            eg = breath;
            eb = 8'h00;
        end

        ACTION_RED: begin
            er = 8'hFF;
            eg = 8'h00;
            eb = 8'h00;
        end

        default: begin
            er = 8'h00;
            eg = breath;
            eb = 8'h00;
        end
    endcase

    for (i = 0; i < LED_NUM; i = i + 1)
        led_data[i*24 +: 24] = {eg, er, eb};
end

reg        drv_start;
wire       drv_busy;
reg [20:0] refresh_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        refresh_cnt <= 21'd0;
        drv_start   <= 1'b0;
    end else begin
        drv_start <= 1'b0;

        if (refresh_cnt >= CLK_FREQ_HZ/40 - 1) begin
            refresh_cnt <= 21'd0;
            if (!drv_busy)
                drv_start <= 1'b1;
        end else begin
            refresh_cnt <= refresh_cnt + 1'b1;
        end
    end
end

ws2812_driver #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .LED_NUM(LED_NUM),
    .BRIGHT_MAX(BRIGHT_MAX)
) u_ws2812_driver (
    .clk(clk),
    .rst_n(rst_n),
    .start(drv_start),
    .busy(drv_busy),
    .led_data(led_data),
    .dout(ws2812_dout)
);

// The three board LEDs are active low and provide a coarse state indicator.
assign led =
    (action_latched == ACTION_RED)    ? 3'b000 :
    (action_latched == ACTION_YELLOW) ? 3'b100 :
    (action_latched == ACTION_BLUE)   ? 3'b101 :
                                        3'b110;

endmodule
