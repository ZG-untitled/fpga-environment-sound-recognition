`timescale 1ns / 1ps

module mic_fft_512_stream (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     window_valid,
    input  wire                     window_last,
    input  wire signed [31:0]       windowed_sample,

    output wire                     fft_config_done,

    output wire                     fft_input_valid,
    output wire                     fft_input_ready,
    output wire                     fft_input_last,
    output reg [8:0]                fft_input_index,

    output reg                      fft_output_valid,
    output reg                      fft_output_last,
    output reg [8:0]                fft_bin,
    output reg signed [31:0]        fft_real,
    output reg signed [31:0]        fft_imag,
    output reg [51:0]               fft_power,

    output reg [8:0]                spectrum_peak_bin,
    output reg [51:0]               spectrum_peak_power,
    output reg                      spectrum_frame_done,

    output wire [10:0]              fft_fifo_level,
    output reg                      fft_input_overflow,
    output reg                      fft_protocol_error,

    output reg [15:0]               fft_input_frame_count,
    output reg [15:0]               fft_output_frame_count
);

// ------------------------------------------------------------
// Convert signed 24-bit microphone range to signed 16-bit FFT input.
// The Hamming result is held in 32 bits, but valid audio occupies
// the signed 24-bit range. Dropping eight LSBs prevents overflow.

wire signed [15:0] scaled_window_sample;

assign scaled_window_sample = windowed_sample[23:8];

// ------------------------------------------------------------
// 1024-entry FIFO between the fixed-rate window generator and
// the AXI-Stream FFT input.

reg [16:0] fft_input_memory [0:1023];

reg [9:0]  fifo_write_pointer;
reg [9:0]  fifo_read_pointer;
reg [10:0] fifo_count;

reg               axis_input_valid;
reg signed [15:0] axis_input_sample;
reg               axis_input_last;

wire fifo_empty;
wire fifo_full;
wire fifo_push;
wire fifo_pop;

assign fifo_empty = (fifo_count == 11'd0);
assign fifo_full  = (fifo_count == 11'd1024);

assign fft_fifo_level = fifo_count;

assign fifo_push =
    window_valid &&
    (!fifo_full || fifo_pop);

assign fifo_pop =
    fft_config_done &&
    (!axis_input_valid || fft_input_ready) &&
    !fifo_empty;

assign fft_input_valid = axis_input_valid;
assign fft_input_last  = axis_input_last;

always @(posedge clk) begin
    if (!rst_n) begin
        fifo_write_pointer   <= 10'd0;
        fifo_read_pointer    <= 10'd0;
        fifo_count           <= 11'd0;

        axis_input_valid     <= 1'b0;
        axis_input_sample    <= 16'sd0;
        axis_input_last      <= 1'b0;

        fft_input_index      <= 9'd0;
        fft_input_overflow   <= 1'b0;
        fft_input_frame_count <= 16'd0;
    end else begin
        if (fifo_push) begin
            fft_input_memory[fifo_write_pointer] <= {
                window_last,
                scaled_window_sample
            };

            fifo_write_pointer <= fifo_write_pointer + 10'd1;
        end

        if (axis_input_valid && fft_input_ready) begin
            axis_input_valid <= 1'b0;

            if (axis_input_last) begin
                fft_input_index <= 9'd0;
                fft_input_frame_count <=
                    fft_input_frame_count + 16'd1;
            end else begin
                fft_input_index <= fft_input_index + 9'd1;
            end
        end

        if (fifo_pop) begin
            {
                axis_input_last,
                axis_input_sample
            } <= fft_input_memory[fifo_read_pointer];

            fifo_read_pointer <= fifo_read_pointer + 10'd1;
            axis_input_valid  <= 1'b1;
        end

        case ({fifo_push, fifo_pop})
            2'b10: fifo_count <= fifo_count + 11'd1;
            2'b01: fifo_count <= fifo_count - 11'd1;
            default: fifo_count <= fifo_count;
        endcase

        if (window_valid && fifo_full && !fifo_pop) begin
            fft_input_overflow <= 1'b1;
        end
    end
end

// ------------------------------------------------------------
// FFT configuration channel.
// 8'h01 selects forward FFT. Configuration is sent once after reset.

reg config_valid;
reg config_complete;
wire config_ready;

assign fft_config_done = config_complete;

always @(posedge clk) begin
    if (!rst_n) begin
        config_valid    <= 1'b1;
        config_complete <= 1'b0;
    end else if (config_valid && config_ready) begin
        config_valid    <= 1'b0;
        config_complete <= 1'b1;
    end
end

// ------------------------------------------------------------
// Xilinx 512-point FFT IP

wire [63:0] fft_output_data;
wire [15:0] fft_output_user;
wire        fft_output_axis_valid;
wire        fft_output_axis_last;

wire event_frame_started;
wire event_tlast_unexpected;
wire event_tlast_missing;
wire event_status_channel_halt;
wire event_data_in_channel_halt;
wire event_data_out_channel_halt;

xfft_mic_512 u_xfft_mic_512 (
    .aclk(clk),
    .aresetn(rst_n),

    .s_axis_config_tdata(8'h01),
    .s_axis_config_tvalid(config_valid),
    .s_axis_config_tready(config_ready),

    .s_axis_data_tdata({
        16'h0000,
        axis_input_sample
    }),
    .s_axis_data_tvalid(axis_input_valid),
    .s_axis_data_tready(fft_input_ready),
    .s_axis_data_tlast(axis_input_last),

    .m_axis_data_tdata(fft_output_data),
    .m_axis_data_tuser(fft_output_user),
    .m_axis_data_tvalid(fft_output_axis_valid),
    .m_axis_data_tready(1'b1),
    .m_axis_data_tlast(fft_output_axis_last),

    .event_frame_started(event_frame_started),
    .event_tlast_unexpected(event_tlast_unexpected),
    .event_tlast_missing(event_tlast_missing),
    .event_status_channel_halt(event_status_channel_halt),
    .event_data_in_channel_halt(event_data_in_channel_halt),
    .event_data_out_channel_halt(event_data_out_channel_halt)
);

// Each 26-bit FFT component is sign-extended into a 32-bit AXI field.
wire signed [31:0] current_real;
wire signed [31:0] current_imag;

assign current_real = fft_output_data[31:0];
assign current_imag = fft_output_data[63:32];

wire signed [63:0] current_real_square;
wire signed [63:0] current_imag_square;
wire [51:0] current_power;

assign current_real_square =
    current_real * current_real;

assign current_imag_square =
    current_imag * current_imag;

assign current_power =
    {1'b0, current_real_square[50:0]} +
    {1'b0, current_imag_square[50:0]};

// ------------------------------------------------------------
// Output capture and positive-frequency peak detector.
// For real audio, bins 1 through 255 are searched; bin zero is
// ignored to prevent DC offset from becoming the detected peak.

reg [8:0]  peak_bin_accumulator;
reg [51:0] peak_power_accumulator;

always @(posedge clk) begin
    if (!rst_n) begin
        fft_output_valid       <= 1'b0;
        fft_output_last        <= 1'b0;
        fft_bin                <= 9'd0;
        fft_real               <= 32'sd0;
        fft_imag               <= 32'sd0;
        fft_power              <= 52'd0;

        peak_bin_accumulator   <= 9'd0;
        peak_power_accumulator <= 52'd0;
        spectrum_peak_bin      <= 9'd0;
        spectrum_peak_power    <= 52'd0;
        spectrum_frame_done    <= 1'b0;

        fft_protocol_error     <= 1'b0;
        fft_output_frame_count <= 16'd0;
    end else begin
        fft_output_valid    <= fft_output_axis_valid;
        fft_output_last     <=
            fft_output_axis_valid &&
            fft_output_axis_last;

        spectrum_frame_done <= 1'b0;

        if (fft_output_axis_valid) begin
            fft_bin   <= fft_output_user[8:0];
            fft_real  <= current_real;
            fft_imag  <= current_imag;
            fft_power <= current_power;

            if (fft_output_user[8:0] == 9'd0) begin
                peak_bin_accumulator   <= 9'd0;
                peak_power_accumulator <= 52'd0;
            end else if (
                (fft_output_user[8:0] <= 9'd255) &&
                (current_power > peak_power_accumulator)
            ) begin
                peak_bin_accumulator   <= fft_output_user[8:0];
                peak_power_accumulator <= current_power;
            end

            if (fft_output_axis_last) begin
                spectrum_peak_bin   <= peak_bin_accumulator;
                spectrum_peak_power <= peak_power_accumulator;
                spectrum_frame_done <= 1'b1;

                fft_output_frame_count <=
                    fft_output_frame_count + 16'd1;
            end
        end

        if (
            event_tlast_unexpected ||
            event_tlast_missing ||
            event_status_channel_halt ||
            event_data_in_channel_halt ||
            event_data_out_channel_halt
        ) begin
            fft_protocol_error <= 1'b1;
        end
    end
end

endmodule