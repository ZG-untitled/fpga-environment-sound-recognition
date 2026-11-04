`timescale 1ns / 1ps

// 512-point frame generator with a 320-sample hop.
//
// Sample rate: 16 kHz
// Frame length: 512 samples = 32 ms
// Hop length:   320 samples = 20 ms
// Overlap:      192 samples = 12 ms
//
// The module stores incoming PCM samples in a circular buffer.
// Once at least 512 samples are available, it emits one complete
// windowed frame. A new frame is emitted every 320 new samples.
module mic_frame_window (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     sample_valid,
    input  wire signed [23:0]       sample_in,

    output reg                      frame_start_pulse,
    output reg                      window_valid,
    output reg                      window_last,
    output reg [8:0]                window_index,
    output reg signed [31:0]        windowed_sample,

    output reg [15:0]               frame_sequence,
    output reg                      frame_busy,
    output reg                      frame_overrun
);

(* ram_style = "block" *)
reg signed [23:0] sample_memory [0:511];

(* rom_style = "block" *)
reg signed [15:0] hamming_memory [0:511];

initial begin
    $readmemh("hamming_512_q15.mem", hamming_memory);
end

reg [8:0] write_pointer;
reg [9:0] samples_available;
reg [8:0] hop_counter;

wire first_frame_due;
wire hop_frame_due;
wire frame_due;

assign first_frame_due =
    sample_valid &&
    (samples_available == 10'd511);

assign hop_frame_due =
    sample_valid &&
    (samples_available == 10'd512) &&
    (hop_counter == 9'd319);

assign frame_due =
    first_frame_due || hop_frame_due;

// Read pipeline
reg [8:0] read_address;
reg [8:0] request_index;

reg signed [23:0] sample_pipeline;
reg signed [15:0] coefficient_pipeline;
reg [8:0]         index_pipeline;
reg               pipeline_valid;

wire signed [39:0] multiplication_result;

assign multiplication_result =
    $signed(sample_pipeline) *
    $signed(coefficient_pipeline);

always @(posedge clk) begin
    if (!rst_n) begin
        write_pointer       <= 9'd0;
        samples_available   <= 10'd0;
        hop_counter         <= 9'd0;

        read_address        <= 9'd0;
        request_index       <= 9'd0;
        sample_pipeline     <= 24'sd0;
        coefficient_pipeline <= 16'sd0;
        index_pipeline      <= 9'd0;
        pipeline_valid      <= 1'b0;

        frame_start_pulse   <= 1'b0;
        window_valid        <= 1'b0;
        window_last         <= 1'b0;
        window_index        <= 9'd0;
        windowed_sample     <= 32'sd0;

        frame_sequence      <= 16'd0;
        frame_busy          <= 1'b0;
        frame_overrun       <= 1'b0;
    end else begin
        frame_start_pulse <= 1'b0;

        // Output the previous synchronous memory-read result.
        window_valid <= pipeline_valid;
        window_last  <= pipeline_valid &&
                        (index_pipeline == 9'd511);

        if (pipeline_valid) begin
            window_index <= index_pipeline;

            // Q1.15 coefficient multiplication.
            windowed_sample <= multiplication_result >>> 15;
        end

        // Store every new microphone sample.
        if (sample_valid) begin
            sample_memory[write_pointer] <= sample_in;
            write_pointer <= write_pointer + 9'd1;

            if (samples_available < 10'd512) begin
                samples_available <= samples_available + 10'd1;
            end

            if (first_frame_due) begin
                hop_counter <= 9'd0;
            end else if (samples_available == 10'd512) begin
                if (hop_counter == 9'd319) begin
                    hop_counter <= 9'd0;
                end else begin
                    hop_counter <= hop_counter + 9'd1;
                end
            end
        end

        // Start reading the oldest sample of the requested frame.
        // write_pointer+1 is the oldest entry after writing the
        // current newest sample.
        if (frame_due) begin
            if (frame_busy) begin
                frame_overrun <= 1'b1;
            end else begin
                read_address      <= write_pointer + 9'd1;
                request_index     <= 9'd0;
                frame_busy        <= 1'b1;
                frame_start_pulse <= 1'b1;
                frame_sequence    <= frame_sequence + 16'd1;
            end
        end

        // Read one frame sample and one coefficient per clock.
        if (frame_busy) begin
            sample_pipeline      <= sample_memory[read_address];
            coefficient_pipeline <= hamming_memory[request_index];
            index_pipeline       <= request_index;
            pipeline_valid       <= 1'b1;

            read_address <= read_address + 9'd1;

            if (request_index == 9'd511) begin
                frame_busy <= 1'b0;
            end else begin
                request_index <= request_index + 9'd1;
            end
        end else begin
            pipeline_valid <= 1'b0;
        end
    end
end

endmodule