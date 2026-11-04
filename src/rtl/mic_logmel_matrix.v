`timescale 1ns / 1ps

// Converts each 64-bit Mel energy to an unsigned Log2 Q8.8 value.
//
// One complete feature matrix contains:
//   49 time frames x 40 Mel bands = 1960 values.
//
// Each value is also mirrored to feature_matrix_stream_* while it is written.
// This keeps feature_memory as a true two-port RAM (audio-domain write plus
// PS-domain read).  A previous automatic replay added a third memory port,
// forcing Vivado to expand the matrix into LUTRAM on hardware.
module mic_logmel_matrix (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        mel_valid,
    input  wire        mel_last,
    input  wire [5:0]  mel_index,
    input  wire [63:0] mel_energy,

    input  wire        matrix_read_clk,
    input  wire [10:0] matrix_read_address,
    output reg  [31:0] matrix_read_data,
    output reg         logmel_valid,
    output reg         logmel_last,
    output reg [5:0]   logmel_frame_index,
    output reg [5:0]   logmel_band_index,
    output reg [15:0]  logmel_value,

    output reg         feature_matrix_done,
    output reg [15:0]  feature_matrix_sequence,

    output reg         feature_matrix_stream_valid,
    output reg         feature_matrix_stream_last,
    output reg [10:0]  feature_matrix_stream_address,
    output reg [5:0]   feature_matrix_stream_frame,
    output reg [5:0]   feature_matrix_stream_band,
    output reg [15:0]  feature_matrix_stream_value,

    output reg         feature_matrix_overrun
);

localparam integer FRAME_COUNT        = 49;
localparam integer MEL_BAND_COUNT     = 40;
localparam integer MATRIX_VALUE_COUNT = 1960;

reg [7:0] log2_fraction_memory [0:255];

initial begin
    $readmemh("log2_fraction_q8.mem", log2_fraction_memory);
end

// Return the location of the highest set bit.
// This is the integer part of Log2.
function [5:0] highest_set_bit;
    input [63:0] value;
    integer bit_index;
    begin
        highest_set_bit = 6'd0;

        for (bit_index = 0;
             bit_index < 64;
             bit_index = bit_index + 1) begin

            if (value[bit_index]) begin
                highest_set_bit = bit_index;
            end
        end
    end
endfunction

// Extract the eight bits following the leading one.
// These bits address the Log2 fractional lookup table.
function [7:0] make_fraction_address;
    input [63:0] value;
    input [5:0]  leading_position;
    reg [63:0] normalized_value;
    begin
        if (leading_position >= 6'd8) begin
            normalized_value =
                value >> (leading_position - 6'd8);
        end else begin
            normalized_value =
                value << (6'd8 - leading_position);
        end

        make_fraction_address = normalized_value[7:0];
    end
endfunction

wire [5:0] energy_exponent;

assign energy_exponent =
    highest_set_bit(mel_energy);

wire [7:0] fraction_address;

assign fraction_address =
    make_fraction_address(
        mel_energy,
        energy_exponent
    );

wire [7:0] log2_fraction;

assign log2_fraction =
    log2_fraction_memory[fraction_address];

// Unsigned Log2 Q8.8:
// upper byte = integer exponent
// lower byte = fractional Log2 lookup result
wire [15:0] log2_value;

assign log2_value =
    (mel_energy == 64'd0)
    ? 16'd0
    : (
        {2'b00, energy_exponent, 8'b0}
        + {8'd0, log2_fraction}
      );

// Vivado should infer block RAM for the 1960 x 16-bit matrix.
(* ram_style = "block" *)
reg [15:0] feature_memory [0:MATRIX_VALUE_COUNT-1];

reg [5:0]  capture_frame_index;
reg [5:0]  expected_band_index;
reg [10:0] write_address;

always @(posedge clk) begin
    if (!rst_n) begin
        logmel_valid                 <= 1'b0;
        logmel_last                  <= 1'b0;
        logmel_frame_index           <= 6'd0;
        logmel_band_index            <= 6'd0;
        logmel_value                 <= 16'd0;

        feature_matrix_done          <= 1'b0;
        feature_matrix_sequence      <= 16'd0;

        feature_matrix_stream_valid  <= 1'b0;
        feature_matrix_stream_last   <= 1'b0;
        feature_matrix_stream_address <= 11'd0;
        feature_matrix_stream_frame  <= 6'd0;
        feature_matrix_stream_band   <= 6'd0;
        feature_matrix_stream_value  <= 16'd0;

        feature_matrix_overrun       <= 1'b0;

        capture_frame_index          <= 6'd0;
        expected_band_index          <= 6'd0;
        write_address                <= 11'd0;

    end else begin
        logmel_valid                <= 1'b0;
        logmel_last                 <= 1'b0;
        feature_matrix_done         <= 1'b0;
        feature_matrix_stream_valid <= 1'b0;
        feature_matrix_stream_last  <= 1'b0;

        // ----------------------------------------------------
        // Receive one 40-dimensional Mel frame.
        // ----------------------------------------------------
        if (mel_valid) begin
            if (mel_index != expected_band_index) begin
                feature_matrix_overrun <= 1'b1;
            end

            if (mel_last != (mel_index == 6'd39)) begin
                feature_matrix_overrun <= 1'b1;
            end

            logmel_valid       <= 1'b1;
            logmel_last        <= mel_last;
            logmel_frame_index <= capture_frame_index;
            logmel_band_index  <= mel_index;
            logmel_value       <= log2_value;

            feature_matrix_stream_valid   <= 1'b1;
            feature_matrix_stream_last    <=
                (capture_frame_index == 6'd48) && mel_last;
            feature_matrix_stream_address <= write_address;
            feature_matrix_stream_frame   <= capture_frame_index;
            feature_matrix_stream_band    <= mel_index;
            feature_matrix_stream_value   <= log2_value;

            if (write_address < 11'd1960) begin
                feature_memory[write_address] <= log2_value;
            end else begin
                feature_matrix_overrun <= 1'b1;
            end

            if (mel_last) begin
                expected_band_index <= 6'd0;

                if (capture_frame_index == 6'd48) begin
                    feature_matrix_done     <= 1'b1;
                    feature_matrix_sequence <=
                        feature_matrix_sequence + 16'd1;

                    capture_frame_index <= 6'd0;
                    write_address       <= 11'd0;
                end else begin
                    capture_frame_index <=
                        capture_frame_index + 6'd1;

                    write_address <=
                        write_address + 11'd1;
                end
            end else begin
                expected_band_index <=
                    expected_band_index + 6'd1;

                write_address <=
                    write_address + 11'd1;
            end
        end
    end
end


// ------------------------------------------------------------
// Independent PS-side read port.
//
// The feature RAM is written in the audio clock domain and read
// in the PS FCLK0 domain. Vivado can infer a true dual-clock,
// dual-port block RAM.
//
// AXI GPIO writes matrix_read_address. One matrix_read_clk later,
// matrix_read_data contains the requested value and matrix number.
// ------------------------------------------------------------
reg [15:0] matrix_sequence_meta;
reg [15:0] matrix_sequence_sync;
reg [15:0] feature_memory_read_data;
wire [10:0] feature_memory_read_address;

assign feature_memory_read_address =
    (matrix_read_address < 11'd1960)
    ? matrix_read_address
    : 11'd0;

// Keep the BRAM read itself in a dedicated, reset-free clocked process.
// Resetting or combining this register with unrelated output fields prevents
// Vivado from matching its simple-dual-port block-RAM inference template.
always @(posedge matrix_read_clk) begin
    feature_memory_read_data <=
        feature_memory[feature_memory_read_address];
end

always @(posedge matrix_read_clk) begin
    if (!rst_n) begin
        matrix_sequence_meta <= 16'd0;
        matrix_sequence_sync <= 16'd0;
        matrix_read_data     <= 32'd0;
    end else begin
        matrix_sequence_meta <= feature_matrix_sequence;
        matrix_sequence_sync <= matrix_sequence_meta;

        if (matrix_read_address < 11'd1960) begin
            matrix_read_data <= {
                matrix_sequence_sync,
                feature_memory_read_data
            };
        end else begin
            matrix_read_data <= {
                matrix_sequence_sync,
                16'd0
            };
        end
    end
end
endmodule
