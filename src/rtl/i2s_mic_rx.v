`timescale 1ns / 1ps

// Four-channel INMP441 I2S receiver.
//
// 输入时钟：50 MHz
// BCLK平均频率：1.024 MHz
// WS频率：16 kHz
// All four microphones share BCLK/WS.  Each microphone has an independent
// SD wire and its L/R pin is tied low, so all four samples are captured from
// the left slot on the same clock edge.
module i2s_mic_rx (
    input  wire              clk_audio,
    input  wire              rst_n,
    input  wire [3:0]        mic_sd,

    output wire              mic_bclk,
    output reg               mic_ws,

    output reg signed [23:0] pcm_sample_ch0,
    output reg signed [23:0] pcm_sample_ch1,
    output reg signed [23:0] pcm_sample_ch2,
    output reg signed [23:0] pcm_sample_ch3,
    output reg               sample_valid,
    output reg [5:0]         frame_bit,
    output wire [3:0]        mic_sd_debug
);

// 50 MHz × 128 / 3125 = 2.048 MHz边沿频率
// BCLK每两个边沿形成一个周期，所以BCLK为1.024 MHz
reg [11:0] edge_acc;
reg        mic_bclk_reg;

wire bclk_toggle;
wire bclk_rise;
wire bclk_fall;

assign bclk_toggle = (edge_acc >= 12'd2997);
assign bclk_rise   = bclk_toggle && !mic_bclk_reg;
assign bclk_fall   = bclk_toggle &&  mic_bclk_reg;

(* ASYNC_REG = "TRUE" *) reg [3:0] mic_sd_meta;
(* ASYNC_REG = "TRUE" *) reg [3:0] mic_sd_sync;

reg [23:0] shift_reg_ch0;
reg [23:0] shift_reg_ch1;
reg [23:0] shift_reg_ch2;
reg [23:0] shift_reg_ch3;

assign mic_bclk     = mic_bclk_reg;
assign mic_sd_debug = mic_sd_sync;

always @(posedge clk_audio) begin
    if (!rst_n) begin
        edge_acc     <= 12'd0;
        mic_bclk_reg <= 1'b0;

        mic_ws       <= 1'b1;
        frame_bit    <= 6'd63;

        mic_sd_meta  <= 4'b0000;
        mic_sd_sync  <= 4'b0000;

        shift_reg_ch0 <= 24'd0;
        shift_reg_ch1 <= 24'd0;
        shift_reg_ch2 <= 24'd0;
        shift_reg_ch3 <= 24'd0;
        pcm_sample_ch0 <= 24'sd0;
        pcm_sample_ch1 <= 24'sd0;
        pcm_sample_ch2 <= 24'sd0;
        pcm_sample_ch3 <= 24'sd0;
        sample_valid <= 1'b0;
    end else begin
        mic_sd_meta  <= mic_sd;
        mic_sd_sync  <= mic_sd_meta;
        sample_valid <= 1'b0;

        // 分数分频：
        // 单个BCLK半周期为24或25个50 MHz时钟周期，
        // 长期平均频率精确为1.024 MHz。
        if (bclk_toggle) begin
            edge_acc     <= edge_acc - 12'd2997;
            mic_bclk_reg <= ~mic_bclk_reg;
        end else begin
            edge_acc <= edge_acc + 12'd128;
        end

        // 在BCLK下降沿更新WS和帧内位编号
        if (bclk_fall) begin
            if (frame_bit == 6'd63) begin
                frame_bit <= 6'd0;
                mic_ws    <= 1'b0;
            end else begin
                frame_bit <= frame_bit + 6'd1;
                mic_ws    <= ((frame_bit + 6'd1) >= 6'd32);
            end
        end

        // I2S在WS变化后有一个延迟位
        // 左声道有效数据位为frame_bit 1至24
        if (
            bclk_rise &&
            !mic_ws &&
            (frame_bit >= 6'd1) &&
            (frame_bit <= 6'd24)
        ) begin
            shift_reg_ch0 <= {shift_reg_ch0[22:0], mic_sd_sync[0]};
            shift_reg_ch1 <= {shift_reg_ch1[22:0], mic_sd_sync[1]};
            shift_reg_ch2 <= {shift_reg_ch2[22:0], mic_sd_sync[2]};
            shift_reg_ch3 <= {shift_reg_ch3[22:0], mic_sd_sync[3]};

            if (frame_bit == 6'd24) begin
                pcm_sample_ch0 <= {shift_reg_ch0[22:0], mic_sd_sync[0]};
                pcm_sample_ch1 <= {shift_reg_ch1[22:0], mic_sd_sync[1]};
                pcm_sample_ch2 <= {shift_reg_ch2[22:0], mic_sd_sync[2]};
                pcm_sample_ch3 <= {shift_reg_ch3[22:0], mic_sd_sync[3]};
                sample_valid <= 1'b1;
            end
        end
    end
end

endmodule
