`timescale 1ns / 1ps

// One-shot verification capture for a strictly matched PCM/feature pair.
//
// The first 49 feature frames after reset use PCM samples 0..15871:
//   frame f -> pcm[f*320 .. f*320+511], f=0..48.
// This module freezes exactly those 15872 ch0 samples together with the
// first replayed 49x40 Log-Mel matrix.  All four PCM memories and the feature
// memory therefore describe the same acoustic interval.
//
// Read protocol on the existing 11-bit AXI-GPIO address bus:
//   2031: enter paired-capture read mode
//   2030: leave paired-capture read mode
//   2029: signature, 0x50414952 ("PAIR")
//   2028: {matrix_sequence[15:0], 14'd0, error, ready}
//   2027: {pcm_sample_count[15:0], feature_value_count[15:0]}
//   2020..2023: select PCM page 0..3
//                addresses 0..1983 each return two signed PCM16 samples
//   2024: select feature page
//         addresses 0..1959 return the unsigned Log2 Q8.8 value in [15:0]
//   2026: arm a new capture and restart the audio frontend
//   1960..1975: select {channel[1:0], page[1:0]} for synchronized
//               four-channel PCM reads; addresses 0..1983 then return two
//               signed PCM16 samples.  2020..2023 remain legacy ch0 aliases.
module mic_frontend_pair_capture (
    input  wire               write_clk,
    input  wire               rst_n,
    input  wire               frontend_ready,
    input  wire               sample_valid,
    input  wire signed [23:0] pcm_sample_ch0,
    input  wire signed [23:0] pcm_sample_ch1,
    input  wire signed [23:0] pcm_sample_ch2,
    input  wire signed [23:0] pcm_sample_ch3,

    input  wire               feature_stream_valid,
    input  wire               feature_stream_last,
    input  wire [10:0]        feature_stream_address,
    input  wire [15:0]        feature_stream_value,
    input  wire [15:0]        feature_matrix_sequence,

    input  wire               read_clk,
    input  wire [10:0]        read_address,
    output reg  [31:0]        read_data,
    output reg                pair_mode,
    output reg                capture_restart_request,
    output wire               pair_ready_debug,
    output wire               pair_error_debug
);

localparam integer PCM_SAMPLE_COUNT    = 15872;
localparam integer PCM_PAIR_COUNT      = 7936;
localparam integer PCM_PAIRS_PER_PAGE  = 1984;
localparam integer FEATURE_VALUE_COUNT = 1960;

localparam [10:0] PAIR_PAGE0_ADDRESS    = 11'd2020;
localparam [10:0] PAIR_PAGE1_ADDRESS    = 11'd2021;
localparam [10:0] PAIR_PAGE2_ADDRESS    = 11'd2022;
localparam [10:0] PAIR_PAGE3_ADDRESS    = 11'd2023;
localparam [10:0] PAIR_FEATURE_ADDRESS  = 11'd2024;
localparam [10:0] PAIR_ARM_ADDRESS      = 11'd2026;
localparam [10:0] PAIR_COUNTS_ADDRESS   = 11'd2027;
localparam [10:0] PAIR_METADATA_ADDRESS = 11'd2028;
localparam [10:0] PAIR_SIGNATURE_ADDRESS = 11'd2029;
localparam [10:0] PAIR_EXIT_ADDRESS     = 11'd2030;
localparam [10:0] PAIR_ENTER_ADDRESS    = 11'd2031;
localparam [10:0] PAIR_CHANNEL_PAGE_BASE = 11'd1960;
localparam [10:0] PAIR_CHANNEL_PAGE_LAST = 11'd1975;

(* ram_style = "block" *)
reg [31:0] pcm_pair_memory_ch0 [0:PCM_PAIR_COUNT-1];
(* ram_style = "block" *)
reg [31:0] pcm_pair_memory_ch1 [0:PCM_PAIR_COUNT-1];
(* ram_style = "block" *)
reg [31:0] pcm_pair_memory_ch2 [0:PCM_PAIR_COUNT-1];
(* ram_style = "block" *)
reg [31:0] pcm_pair_memory_ch3 [0:PCM_PAIR_COUNT-1];

(* ram_style = "block" *)
reg [15:0] feature_memory [0:FEATURE_VALUE_COUNT-1];

reg [13:0] pcm_sample_index;
reg [15:0] pcm_even_sample_ch0;
reg [15:0] pcm_even_sample_ch1;
reg [15:0] pcm_even_sample_ch2;
reg [15:0] pcm_even_sample_ch3;
reg        pcm_capture_done;

reg        feature_capture_started;
reg        feature_capture_done;
reg [11:0] feature_value_count;
reg [15:0] captured_matrix_sequence;
reg        capture_error;
reg        capture_active;
reg        waiting_for_frontend_reset;
reg        frontend_reset_seen;

reg        arm_toggle_meta;
reg        arm_toggle_sync;
reg        arm_toggle_sync_d;
reg        arm_toggle_read;
reg        arm_select_d;

wire [15:0] pcm16_ch0 = pcm_sample_ch0[23:8];
wire [15:0] pcm16_ch1 = pcm_sample_ch1[23:8];
wire [15:0] pcm16_ch2 = pcm_sample_ch2[23:8];
wire [15:0] pcm16_ch3 = pcm_sample_ch3[23:8];
wire arm_event = arm_toggle_sync ^ arm_toggle_sync_d;

always @(posedge write_clk) begin
    if (!rst_n) begin
        pcm_sample_index         <= 14'd0;
        pcm_even_sample_ch0      <= 16'd0;
        pcm_even_sample_ch1      <= 16'd0;
        pcm_even_sample_ch2      <= 16'd0;
        pcm_even_sample_ch3      <= 16'd0;
        pcm_capture_done         <= 1'b0;
        feature_capture_started  <= 1'b0;
        feature_capture_done     <= 1'b0;
        feature_value_count      <= 12'd0;
        captured_matrix_sequence <= 16'd0;
        capture_error            <= 1'b0;
        capture_active           <= 1'b0;
        waiting_for_frontend_reset <= 1'b0;
        frontend_reset_seen      <= 1'b0;
        capture_restart_request  <= 1'b0;
        arm_toggle_meta          <= 1'b0;
        arm_toggle_sync          <= 1'b0;
        arm_toggle_sync_d        <= 1'b0;
    end else begin
        arm_toggle_meta   <= arm_toggle_read;
        arm_toggle_sync   <= arm_toggle_meta;
        arm_toggle_sync_d <= arm_toggle_sync;
        capture_restart_request <= 1'b0;

        if (arm_event) begin
            pcm_sample_index         <= 14'd0;
            pcm_even_sample_ch0      <= 16'd0;
            pcm_even_sample_ch1      <= 16'd0;
            pcm_even_sample_ch2      <= 16'd0;
            pcm_even_sample_ch3      <= 16'd0;
            pcm_capture_done         <= 1'b0;
            feature_capture_started  <= 1'b0;
            feature_capture_done     <= 1'b0;
            feature_value_count      <= 12'd0;
            captured_matrix_sequence <= 16'd0;
            capture_error            <= 1'b0;
            capture_active           <= 1'b0;
            waiting_for_frontend_reset <= 1'b1;
            frontend_reset_seen      <= 1'b0;
            capture_restart_request  <= 1'b1;
        end else if (waiting_for_frontend_reset) begin
            if (!frontend_ready) begin
                frontend_reset_seen <= 1'b1;
            end else if (frontend_reset_seen) begin
                waiting_for_frontend_reset <= 1'b0;
                capture_active <= 1'b1;
            end
        end

        if (
            sample_valid &&
            capture_active &&
            !arm_event &&
            !pcm_capture_done
        ) begin
            if (!pcm_sample_index[0]) begin
                pcm_even_sample_ch0 <= pcm16_ch0;
                pcm_even_sample_ch1 <= pcm16_ch1;
                pcm_even_sample_ch2 <= pcm16_ch2;
                pcm_even_sample_ch3 <= pcm16_ch3;
            end else begin
                pcm_pair_memory_ch0[pcm_sample_index[13:1]] <= {
                    pcm16_ch0, pcm_even_sample_ch0
                };
                pcm_pair_memory_ch1[pcm_sample_index[13:1]] <= {
                    pcm16_ch1, pcm_even_sample_ch1
                };
                pcm_pair_memory_ch2[pcm_sample_index[13:1]] <= {
                    pcm16_ch2, pcm_even_sample_ch2
                };
                pcm_pair_memory_ch3[pcm_sample_index[13:1]] <= {
                    pcm16_ch3, pcm_even_sample_ch3
                };
            end

            if (pcm_sample_index == 14'd15871) begin
                pcm_capture_done <= 1'b1;
            end else begin
                pcm_sample_index <= pcm_sample_index + 14'd1;
            end
        end

        if (
            feature_stream_valid &&
            capture_active &&
            !arm_event &&
            !feature_capture_done
        ) begin
            if (!feature_capture_started) begin
                feature_capture_started  <= 1'b1;

                if (feature_stream_address != 11'd0) begin
                    capture_error <= 1'b1;
                end
            end

            if (feature_stream_address < 11'd1960) begin
                feature_memory[feature_stream_address] <=
                    feature_stream_value;
            end else begin
                capture_error <= 1'b1;
            end

            if (feature_stream_address != feature_value_count[10:0]) begin
                capture_error <= 1'b1;
            end

            feature_value_count <= feature_value_count + 12'd1;

            if (feature_stream_last) begin
                feature_capture_done <= 1'b1;
                captured_matrix_sequence <=
                    feature_matrix_sequence + 16'd1;

                if (
                    (feature_stream_address != 11'd1959) ||
                    (feature_value_count != 12'd1959) ||
                    !pcm_capture_done
                ) begin
                    capture_error <= 1'b1;
                end
            end
        end
    end
end

assign pair_ready_debug = pcm_capture_done && feature_capture_done;
assign pair_error_debug = capture_error;

reg        ready_meta;
reg        ready_sync;
reg        error_meta;
reg        error_sync;
reg [15:0] sequence_meta;
reg [15:0] sequence_sync;
reg [2:0]  selected_page;
reg [1:0]  selected_channel;
reg [12:0] pcm_read_index;
reg [10:0] feature_read_index;
reg [31:0] pcm_memory_read_data_ch0;
reg [31:0] pcm_memory_read_data_ch1;
reg [31:0] pcm_memory_read_data_ch2;
reg [31:0] pcm_memory_read_data_ch3;
reg [31:0] pcm_memory_read_data;
reg [15:0] feature_memory_read_data;

always @(*) begin
    case (selected_page)
        3'd0: pcm_read_index = {2'd0, read_address};
        3'd1: pcm_read_index = 13'd1984 + read_address;
        3'd2: pcm_read_index = 13'd3968 + read_address;
        default: pcm_read_index = 13'd5952 + read_address;
    endcase

    feature_read_index =
        (read_address < 11'd1960)
        ? read_address
        : 11'd0;

    case (selected_channel)
        2'd0: pcm_memory_read_data = pcm_memory_read_data_ch0;
        2'd1: pcm_memory_read_data = pcm_memory_read_data_ch1;
        2'd2: pcm_memory_read_data = pcm_memory_read_data_ch2;
        default: pcm_memory_read_data = pcm_memory_read_data_ch3;
    endcase
end

// Keep the memory read ports in the canonical synchronous simple-dual-port
// form so Vivado infers BRAM instead of expanding these arrays into LUTRAM.
always @(posedge read_clk) begin
    pcm_memory_read_data_ch0 <= pcm_pair_memory_ch0[pcm_read_index];
    pcm_memory_read_data_ch1 <= pcm_pair_memory_ch1[pcm_read_index];
    pcm_memory_read_data_ch2 <= pcm_pair_memory_ch2[pcm_read_index];
    pcm_memory_read_data_ch3 <= pcm_pair_memory_ch3[pcm_read_index];
    feature_memory_read_data <= feature_memory[feature_read_index];
end

always @(posedge read_clk) begin
    if (!rst_n) begin
        pair_mode     <= 1'b0;
        selected_page <= 3'd0;
        selected_channel <= 2'd0;
        read_data     <= 32'd0;
        ready_meta    <= 1'b0;
        ready_sync    <= 1'b0;
        error_meta    <= 1'b0;
        error_sync    <= 1'b0;
        sequence_meta <= 16'd0;
        sequence_sync <= 16'd0;
        arm_toggle_read <= 1'b0;
        arm_select_d    <= 1'b0;
    end else begin
        ready_meta    <= pair_ready_debug;
        ready_sync    <= ready_meta;
        error_meta    <= pair_error_debug;
        error_sync    <= error_meta;
        sequence_meta <= captured_matrix_sequence;
        sequence_sync <= sequence_meta;
        arm_select_d <= (read_address == PAIR_ARM_ADDRESS);

        if (
            (read_address == PAIR_ARM_ADDRESS) &&
            !arm_select_d
        ) begin
            arm_toggle_read <= ~arm_toggle_read;
        end

        if (read_address == PAIR_ENTER_ADDRESS) begin
            pair_mode <= 1'b1;
        end else if (read_address == PAIR_EXIT_ADDRESS) begin
            pair_mode <= 1'b0;
        end

        if ((read_address >= PAIR_CHANNEL_PAGE_BASE) &&
            (read_address <= PAIR_CHANNEL_PAGE_LAST)) begin
            selected_channel <=
                (read_address - PAIR_CHANNEL_PAGE_BASE) >> 2;
            selected_page <=
                (read_address - PAIR_CHANNEL_PAGE_BASE) & 2'b11;
        end else begin
            case (read_address)
                PAIR_PAGE0_ADDRESS: begin
                    selected_channel <= 2'd0;
                    selected_page <= 3'd0;
                end
                PAIR_PAGE1_ADDRESS: begin
                    selected_channel <= 2'd0;
                    selected_page <= 3'd1;
                end
                PAIR_PAGE2_ADDRESS: begin
                    selected_channel <= 2'd0;
                    selected_page <= 3'd2;
                end
                PAIR_PAGE3_ADDRESS: begin
                    selected_channel <= 2'd0;
                    selected_page <= 3'd3;
                end
                PAIR_FEATURE_ADDRESS: selected_page <= 3'd4;
                default: selected_page <= selected_page;
            endcase
        end

        if (!pair_mode) begin
            read_data <= 32'd0;
        end else if (read_address == PAIR_SIGNATURE_ADDRESS) begin
            read_data <= 32'h50414952;
        end else if (read_address == PAIR_METADATA_ADDRESS) begin
            read_data <= {
                sequence_sync,
                14'd0,
                error_sync,
                ready_sync
            };
        end else if (read_address == PAIR_COUNTS_ADDRESS) begin
            read_data <= {16'd15872, 16'd1960};
        end else if (
            (selected_page <= 3'd3) &&
            (read_address < 11'd1984)
        ) begin
            read_data <= pcm_memory_read_data;
        end else if (
            (selected_page == 3'd4) &&
            (read_address < 11'd1960)
        ) begin
            read_data <= {16'd0, feature_memory_read_data};
        end else begin
            read_data <= 32'd0;
        end
    end
end

endmodule
