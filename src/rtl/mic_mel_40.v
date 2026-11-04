`timescale 1ns / 1ps

module mic_mel_40 (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               fft_valid,
    input  wire [8:0]         fft_bin,
    input  wire [51:0]        fft_power,

    output reg                mel_valid,
    output reg                mel_last,
    output reg [5:0]          mel_index,
    output reg [63:0]         mel_energy,

    output reg                mel_frame_done,
    output reg [5:0]          mel_peak_band,
    output reg [63:0]         mel_peak_energy,
    output reg [15:0]         mel_frame_count,
    output reg                mel_overrun
);

reg [5:0]  filter0_index_memory [0:256];
reg [15:0] filter0_weight_memory [0:256];
reg [5:0]  filter1_index_memory [0:256];
reg [15:0] filter1_weight_memory [0:256];

initial begin
    $readmemh("mel_filter0_index.mem", filter0_index_memory);
    $readmemh("mel_filter0_weight.mem", filter0_weight_memory);
    $readmemh("mel_filter1_index.mem", filter1_index_memory);
    $readmemh("mel_filter1_weight.mem", filter1_weight_memory);
end

reg [63:0] mel_accumulator [0:39];

wire [8:0] map_address;

assign map_address =
    (fft_bin <= 9'd256)
    ? fft_bin
    : 9'd0;

wire [5:0] filter0_index;
wire [5:0] filter1_index;
wire [15:0] filter0_weight;
wire [15:0] filter1_weight;

assign filter0_index =
    filter0_index_memory[map_address];

assign filter1_index =
    filter1_index_memory[map_address];

assign filter0_weight =
    filter0_weight_memory[map_address];

assign filter1_weight =
    filter1_weight_memory[map_address];

wire [67:0] filter0_product;
wire [67:0] filter1_product;
wire [63:0] filter0_contribution;
wire [63:0] filter1_contribution;

assign filter0_product =
    fft_power * filter0_weight;

assign filter1_product =
    fft_power * filter1_weight;

// Remove the Q1.15 coefficient fractional bits.
assign filter0_contribution =
    filter0_product >> 15;

assign filter1_contribution =
    filter1_product >> 15;

reg       output_active;
reg [5:0] output_counter;

reg [5:0]  peak_band_accumulator;
reg [63:0] peak_energy_accumulator;

integer i;

always @(posedge clk) begin
    if (!rst_n) begin
        for (i = 0; i < 40; i = i + 1) begin
            mel_accumulator[i] <= 64'd0;
        end

        output_active          <= 1'b0;
        output_counter         <= 6'd0;

        mel_valid              <= 1'b0;
        mel_last               <= 1'b0;
        mel_index              <= 6'd0;
        mel_energy             <= 64'd0;

        mel_frame_done         <= 1'b0;
        mel_peak_band          <= 6'd0;
        mel_peak_energy        <= 64'd0;
        mel_frame_count        <= 16'd0;
        mel_overrun            <= 1'b0;

        peak_band_accumulator  <= 6'd0;
        peak_energy_accumulator <= 64'd0;
    end else begin
        mel_valid      <= 1'b0;
        mel_last       <= 1'b0;
        mel_frame_done <= 1'b0;

        // Bin zero marks the start of a new natural-order FFT frame.
        // DC is intentionally excluded from the Mel energies.
        if (fft_valid && (fft_bin == 9'd0)) begin
            if (output_active) begin
                mel_overrun <= 1'b1;
            end

            for (i = 0; i < 40; i = i + 1) begin
                mel_accumulator[i] <= 64'd0;
            end
        end
        else if (
            fft_valid &&
            (fft_bin >= 9'd1) &&
            (fft_bin <= 9'd256)
        ) begin
            // Give every accumulator one statically indexed write path.
            // The former implementation made two variable-index writes to
            // the same unpacked array in one clock. RTL simulation handled
            // that correctly, but the synthesized board image consistently
            // lost bands 0 and 2. Fixed-index writes remove the ambiguous
            // multi-write inference while preserving the exact arithmetic.
            for (i = 0; i < 40; i = i + 1) begin
                if (
                    (filter0_index == i) ||
                    (filter1_index == i)
                ) begin
                    mel_accumulator[i] <=
                        mel_accumulator[i] +
                        ((filter0_index == i)
                            ? filter0_contribution
                            : 64'd0) +
                        ((filter1_index == i)
                            ? filter1_contribution
                            : 64'd0);
                end
            end

            if (fft_bin == 9'd256) begin
                output_active  <= 1'b1;
                output_counter <= 6'd0;
            end
        end

        // Stream the 40 completed Mel energies.
        if (output_active) begin
            mel_valid  <= 1'b1;
            mel_index  <= output_counter;
            mel_energy <= mel_accumulator[output_counter];

            if (output_counter == 6'd0) begin
                peak_band_accumulator <= 6'd0;
                peak_energy_accumulator <=
                    mel_accumulator[0];
            end
            else if (
                mel_accumulator[output_counter] >
                peak_energy_accumulator
            ) begin
                peak_band_accumulator <= output_counter;
                peak_energy_accumulator <=
                    mel_accumulator[output_counter];
            end

            if (output_counter == 6'd39) begin
                mel_last       <= 1'b1;
                mel_frame_done <= 1'b1;
                mel_frame_count <= mel_frame_count + 16'd1;
                output_active  <= 1'b0;

                if (
                    mel_accumulator[39] >
                    peak_energy_accumulator
                ) begin
                    mel_peak_band   <= 6'd39;
                    mel_peak_energy <= mel_accumulator[39];
                end else begin
                    mel_peak_band   <= peak_band_accumulator;
                    mel_peak_energy <= peak_energy_accumulator;
                end
            end else begin
                output_counter <= output_counter + 6'd1;
            end
        end
    end
end

endmodule
