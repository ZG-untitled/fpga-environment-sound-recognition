`timescale 1ns / 1ps

// Four synchronized INMP441 microphones.  CH0 feeds the proven Log-Mel
// pipeline; all four raw PCM channels are exposed to ILA for array bring-up.
module mic_test_top #(
    parameter integer INCLUDE_ILA = 1
) (
    input  wire sys_clk,
    input  wire rst_n,
    input  wire [3:0] mic_sd,
    output wire mic_bclk,
    output wire mic_ws,
    output wire led,
    input  wire        matrix_read_clk,
    input  wire [10:0] matrix_read_address,
    output wire [31:0] matrix_read_data
);

wire clk_audio;
wire pll_locked;
wire pair_capture_restart_request;

// Use the board's native 50 MHz PL clock directly.
// This avoids relying on the clock wizard/MMCM for the microphone test.
assign clk_audio = sys_clk;
assign pll_locked = 1'b1;
// Hold the microphone interface in reset briefly only at board startup.
// A verification capture must not restart BCLK/WS: doing so makes the
// INMP441 emit a large startup transient in the first two analysis frames.
reg [9:0] startup_count;
reg       mic_reset_n;

always @(posedge clk_audio) begin
    if (!rst_n || !pll_locked) begin
        startup_count <= 10'd0;
        mic_reset_n   <= 1'b0;
    end else if (!startup_count[9]) begin
        startup_count <= startup_count + 10'd1;
        mic_reset_n   <= 1'b0;
    end else begin
        mic_reset_n   <= 1'b1;
    end
end

// Restart only the frame/FFT/Mel/matrix processing chain for a paired
// capture.  The I2S receiver and microphone clocks remain continuous, so
// the first stored PCM sample is steady-state audio while still matching
// the freshly reset feature frame buffer exactly.
reg [4:0] processing_restart_count;
wire      processing_reset_n =
    mic_reset_n && (processing_restart_count == 5'd0);

always @(posedge clk_audio) begin
    if (!mic_reset_n) begin
        processing_restart_count <= 5'd0;
    end else if (pair_capture_restart_request) begin
        processing_restart_count <= 5'd31;
    end else if (processing_restart_count != 5'd0) begin
        processing_restart_count <= processing_restart_count - 5'd1;
    end
end

wire signed [23:0] pcm_sample;
wire signed [23:0] pcm_sample_ch0;
wire signed [23:0] pcm_sample_ch1;
wire signed [23:0] pcm_sample_ch2;
wire signed [23:0] pcm_sample_ch3;
wire               sample_valid;
wire [5:0]         frame_bit;
wire [3:0]         mic_sd_debug;

// Preserve the validated single-channel feature path while the new array is
// brought up.  Spatial fusion can be added after four-channel raw validation.
assign pcm_sample = pcm_sample_ch0;

i2s_mic_rx u_i2s_mic_rx (
    .clk_audio(clk_audio),
    .rst_n(mic_reset_n),
    .mic_sd(mic_sd),
    .mic_bclk(mic_bclk),
    .mic_ws(mic_ws),
    .pcm_sample_ch0(pcm_sample_ch0),
    .pcm_sample_ch1(pcm_sample_ch1),
    .pcm_sample_ch2(pcm_sample_ch2),
    .pcm_sample_ch3(pcm_sample_ch3),
    .sample_valid(sample_valid),
    .frame_bit(frame_bit),
    .mic_sd_debug(mic_sd_debug)
);

// Keep the PL LED lit for about 150 ms after a sample exceeds the threshold.
// This is only a quick physical activity indicator; ILA is the real check.
wire [23:0] sample_magnitude_ch0 = pcm_sample_ch0[23]
                                   ? (~pcm_sample_ch0 + 24'd1)
                                   : pcm_sample_ch0;
wire [23:0] sample_magnitude_ch1 = pcm_sample_ch1[23]
                                   ? (~pcm_sample_ch1 + 24'd1)
                                   : pcm_sample_ch1;
wire [23:0] sample_magnitude_ch2 = pcm_sample_ch2[23]
                                   ? (~pcm_sample_ch2 + 24'd1)
                                   : pcm_sample_ch2;
wire [23:0] sample_magnitude_ch3 = pcm_sample_ch3[23]
                                   ? (~pcm_sample_ch3 + 24'd1)
                                   : pcm_sample_ch3;
wire [23:0] sample_magnitude_max01 =
    (sample_magnitude_ch0 >= sample_magnitude_ch1)
    ? sample_magnitude_ch0 : sample_magnitude_ch1;
wire [23:0] sample_magnitude_max23 =
    (sample_magnitude_ch2 >= sample_magnitude_ch3)
    ? sample_magnitude_ch2 : sample_magnitude_ch3;
wire [23:0] sample_magnitude =
    (sample_magnitude_max01 >= sample_magnitude_max23)
    ? sample_magnitude_max01 : sample_magnitude_max23;
localparam [22:0] ACTIVITY_HOLD_CYCLES = 23'd7500000;
localparam [23:0] ACTIVITY_THRESHOLD   = 24'd200000;
reg [22:0] activity_count;

always @(posedge clk_audio) begin
    if (!mic_reset_n) begin
        activity_count <= 23'd0;
    end else if (sample_valid && (sample_magnitude >= ACTIVITY_THRESHOLD)) begin
        activity_count <= ACTIVITY_HOLD_CYCLES;
    end else if (activity_count != 23'd0) begin
        activity_count <= activity_count - 23'd1;
    end
end

assign led = (activity_count != 23'd0);


// ============================================================
// Stage 2: single-channel FIFO and 512-sample statistics window
// CH0 is connected to the real microphone.
// CH1..CH3 are reserved for later expansion.
wire signed [23:0] fifo_data_out;
wire [9:0]         fifo_level;
wire               fifo_overflow;
wire [23:0]        frame_peak;
wire [23:0]        frame_mean_abs;
wire               frame_done;
wire [3:0]         channel_present;

mic_stream_stats u_mic_stream_stats (
    .clk(clk_audio),
    .rst_n(processing_reset_n),
    .sample_valid(sample_valid),
    .sample_in(pcm_sample),

    .fifo_data_out(fifo_data_out),
    .fifo_level(fifo_level),
    .fifo_overflow(fifo_overflow),

    .frame_peak(frame_peak),
    .frame_mean_abs(frame_mean_abs),
    .frame_done(frame_done),
    .channel_present(channel_present)
);

// ============================================================
// Stage 3: 512-point frame buffer, 320-point hop and Hamming window
wire               window_frame_start;
wire               window_valid;
wire               window_last;
wire [8:0]         window_index;
wire signed [31:0] windowed_sample;
wire [15:0]        window_frame_sequence;
wire               window_frame_busy;
wire               window_frame_overrun;

mic_frame_window u_mic_frame_window (
    .clk(clk_audio),
    .rst_n(processing_reset_n),
    .sample_valid(sample_valid),
    .sample_in(pcm_sample),

    .frame_start_pulse(window_frame_start),
    .window_valid(window_valid),
    .window_last(window_last),
    .window_index(window_index),
    .windowed_sample(windowed_sample),

    .frame_sequence(window_frame_sequence),
    .frame_busy(window_frame_busy),
    .frame_overrun(window_frame_overrun)
);

// ============================================================
// Stage 4: 512-point FFT and power spectrum
wire               fft_config_done;
wire               fft_input_valid_debug;
wire               fft_input_ready_debug;
wire               fft_input_last_debug;
wire [8:0]         fft_input_index_debug;

wire               fft_output_valid_debug;
wire               fft_output_last_debug;
wire [8:0]         fft_bin_debug;
wire signed [31:0] fft_real_debug;
wire signed [31:0] fft_imag_debug;
wire [51:0]        fft_power_debug;

wire [8:0]         spectrum_peak_bin_debug;
wire [51:0]        spectrum_peak_power_debug;
wire               spectrum_frame_done_debug;

wire [10:0]        fft_fifo_level_debug;
wire               fft_input_overflow_debug;
wire               fft_protocol_error_debug;
wire [15:0]        fft_input_frame_count_debug;
wire [15:0]        fft_output_frame_count_debug;

mic_fft_512_stream u_mic_fft_512_stream (
    .clk(clk_audio),
    .rst_n(processing_reset_n),

    .window_valid(window_valid),
    .window_last(window_last),
    .windowed_sample(windowed_sample),

    .fft_config_done(fft_config_done),

    .fft_input_valid(fft_input_valid_debug),
    .fft_input_ready(fft_input_ready_debug),
    .fft_input_last(fft_input_last_debug),
    .fft_input_index(fft_input_index_debug),

    .fft_output_valid(fft_output_valid_debug),
    .fft_output_last(fft_output_last_debug),
    .fft_bin(fft_bin_debug),
    .fft_real(fft_real_debug),
    .fft_imag(fft_imag_debug),
    .fft_power(fft_power_debug),

    .spectrum_peak_bin(spectrum_peak_bin_debug),
    .spectrum_peak_power(spectrum_peak_power_debug),
    .spectrum_frame_done(spectrum_frame_done_debug),

    .fft_fifo_level(fft_fifo_level_debug),
    .fft_input_overflow(fft_input_overflow_debug),
    .fft_protocol_error(fft_protocol_error_debug),

    .fft_input_frame_count(fft_input_frame_count_debug),
    .fft_output_frame_count(fft_output_frame_count_debug)
);

// ============================================================
// Stage 5: 40-dimensional Mel filter bank
wire        mel_valid_debug;
wire        mel_last_debug;
wire [5:0]  mel_index_debug;
wire [63:0] mel_energy_debug;

wire        mel_frame_done_debug;
wire [5:0]  mel_peak_band_debug;
wire [63:0] mel_peak_energy_debug;
wire [15:0] mel_frame_count_debug;
wire        mel_overrun_debug;

mic_mel_40 u_mic_mel_40 (
    .clk(clk_audio),
    .rst_n(processing_reset_n),

    .fft_valid(fft_output_valid_debug),
    .fft_bin(fft_bin_debug),
    .fft_power(fft_power_debug),

    .mel_valid(mel_valid_debug),
    .mel_last(mel_last_debug),
    .mel_index(mel_index_debug),
    .mel_energy(mel_energy_debug),

    .mel_frame_done(mel_frame_done_debug),
    .mel_peak_band(mel_peak_band_debug),
    .mel_peak_energy(mel_peak_energy_debug),
    .mel_frame_count(mel_frame_count_debug),
    .mel_overrun(mel_overrun_debug)
);
// ============================================================
// Stage 6: fixed-point Log2 and 49 x 40 feature matrix
wire        logmel_valid_debug;
wire        logmel_last_debug;
wire [5:0]  logmel_frame_index_debug;
wire [5:0]  logmel_band_index_debug;
wire [15:0] logmel_value_debug;

wire        feature_matrix_done_debug;
wire [15:0] feature_matrix_sequence_debug;

wire        feature_matrix_stream_valid_debug;
wire        feature_matrix_stream_last_debug;
wire [10:0] feature_matrix_stream_address_debug;
wire [5:0]  feature_matrix_stream_frame_debug;
wire [5:0]  feature_matrix_stream_band_debug;
wire [15:0] feature_matrix_stream_value_debug;

wire        feature_matrix_overrun_debug;

wire [10:0] logmel_matrix_read_address;
wire [31:0] logmel_matrix_read_data;
wire        raw_snapshot_mode_debug;
wire [15:0] raw_snapshot_sequence_debug;
wire [31:0] raw_bridge_read_data;
wire [31:0] pair_capture_read_data;
wire        pair_capture_mode;
wire        pair_capture_ready_debug;
wire        pair_capture_error_debug;

mic_logmel_matrix u_mic_logmel_matrix (
        .matrix_read_clk(matrix_read_clk),
        .matrix_read_address(logmel_matrix_read_address),
        .matrix_read_data(logmel_matrix_read_data),
    .clk(clk_audio),
    .rst_n(processing_reset_n),

    .mel_valid(mel_valid_debug),
    .mel_last(mel_last_debug),
    .mel_index(mel_index_debug),
    .mel_energy(mel_energy_debug),

    .logmel_valid(logmel_valid_debug),
    .logmel_last(logmel_last_debug),
    .logmel_frame_index(logmel_frame_index_debug),
    .logmel_band_index(logmel_band_index_debug),
    .logmel_value(logmel_value_debug),

    .feature_matrix_done(feature_matrix_done_debug),
    .feature_matrix_sequence(feature_matrix_sequence_debug),

    .feature_matrix_stream_valid(
        feature_matrix_stream_valid_debug
    ),
    .feature_matrix_stream_last(
        feature_matrix_stream_last_debug
    ),
    .feature_matrix_stream_address(
        feature_matrix_stream_address_debug
    ),
    .feature_matrix_stream_frame(
        feature_matrix_stream_frame_debug
    ),
    .feature_matrix_stream_band(
        feature_matrix_stream_band_debug
    ),
    .feature_matrix_stream_value(
        feature_matrix_stream_value_debug
    ),

    .feature_matrix_overrun(
        feature_matrix_overrun_debug
    )
);
mic_raw_snapshot_bridge u_mic_raw_snapshot_bridge (
    .write_clk(clk_audio),
    .rst_n(mic_reset_n),
    .sample_valid(sample_valid),
    .pcm_sample_ch0(pcm_sample_ch0),
    .pcm_sample_ch1(pcm_sample_ch1),
    .pcm_sample_ch2(pcm_sample_ch2),
    .pcm_sample_ch3(pcm_sample_ch3),

    .read_clk(matrix_read_clk),
    .read_address(matrix_read_address),

    .logmel_read_address(logmel_matrix_read_address),
    .logmel_read_data(logmel_matrix_read_data),
    .read_data(raw_bridge_read_data),

    .raw_mode_debug(raw_snapshot_mode_debug),
    .snapshot_sequence_debug(raw_snapshot_sequence_debug)
);

// Stage 25 verification/runtime path.  It freezes the exact 15872 samples
// from all four microphones used by the first 49x40 ch0 feature matrix after
// reset, plus that matrix's replay stream.  Classification and localization
// can therefore use the same acoustic interval.
mic_frontend_pair_capture u_mic_frontend_pair_capture (
    .write_clk(clk_audio),
    .rst_n(rst_n),
    .frontend_ready(processing_reset_n),
    .sample_valid(sample_valid),
    .pcm_sample_ch0(pcm_sample_ch0),
    .pcm_sample_ch1(pcm_sample_ch1),
    .pcm_sample_ch2(pcm_sample_ch2),
    .pcm_sample_ch3(pcm_sample_ch3),

    .feature_stream_valid(feature_matrix_stream_valid_debug),
    .feature_stream_last(feature_matrix_stream_last_debug),
    .feature_stream_address(feature_matrix_stream_address_debug),
    .feature_stream_value(feature_matrix_stream_value_debug),
    .feature_matrix_sequence(feature_matrix_sequence_debug),

    .read_clk(matrix_read_clk),
    .read_address(matrix_read_address),
    .read_data(pair_capture_read_data),
    .pair_mode(pair_capture_mode),
    .capture_restart_request(pair_capture_restart_request),
    .pair_ready_debug(pair_capture_ready_debug),
    .pair_error_debug(pair_capture_error_debug)
);

assign matrix_read_data = pair_capture_mode
                          ? pair_capture_read_data
                          : raw_bridge_read_data;
// The testbench disables this branch.  Hardware synthesis keeps it enabled so
// the bitstream contains a ready-to-use ILA core.
generate
    if (INCLUDE_ILA != 0) begin : g_mic_ila
        ila_mic u_ila_mic (
            .clk(clk_audio),

            .probe0(fft_config_done),
            .probe1(fft_input_overflow_debug),
            .probe2(fft_protocol_error_debug),
            .probe3(mel_overrun_debug),

            .probe4(logmel_valid_debug),
            .probe5(logmel_last_debug),
            .probe6(logmel_frame_index_debug),
            .probe7(logmel_band_index_debug),
            .probe8(logmel_value_debug),

            .probe9(feature_matrix_done_debug),
            .probe10(feature_matrix_sequence_debug),

            .probe11(feature_matrix_stream_valid_debug),
            .probe12(feature_matrix_stream_last_debug),
            .probe13(feature_matrix_stream_address_debug),
            .probe14(feature_matrix_stream_frame_debug),
            .probe15(feature_matrix_stream_band_debug),
            .probe16(feature_matrix_stream_value_debug),

            .probe17(feature_matrix_overrun_debug),

            .probe18(spectrum_peak_bin_debug),
            .probe19(mel_peak_band_debug),
            .probe20(mel_frame_count_debug),
            .probe21(channel_present),
            .probe22(frame_peak),

            .probe23(sample_valid),
            .probe24(mic_sd_debug),
            .probe25(pcm_sample_ch0),
            .probe26(pcm_sample_ch1),
            .probe27(pcm_sample_ch2),
            .probe28(pcm_sample_ch3)
        );
    end
endgenerate

endmodule


// ============================================================
// Single-channel stream FIFO and 512-sample statistics.
//
// The FIFO is automatically drained in this test version. This verifies
// write/read/count/overflow operation before the PS or DMA reader is added.
// Frame statistics are produced once every 512 valid PCM samples.
module mic_stream_stats (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     sample_valid,
    input  wire signed [23:0]       sample_in,

    output reg signed [23:0]        fifo_data_out,
    output wire [9:0]               fifo_level,
    output reg                      fifo_overflow,

    output reg [23:0]               frame_peak,
    output reg [23:0]               frame_mean_abs,
    output reg                      frame_done,
    output wire [3:0]               channel_present
);

localparam integer FIFO_DEPTH = 512;
localparam integer ADDR_WIDTH = 9;

(* ram_style = "block" *)
reg signed [23:0] fifo_mem [0:FIFO_DEPTH-1];

reg [ADDR_WIDTH-1:0] fifo_write_ptr;
reg [ADDR_WIDTH-1:0] fifo_read_ptr;
reg [ADDR_WIDTH:0]   fifo_count;

wire fifo_empty;
wire fifo_full;
wire fifo_read_enable;
wire fifo_write_enable;

assign fifo_empty = (fifo_count == 10'd0);
assign fifo_full  = (fifo_count == 10'd512);

// Temporary automatic consumer.
// It will later be replaced by the PS/AXI/DMA read request.
assign fifo_read_enable =
    !fifo_empty;

assign fifo_write_enable =
    sample_valid && (!fifo_full || fifo_read_enable);

assign fifo_level = fifo_count;

// Stage 8 hardware configuration has four independent synchronized SD inputs.
assign channel_present = 4'b1111;

always @(posedge clk) begin
    if (!rst_n) begin
        fifo_write_ptr <= 9'd0;
        fifo_read_ptr  <= 9'd0;
        fifo_count     <= 10'd0;
        fifo_data_out  <= 24'sd0;
        fifo_overflow  <= 1'b0;
    end else begin
        if (fifo_write_enable) begin
            fifo_mem[fifo_write_ptr] <= sample_in;
            fifo_write_ptr <= fifo_write_ptr + 9'd1;
        end

        if (fifo_read_enable) begin
            fifo_data_out <= fifo_mem[fifo_read_ptr];
            fifo_read_ptr <= fifo_read_ptr + 9'd1;
        end

        case ({fifo_write_enable, fifo_read_enable})
            2'b10: fifo_count <= fifo_count + 10'd1;
            2'b01: fifo_count <= fifo_count - 10'd1;
            default: fifo_count <= fifo_count;
        endcase

        if (sample_valid && fifo_full && !fifo_read_enable) begin
            fifo_overflow <= 1'b1;
        end
    end
end

// ------------------------------------------------------------
// Statistics over each group of 512 valid samples

reg [8:0]  frame_sample_count;
reg [23:0] peak_accumulator;
reg [32:0] absolute_sum_accumulator;

wire [23:0] sample_absolute;
wire [23:0] next_peak;
wire [32:0] next_absolute_sum;

assign sample_absolute =
    sample_in[23]
    ? (~sample_in + 24'd1)
    : sample_in;

assign next_peak =
    (sample_absolute > peak_accumulator)
    ? sample_absolute
    : peak_accumulator;

assign next_absolute_sum =
    absolute_sum_accumulator + {9'd0, sample_absolute};

always @(posedge clk) begin
    if (!rst_n) begin
        frame_sample_count       <= 9'd0;
        peak_accumulator         <= 24'd0;
        absolute_sum_accumulator <= 33'd0;

        frame_peak               <= 24'd0;
        frame_mean_abs           <= 24'd0;
        frame_done               <= 1'b0;
    end else begin
        frame_done <= 1'b0;

        if (sample_valid) begin
            if (frame_sample_count == 9'd511) begin
                frame_peak     <= next_peak;
                frame_mean_abs <= next_absolute_sum[32:9];
                frame_done     <= 1'b1;

                frame_sample_count       <= 9'd0;
                peak_accumulator         <= 24'd0;
                absolute_sum_accumulator <= 33'd0;
            end else begin
                frame_sample_count       <= frame_sample_count + 9'd1;
                peak_accumulator         <= next_peak;
                absolute_sum_accumulator <= next_absolute_sum;
            end
        end
    end
end

endmodule
