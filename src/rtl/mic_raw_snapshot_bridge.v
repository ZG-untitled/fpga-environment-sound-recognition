`timescale 1ns / 1ps

// Four-channel 512-sample PCM snapshot bridge.
//
// Normal mode:
//   addresses 0..1959 retain the existing Log-Mel matrix interface.
//
// Raw snapshot mode:
//   write/read address 2047 to enter and latch the latest complete frame.
//   addresses   0..511  = {ch1[23:8], ch0[23:8]}
//   addresses 512..1023 = {ch3[23:8], ch2[23:8]}
//   address 2044        = signature 0x4d494334 ("MIC4")
//   address 2045        = {sequence[15:0], 15'd0, captured_bank}
//   address 2046        = leave raw mode.
//
// Samples are exported as signed 16-bit PCM. The reader latches a completed
// bank while the audio writer continues filling the alternate ping-pong bank.
module mic_raw_snapshot_bridge (
    input  wire               write_clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [23:0] pcm_sample_ch0,
    input  wire signed [23:0] pcm_sample_ch1,
    input  wire signed [23:0] pcm_sample_ch2,
    input  wire signed [23:0] pcm_sample_ch3,

    input  wire               read_clk,
    input  wire [10:0]        read_address,

    output wire [10:0]        logmel_read_address,
    input  wire [31:0]        logmel_read_data,
    output reg  [31:0]        read_data,

    output wire               raw_mode_debug,
    output wire [15:0]        snapshot_sequence_debug
);

localparam [10:0] RAW_SIGNATURE_ADDRESS = 11'd2044;
localparam [10:0] RAW_METADATA_ADDRESS  = 11'd2045;
localparam [10:0] RAW_EXIT_ADDRESS      = 11'd2046;
localparam [10:0] RAW_ENTER_ADDRESS     = 11'd2047;

(* ram_style = "block" *) reg [31:0] bank0_pair01 [0:511];
(* ram_style = "block" *) reg [31:0] bank0_pair23 [0:511];
(* ram_style = "block" *) reg [31:0] bank1_pair01 [0:511];
(* ram_style = "block" *) reg [31:0] bank1_pair23 [0:511];

reg [8:0]  write_index;
reg        write_bank;
reg        completed_bank;
reg [15:0] completed_sequence;

reg raw_mode;
reg raw_mode_write_meta;
reg raw_mode_write_sync;

reg        completed_bank_meta;
reg        completed_bank_sync;
reg [15:0] completed_sequence_meta;
reg [15:0] completed_sequence_sync;

reg        snapshot_bank;
reg [15:0] snapshot_sequence;

assign logmel_read_address       = read_address;
assign raw_mode_debug            = raw_mode;
assign snapshot_sequence_debug   = snapshot_sequence;

// Synchronize the read-domain freeze request into the audio domain.
always @(posedge write_clk) begin
    if (!rst_n) begin
        raw_mode_write_meta <= 1'b0;
        raw_mode_write_sync <= 1'b0;
    end else begin
        raw_mode_write_meta <= raw_mode;
        raw_mode_write_sync <= raw_mode_write_meta;
    end
end

// Continuously capture complete synchronized four-channel frames.
always @(posedge write_clk) begin
    if (!rst_n) begin
        write_index        <= 9'd0;
        write_bank         <= 1'b0;
        completed_bank     <= 1'b0;
        completed_sequence <= 16'd0;
    end else if (sample_valid) begin
        if (write_bank == 1'b0) begin
            bank0_pair01[write_index] <= {
                pcm_sample_ch1[23:8],
                pcm_sample_ch0[23:8]
            };
            bank0_pair23[write_index] <= {
                pcm_sample_ch3[23:8],
                pcm_sample_ch2[23:8]
            };
        end else begin
            bank1_pair01[write_index] <= {
                pcm_sample_ch1[23:8],
                pcm_sample_ch0[23:8]
            };
            bank1_pair23[write_index] <= {
                pcm_sample_ch3[23:8],
                pcm_sample_ch2[23:8]
            };
        end

        if (write_index == 9'd511) begin
            completed_bank     <= write_bank;
            completed_sequence <= completed_sequence + 16'd1;
            write_bank         <= ~write_bank;
            write_index        <= 9'd0;
        end else begin
            write_index <= write_index + 9'd1;
        end
    end
end

// Synchronize completed-frame metadata into the PS read-clock domain.
always @(posedge read_clk) begin
    if (!rst_n) begin
        completed_bank_meta      <= 1'b0;
        completed_bank_sync      <= 1'b0;
        completed_sequence_meta  <= 16'd0;
        completed_sequence_sync  <= 16'd0;
    end else begin
        completed_bank_meta      <= completed_bank;
        completed_bank_sync      <= completed_bank_meta;
        completed_sequence_meta  <= completed_sequence;
        completed_sequence_sync  <= completed_sequence_meta;
    end
end

// Read mux and raw-mode command handling.
always @(posedge read_clk) begin
    if (!rst_n) begin
        raw_mode          <= 1'b0;
        snapshot_bank     <= 1'b0;
        snapshot_sequence <= 16'd0;
        read_data         <= 32'd0;
    end else begin
        if (read_address == RAW_ENTER_ADDRESS) begin
            raw_mode          <= 1'b1;
            snapshot_bank     <= completed_bank_sync;
            snapshot_sequence <= completed_sequence_sync;
        end else if (read_address == RAW_EXIT_ADDRESS) begin
            raw_mode <= 1'b0;
        end

        if (!raw_mode) begin
            read_data <= logmel_read_data;
        end else if (read_address < 11'd512) begin
            if (snapshot_bank == 1'b0)
                read_data <= bank0_pair01[read_address[8:0]];
            else
                read_data <= bank1_pair01[read_address[8:0]];
        end else if (read_address < 11'd1024) begin
            if (snapshot_bank == 1'b0)
                read_data <= bank0_pair23[read_address[8:0]];
            else
                read_data <= bank1_pair23[read_address[8:0]];
        end else if (read_address == RAW_SIGNATURE_ADDRESS) begin
            read_data <= 32'h4d494334;
        end else if (read_address == RAW_METADATA_ADDRESS) begin
            read_data <= {snapshot_sequence, 15'd0, snapshot_bank};
        end else begin
            read_data <= 32'd0;
        end
    end
end

endmodule