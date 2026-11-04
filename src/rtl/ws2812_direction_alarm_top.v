`timescale 1ns / 1ps

// Combined Stage 17 alarm colour and Stage 22 source-direction renderer.
// direction_sector: 0 front, 2 right, 4 back, 6 left; odd values are diagonals.
module ws2812_direction_alarm_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer LED_NUM     = 30,
    parameter integer BRIGHT_MAX  = 64
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key,
    input  wire        alarm_action_valid,
    input  wire [1:0]  alarm_action,
    input  wire        alarm_visual_only_valid,
    input  wire        direction_valid,
    input  wire [2:0]  direction_sector,
    output wire        ws2812_dout,
    output wire        vibration_motor,
    output wire [2:0]  led,
    output wire [1:0]  active_action,
    output wire [2:0]  active_direction
);

localparam [1:0] ACTION_IDLE   = 2'd0;
localparam [1:0] ACTION_BLUE   = 2'd1;
localparam [1:0] ACTION_YELLOW = 2'd2;
localparam [1:0] ACTION_RED    = 2'd3;

reg key_s0;
reg key_s1;
localparam integer DEB_CNT = CLK_FREQ_HZ / 50;
reg [19:0] deb_cnt;
reg key_stable;
reg key_stable_d;
wire key_press = key_stable_d & ~key_stable;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_s0 <= 1'b1;
        key_s1 <= 1'b1;
    end else begin
        key_s0 <= key;
        key_s1 <= key_s0;
    end
end

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

reg [1:0] action_latched;
reg       vibration_allowed;
reg [2:0] direction_latched;
reg       direction_seen;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        action_latched <= ACTION_IDLE;
        vibration_allowed <= 1'b1;
    end else if (key_press) begin
        action_latched <= ACTION_IDLE;
        vibration_allowed <= 1'b1;
    end else if (alarm_visual_only_valid) begin
        action_latched <= ACTION_RED;
        vibration_allowed <= 1'b0;
    end else if (alarm_action_valid) begin
        action_latched <= alarm_action;
        vibration_allowed <= 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        direction_latched <= 3'd0;
        direction_seen    <= 1'b0;
    end else if (direction_valid) begin
        direction_latched <= direction_sector;
        direction_seen    <= 1'b1;
    end
end

assign active_action = action_latched;
assign active_direction = direction_latched;

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
reg [7:0] bg_r;
reg [7:0] bg_g;
reg [7:0] bg_b;
reg [7:0] selected_r;
reg [7:0] selected_g;
reg [7:0] selected_b;
integer i;

always @(*) begin
    case (action_latched)
        ACTION_BLUE: begin
            bg_r = 8'h00;
            bg_g = 8'h00;
            bg_b = 8'h08;
            selected_r = 8'h00;
            selected_g = 8'h00;
            selected_b = strobe;
        end
        ACTION_YELLOW: begin
            bg_r = 8'h10;
            bg_g = 8'h10;
            bg_b = 8'h00;
            selected_r = breath;
            selected_g = breath;
            selected_b = 8'h00;
        end
        ACTION_RED: begin
            bg_r = 8'h20;
            bg_g = 8'h00;
            bg_b = 8'h00;
            selected_r = 8'hFF;
            selected_g = 8'h00;
            selected_b = 8'h00;
        end
        default: begin
            bg_r = 8'h00;
            bg_g = breath >> 3;
            bg_b = 8'h00;
            selected_r = 8'h00;
            selected_g = breath;
            selected_b = breath;
        end
    endcase

    led_data = {(LED_NUM*24){1'b0}};
    for (i = 0; i < LED_NUM; i = i + 1) begin
        if (direction_seen && (((i * 8) / LED_NUM) == direction_latched))
            led_data[i*24 +: 24] = {selected_g, selected_r, selected_b};
        else
            led_data[i*24 +: 24] = {bg_g, bg_r, bg_b};
    end
end

reg drv_start;
wire drv_busy;
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

assign led =
    (action_latched == ACTION_RED)    ? 3'b000 :
    (action_latched == ACTION_YELLOW) ? 3'b100 :
    (action_latched == ACTION_BLUE)   ? 3'b101 :
                                        3'b110;

// Active-high vibration-module control.  The tested module's onboard driver
// makes 20 kHz duty-cycle levels feel nearly identical, so encode severity as
// unmistakable one-second tactile patterns instead:
// blue = one 200 ms pulse, yellow = two 200 ms pulses, red = continuous.
localparam integer VIBRATION_PATTERN_TICKS = CLK_FREQ_HZ;
localparam integer VIBRATION_PULSE_TICKS = CLK_FREQ_HZ / 5;
localparam integer VIBRATION_SECOND_START = (CLK_FREQ_HZ * 7) / 20;
localparam integer VIBRATION_SECOND_END = (CLK_FREQ_HZ * 11) / 20;

reg [31:0] vibration_pattern_count;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        vibration_pattern_count <= 32'd0;
    else if (key_press ||
             (alarm_action_valid && (alarm_action != action_latched)) ||
             alarm_visual_only_valid)
        vibration_pattern_count <= 32'd0;
    else if (vibration_pattern_count >= VIBRATION_PATTERN_TICKS - 1)
        vibration_pattern_count <= 32'd0;
    else
        vibration_pattern_count <= vibration_pattern_count + 1'b1;
end

assign vibration_motor = vibration_allowed &&
    ((action_latched == ACTION_RED) ? 1'b1 :
    (action_latched == ACTION_YELLOW) ?
        ((vibration_pattern_count < VIBRATION_PULSE_TICKS) ||
         ((vibration_pattern_count >= VIBRATION_SECOND_START) &&
          (vibration_pattern_count < VIBRATION_SECOND_END))) :
    (action_latched == ACTION_BLUE) ?
        (vibration_pattern_count < VIBRATION_PULSE_TICKS) :
        1'b0);

endmodule
