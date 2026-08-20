// kv_v03_typed_decode_lane_bank_4x1.v
//
// Four independent whole-page decode lanes behind one AXI-free, synchronous
// scratch-copy port.  A page is first copied into lane-local payload/scale
// RAM, allowing the upstream ping-pong owner to be released before prefix
// decode completes.  Completed pages are published strictly in issue order.
//
// task_tag is the existing v0.3 typed layout:
//   {layer[15:0], kv_head[15:0], profile_id[15:0],
//    codebook_id[7:0], request_id[7:0]}.
// page_index, stream_is_v, and epoch are carried beside that tag.
//
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_typed_decode_lane_bank_4x1 #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_SYMBOLS = 16384,
    parameter integer MAX_PAYLOAD_BYTES = 10240,
    parameter integer MAX_SCALE_BYTES = 256,
    parameter integer COMPILED_PROFILE_ID = 0,
    parameter integer COMPILED_K_CODEBOOK_ID = 1,
    parameter integer COMPILED_V_CODEBOOK_ID = 2
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // One CRC-approved page descriptor.  The expected-stream bit comes from
    // the scheduler and is compared with the page/header stream bit.
    input  wire                    page_valid,
    output wire                    page_ready,
    input  wire [63:0]             page_task_tag,
    input  wire [15:0]             page_epoch,
    input  wire [4:0]              page_index,
    input  wire                    page_stream_is_v,
    input  wire                    page_expected_stream_is_v,
    input  wire                    page_raw_mode,
    input  wire [15:0]             page_payload_bytes,
    input  wire [14:0]             page_expected_symbols,
    input  wire [7:0]              page_token_count,
    input  wire [8:0]              page_scale_slice_bytes,

    // Pulse after the accepted upstream page is no longer referenced.  On an
    // abort/fault it is delayed until every accepted scratch read is drained.
    output reg                     source_release,

    // Synchronous upstream scratch ports.  Data word zero is the page header;
    // payload copying therefore begins at logical word address three.
    output wire                    data_rd_en,
    output wire [11:0]             data_rd_word_addr,
    input  wire                    data_rd_valid,
    input  wire [31:0]             data_rd_data,
    input  wire [3:0]              data_rd_byte_valid,
    input  wire                    data_rd_last,
    input  wire [13:0]             data_rd_byte_offset,
    output wire                    scale_rd_en,
    output wire [6:0]              scale_rd_word_addr,
    input  wire                    scale_rd_valid,
    input  wire [31:0]             scale_rd_data,
    input  wire [3:0]              scale_rd_byte_valid,
    input  wire                    scale_rd_last,
    input  wire [8:0]              scale_rd_byte_offset,

    // Fail-closed row cancellation.  It flushes the complete four-lane bank;
    // the supplied identity is retained as the typed abort cause.
    input  wire                    abort_valid,
    input  wire [63:0]             abort_task_tag,
    input  wire [15:0]             abort_epoch,
    input  wire [4:0]              abort_page_index,
    input  wire                    abort_stream_is_v,
    input  wire                    clear_fault,
    output wire                    clear_ready,

    // The head descriptor is held until accepted, then owns the common read
    // ports until page_release.  Later lanes may finish first but cannot pass
    // this issue-order boundary.
    output wire                    publish_valid,
    input  wire                    publish_ready,
    output wire                    page_active,
    input  wire                    page_release,
    output wire [63:0]             published_task_tag,
    output wire [15:0]             published_epoch,
    output wire [4:0]              published_page_index,
    output wire                    published_stream_is_v,
    output wire                    published_raw_mode,
    output wire [15:0]             published_payload_bytes,
    output wire [14:0]             published_expected_symbols,
    output wire [7:0]              published_token_count,
    output wire [8:0]              published_scale_slice_bytes,

    // P16 arithmetic-facing synchronous reads.  Code i occupies
    // p16_rd_codes[(i*5)+:5].  All K4 values are sign-extended to five bits.
    input  wire                    p16_rd_en,
    input  wire [9:0]              p16_rd_addr,
    output wire                    p16_rd_valid,
    output wire [79:0]             p16_rd_codes,
    input  wire                    token_scale_rd_en,
    input  wire [6:0]              token_scale_rd_addr,
    output wire                    token_scale_rd_valid,
    output wire [SCALE_BITS-1:0]   token_scale_rd_data,

    output wire                    busy,
    output wire                    draining,
    output wire [3:0]              lane_occupied,
    output wire [3:0]              lane_decode_busy,
    output wire [3:0]              lane_complete,

    // Sticky, fully typed fault plus a one-cycle row_abort notification.
    output reg                     sticky_error,
    output reg  [7:0]              sticky_error_code,
    output reg  [7:0]              sticky_error_subcode,
    output reg  [63:0]             sticky_task_tag,
    output reg  [15:0]             sticky_epoch,
    output reg  [4:0]              sticky_page_index,
    output reg                     sticky_stream_is_v,
    output reg                     row_abort
);
    localparam [7:0] ERR_DESCRIPTOR = 8'h01;
    localparam [7:0] ERR_PROFILE    = 8'h02;
    localparam [7:0] ERR_CODEBOOK   = 8'h03;
    localparam [7:0] ERR_STREAM     = 8'h04;
    localparam [7:0] ERR_DATA_PORT  = 8'h05;
    localparam [7:0] ERR_SCALE_PORT = 8'h06;
    localparam [7:0] ERR_DECODER    = 8'h07;
    localparam [7:0] ERR_SCALE      = 8'h08;
    localparam [7:0] ERR_ABORT      = 8'h09;
    localparam [7:0] ERR_INTERNAL   = 8'h0a;

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    function [3:0] final_keep;
        input [1:0] remainder;
        begin
            case (remainder)
                2'd1: final_keep = 4'b0001;
                2'd2: final_keep = 4'b0011;
                2'd3: final_keep = 4'b0111;
                default: final_keep = 4'b1111;
            endcase
        end
    endfunction

    reg [3:0] occupied_reg;
    reg [2:0] queue_count;
    reg [1:0] queue_lane0, queue_lane1, queue_lane2, queue_lane3;
    reg head_presented;

    reg capture_active;
    reg [1:0] capture_lane;
    reg [11:0] data_word_count;
    reg [7:0] scale_word_count;
    reg [11:0] data_request_count;
    reg [7:0] scale_request_count;
    reg data_outstanding;
    reg scale_outstanding;
    reg [11:0] data_outstanding_index;
    reg [7:0] scale_outstanding_index;
    reg [3:0] data_outstanding_keep;
    reg [3:0] scale_outstanding_keep;
    reg data_outstanding_last;
    reg scale_outstanding_last;
    reg [13:0] data_outstanding_offset;
    reg [8:0] scale_outstanding_offset;
    reg data_copy_done;
    reg scale_copy_done;
    reg draining_reg;
    reg release_pending;

    reg [63:0] lane_task_tag [0:3];
    reg [15:0] lane_epoch [0:3];
    reg [4:0] lane_page_index [0:3];
    reg lane_stream_is_v [0:3];
    reg lane_raw_mode [0:3];
    reg [15:0] lane_payload_bytes [0:3];
    reg [14:0] lane_expected_symbols [0:3];
    reg [7:0] lane_token_count [0:3];
    reg [8:0] lane_scale_slice_bytes [0:3];

    wire [3:0] free_mask = ~occupied_reg;
    reg [1:0] allocation_lane;
    always @* begin
        casex (free_mask)
            4'bxxx1: allocation_lane = 2'd0;
            4'bxx10: allocation_lane = 2'd1;
            4'bx100: allocation_lane = 2'd2;
            default: allocation_lane = 2'd3;
        endcase
    end

    wire [15:0] descriptor_profile = page_task_tag[31:16];
    wire [7:0] descriptor_codebook = page_task_tag[15:8];
    wire [7:0] expected_codebook = page_expected_stream_is_v ?
        COMPILED_V_CODEBOOK_ID[7:0] : COMPILED_K_CODEBOOK_ID[7:0];
    wire [7:0] opposite_codebook = page_expected_stream_is_v ?
        COMPILED_K_CODEBOOK_ID[7:0] : COMPILED_V_CODEBOOK_ID[7:0];
    wire [14:0] descriptor_symbol_count = {page_token_count, 7'b0};
    wire [19:0] descriptor_raw_bits = page_expected_symbols *
        (page_stream_is_v ? 20'd5 : 20'd4);
    wire [15:0] descriptor_raw_bytes =
        (descriptor_raw_bits + 20'd7) >> 3;
    wire [16:0] descriptor_scale_bits = page_token_count * SCALE_BITS;
    wire [8:0] descriptor_scale_bytes =
        (descriptor_scale_bits + 17'd7) >> 3;

    wire descriptor_stream_bad =
        page_stream_is_v != page_expected_stream_is_v;
    wire descriptor_profile_bad =
        descriptor_profile != COMPILED_PROFILE_ID[15:0];
    wire descriptor_codebook_bad = descriptor_codebook != expected_codebook;
    wire descriptor_geometry_bad =
        (page_token_count == 0) || (page_token_count > 128) ||
        (page_expected_symbols == 0) ||
        (page_expected_symbols > MAX_SYMBOLS) ||
        (page_expected_symbols != descriptor_symbol_count) ||
        (page_payload_bytes == 0) ||
        (page_payload_bytes > MAX_PAYLOAD_BYTES) ||
        (page_scale_slice_bytes == 0) ||
        (page_scale_slice_bytes > MAX_SCALE_BYTES) ||
        (page_scale_slice_bytes != descriptor_scale_bytes) ||
        (page_raw_mode && (page_payload_bytes != descriptor_raw_bytes)) ||
        (!page_raw_mode && (page_payload_bytes >= descriptor_raw_bytes));
    wire descriptor_bad = descriptor_stream_bad ||
                          descriptor_profile_bad ||
                          descriptor_codebook_bad ||
                          descriptor_geometry_bad;
    wire [7:0] descriptor_error_code =
        descriptor_profile_bad ? ERR_PROFILE :
        descriptor_stream_bad ? ERR_STREAM :
        descriptor_codebook_bad ? ERR_CODEBOOK : ERR_DESCRIPTOR;

    wire [3:0] lane_busy_i;
    wire [3:0] lane_committed_i;
    wire [3:0] lane_error_i;
    wire [7:0] lane_error_source_i;
    wire [31:0] lane_error_code_i;
    wire [3:0] lane_complete_pulse_i;
    wire [319:0] lane_p16_data_i;
    wire [3:0] lane_p16_valid_i;
    wire [(4*SCALE_BITS)-1:0] lane_scale_data_i;
    wire [3:0] lane_scale_valid_i;

    reg [1:0] fault_lane;
    always @* begin
        casex (lane_error_i)
            4'bxxx1: fault_lane = 2'd0;
            4'bxx10: fault_lane = 2'd1;
            4'bx100: fault_lane = 2'd2;
            default: fault_lane = 2'd3;
        endcase
    end

    wire lane_error_any = |lane_error_i;
    wire unexpected_response = !capture_active && !draining_reg &&
                               (data_rd_valid || scale_rd_valid);
    wire healthy = !sticky_error && !draining_reg && !abort_valid &&
                   !lane_error_any && !unexpected_response;
    assign page_ready = healthy && !capture_active && (|free_mask) &&
                        !source_release && !data_rd_valid && !scale_rd_valid;
    wire page_fire = page_valid && page_ready;
    wire good_page_fire = page_fire && !descriptor_bad;
    wire bad_page_fire = page_fire && descriptor_bad;

    assign data_rd_en = healthy && capture_active &&
                        !data_outstanding && !data_rd_valid &&
                        (data_request_count < data_word_count) &&
                        !data_copy_done;
    assign data_rd_word_addr = 12'd3 + data_request_count;
    assign scale_rd_en = healthy && capture_active &&
                         !scale_outstanding && !scale_rd_valid &&
                         (scale_request_count < scale_word_count) &&
                         !scale_copy_done;
    assign scale_rd_word_addr = scale_request_count[6:0];

    wire data_response_bad = capture_active && data_rd_valid &&
        (!data_outstanding || !valid_mask(data_rd_byte_valid) ||
         ((data_rd_byte_valid & data_outstanding_keep) !=
          data_outstanding_keep) ||
         (data_rd_byte_offset != data_outstanding_offset) ||
         (data_rd_last && !data_outstanding_last));
    wire scale_response_bad = capture_active && scale_rd_valid &&
        (!scale_outstanding || !valid_mask(scale_rd_byte_valid) ||
         ((scale_rd_byte_valid & scale_outstanding_keep) !=
          scale_outstanding_keep) ||
         (scale_rd_byte_offset != scale_outstanding_offset) ||
         (scale_rd_last != scale_outstanding_last));
    wire data_response_accept = capture_active && data_rd_valid &&
                                data_outstanding && !data_response_bad;
    wire scale_response_accept = capture_active && scale_rd_valid &&
                                 scale_outstanding && !scale_response_bad;
    wire data_final_accept = data_response_accept && data_outstanding_last;
    wire scale_final_accept = scale_response_accept && scale_outstanding_last;
    wire capture_complete_now = capture_active &&
        (data_copy_done || data_final_accept) &&
        (scale_copy_done || scale_final_accept);

    wire fault_event = !sticky_error &&
        (abort_valid || bad_page_fire || data_response_bad ||
         scale_response_bad || unexpected_response || lane_error_any);
    wire [3:0] lane_flush = {4{fault_event}};
    wire [3:0] lane_allocate =
        good_page_fire ? (4'b0001 << allocation_lane) : 4'b0000;
    wire [3:0] lane_decode_start =
        capture_complete_now ? (4'b0001 << capture_lane) : 4'b0000;

    wire [1:0] head_lane = queue_lane0;
    assign publish_valid = healthy && (queue_count != 0) &&
                           !head_presented && lane_committed_i[head_lane];
    wire publish_fire = publish_valid && publish_ready;
    assign page_active = healthy && (queue_count != 0) && head_presented &&
                         lane_committed_i[head_lane];
    wire release_fire = page_active && page_release;
    wire [3:0] lane_release =
        release_fire ? (4'b0001 << head_lane) : 4'b0000;

    assign published_task_tag = lane_task_tag[head_lane];
    assign published_epoch = lane_epoch[head_lane];
    assign published_page_index = lane_page_index[head_lane];
    assign published_stream_is_v = lane_stream_is_v[head_lane];
    assign published_raw_mode = lane_raw_mode[head_lane];
    assign published_payload_bytes = lane_payload_bytes[head_lane];
    assign published_expected_symbols = lane_expected_symbols[head_lane];
    assign published_token_count = lane_token_count[head_lane];
    assign published_scale_slice_bytes =
        lane_scale_slice_bytes[head_lane];

    wire [3:0] lane_p16_rd_en =
        (p16_rd_en && page_active && !page_release) ?
        (4'b0001 << head_lane) : 4'b0000;
    wire [3:0] lane_token_scale_rd_en =
        (token_scale_rd_en && page_active && !page_release) ?
        (4'b0001 << head_lane) : 4'b0000;
    assign p16_rd_valid = page_active && !page_release &&
                          lane_p16_valid_i[head_lane];
    assign p16_rd_codes =
        lane_p16_data_i[(head_lane*80) +: 80];
    assign token_scale_rd_valid = page_active && !page_release &&
                                  lane_scale_valid_i[head_lane];
    assign token_scale_rd_data =
        lane_scale_data_i[(head_lane*SCALE_BITS) +: SCALE_BITS];

    wire [3:0] lane_payload_wr_en =
        data_response_accept ? (4'b0001 << capture_lane) : 4'b0000;
    wire [3:0] lane_scale_wr_en =
        scale_response_accept ? (4'b0001 << capture_lane) : 4'b0000;

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_lane
            kv_v03_typed_decode_lane #(
                .SCALE_BITS(SCALE_BITS),
                .MAX_SYMBOLS(MAX_SYMBOLS),
                .MAX_PAYLOAD_BYTES(MAX_PAYLOAD_BYTES),
                .MAX_SCALE_BYTES(MAX_SCALE_BYTES)
            ) u_lane (
                .clk(clk), .rst_n(rst_n),
                .allocate(lane_allocate[lane]),
                .alloc_stream_is_v(page_stream_is_v),
                .alloc_raw_mode(page_raw_mode),
                .alloc_payload_bytes(page_payload_bytes),
                .alloc_expected_symbols(page_expected_symbols),
                .alloc_token_count(page_token_count),
                .alloc_scale_slice_bytes(page_scale_slice_bytes),
                .payload_wr_en(lane_payload_wr_en[lane]),
                .payload_wr_addr(data_outstanding_index),
                .payload_wr_data(data_rd_data),
                .scale_wr_en(lane_scale_wr_en[lane]),
                .scale_wr_addr(scale_outstanding_index[6:0]),
                .scale_wr_data(scale_rd_data),
                .decode_start(lane_decode_start[lane]),
                .flush(lane_flush[lane]),
                .release_lane(lane_release[lane]),
                .p16_rd_en(lane_p16_rd_en[lane]),
                .p16_rd_addr(p16_rd_addr),
                .p16_rd_valid(lane_p16_valid_i[lane]),
                .p16_rd_data(lane_p16_data_i[(lane*80) +: 80]),
                .scale_rd_en(lane_token_scale_rd_en[lane]),
                .scale_rd_addr(token_scale_rd_addr),
                .scale_rd_valid(lane_scale_valid_i[lane]),
                .scale_rd_data(
                    lane_scale_data_i[(lane*SCALE_BITS) +: SCALE_BITS]),
                .busy(lane_busy_i[lane]),
                .committed(lane_committed_i[lane]),
                .complete_pulse(lane_complete_pulse_i[lane]),
                .error_valid(lane_error_i[lane]),
                .error_source(lane_error_source_i[(lane*2) +: 2]),
                .error_code(lane_error_code_i[(lane*8) +: 8])
            );
        end
    endgenerate

    assign lane_occupied = occupied_reg;
    assign lane_decode_busy = lane_busy_i;
    assign lane_complete = lane_complete_pulse_i;
    assign draining = draining_reg;
    assign busy = capture_active || draining_reg || (occupied_reg != 0) ||
                  sticky_error;
    assign clear_ready = sticky_error && !abort_valid && !draining_reg &&
                         !capture_active && (occupied_reg == 0) &&
                         !(|lane_busy_i) && !source_release;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            occupied_reg <= 4'b0;
            queue_count <= 3'd0;
            queue_lane0 <= 2'd0;
            queue_lane1 <= 2'd0;
            queue_lane2 <= 2'd0;
            queue_lane3 <= 2'd0;
            head_presented <= 1'b0;
            capture_active <= 1'b0;
            capture_lane <= 2'd0;
            data_word_count <= 12'd0;
            scale_word_count <= 8'd0;
            data_request_count <= 12'd0;
            scale_request_count <= 8'd0;
            data_outstanding <= 1'b0;
            scale_outstanding <= 1'b0;
            data_outstanding_index <= 12'd0;
            scale_outstanding_index <= 8'd0;
            data_outstanding_keep <= 4'b0;
            scale_outstanding_keep <= 4'b0;
            data_outstanding_last <= 1'b0;
            scale_outstanding_last <= 1'b0;
            data_outstanding_offset <= 14'd0;
            scale_outstanding_offset <= 9'd0;
            data_copy_done <= 1'b0;
            scale_copy_done <= 1'b0;
            draining_reg <= 1'b0;
            release_pending <= 1'b0;
            source_release <= 1'b0;
            sticky_error <= 1'b0;
            sticky_error_code <= 8'd0;
            sticky_error_subcode <= 8'd0;
            sticky_task_tag <= 64'd0;
            sticky_epoch <= 16'd0;
            sticky_page_index <= 5'd0;
            sticky_stream_is_v <= 1'b0;
            row_abort <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                lane_task_tag[i] <= 64'd0;
                lane_epoch[i] <= 16'd0;
                lane_page_index[i] <= 5'd0;
                lane_stream_is_v[i] <= 1'b0;
                lane_raw_mode[i] <= 1'b0;
                lane_payload_bytes[i] <= 16'd0;
                lane_expected_symbols[i] <= 15'd0;
                lane_token_count[i] <= 8'd0;
                lane_scale_slice_bytes[i] <= 9'd0;
            end
        end else begin
            source_release <= 1'b0;
            row_abort <= 1'b0;

            if (fault_event) begin
                sticky_error <= 1'b1;
                sticky_error_subcode <= 8'd0;
                row_abort <= 1'b1;
                occupied_reg <= 4'b0;
                queue_count <= 3'd0;
                queue_lane0 <= 2'd0;
                queue_lane1 <= 2'd0;
                queue_lane2 <= 2'd0;
                queue_lane3 <= 2'd0;
                head_presented <= 1'b0;
                capture_active <= 1'b0;
                data_copy_done <= 1'b0;
                scale_copy_done <= 1'b0;

                if (abort_valid) begin
                    sticky_error_code <= ERR_ABORT;
                    sticky_task_tag <= abort_task_tag;
                    sticky_epoch <= abort_epoch;
                    sticky_page_index <= abort_page_index;
                    sticky_stream_is_v <= abort_stream_is_v;
                end else if (bad_page_fire) begin
                    sticky_error_code <= descriptor_error_code;
                    sticky_task_tag <= page_task_tag;
                    sticky_epoch <= page_epoch;
                    sticky_page_index <= page_index;
                    sticky_stream_is_v <= page_stream_is_v;
                end else if (data_response_bad ||
                             scale_response_bad) begin
                    sticky_error_code <= data_response_bad ?
                                         ERR_DATA_PORT : ERR_SCALE_PORT;
                    sticky_task_tag <= lane_task_tag[capture_lane];
                    sticky_epoch <= lane_epoch[capture_lane];
                    sticky_page_index <= lane_page_index[capture_lane];
                    sticky_stream_is_v <=
                        lane_stream_is_v[capture_lane];
                end else if (unexpected_response) begin
                    sticky_error_code <= data_rd_valid ?
                                         ERR_DATA_PORT : ERR_SCALE_PORT;
                    sticky_task_tag <= 64'd0;
                    sticky_epoch <= 16'd0;
                    sticky_page_index <= 5'd0;
                    sticky_stream_is_v <= 1'b0;
                end else begin
                    sticky_error_code <=
                        (lane_error_source_i[(fault_lane*2) +: 2] == 2'd1) ?
                        ERR_DECODER :
                        (lane_error_source_i[(fault_lane*2) +: 2] == 2'd2) ?
                        ERR_SCALE : ERR_INTERNAL;
                    sticky_error_subcode <=
                        lane_error_code_i[(fault_lane*8) +: 8];
                    sticky_task_tag <= lane_task_tag[fault_lane];
                    sticky_epoch <= lane_epoch[fault_lane];
                    sticky_page_index <= lane_page_index[fault_lane];
                    sticky_stream_is_v <= lane_stream_is_v[fault_lane];
                end

                data_outstanding <= data_outstanding && !data_rd_valid;
                scale_outstanding <= scale_outstanding && !scale_rd_valid;
                if (capture_active || bad_page_fire) begin
                    release_pending <= 1'b1;
                    if ((data_outstanding && !data_rd_valid) ||
                        (scale_outstanding && !scale_rd_valid)) begin
                        draining_reg <= 1'b1;
                    end else begin
                        draining_reg <= 1'b0;
                        release_pending <= 1'b0;
                        source_release <= 1'b1;
                    end
                end else begin
                    draining_reg <= 1'b0;
                    release_pending <= 1'b0;
                end
            end else if (draining_reg) begin
                if (data_rd_valid)
                    data_outstanding <= 1'b0;
                if (scale_rd_valid)
                    scale_outstanding <= 1'b0;
                if ((!data_outstanding || data_rd_valid) &&
                    (!scale_outstanding || scale_rd_valid)) begin
                    draining_reg <= 1'b0;
                    if (release_pending)
                        source_release <= 1'b1;
                    release_pending <= 1'b0;
                end
            end else begin
                if (clear_fault && clear_ready) begin
                    sticky_error <= 1'b0;
                    sticky_error_code <= 8'd0;
                    sticky_error_subcode <= 8'd0;
                end

                if (publish_fire)
                    head_presented <= 1'b1;
                if (release_fire)
                    head_presented <= 1'b0;

                case ({good_page_fire, release_fire})
                    2'b10: begin
                        case (queue_count)
                            3'd0: queue_lane0 <= allocation_lane;
                            3'd1: queue_lane1 <= allocation_lane;
                            3'd2: queue_lane2 <= allocation_lane;
                            default: queue_lane3 <= allocation_lane;
                        endcase
                        queue_count <= queue_count + 1'b1;
                    end
                    2'b01: begin
                        queue_lane0 <= queue_lane1;
                        queue_lane1 <= queue_lane2;
                        queue_lane2 <= queue_lane3;
                        queue_count <= queue_count - 1'b1;
                    end
                    2'b11: begin
                        queue_lane0 <= queue_lane1;
                        queue_lane1 <= queue_lane2;
                        queue_lane2 <= queue_lane3;
                        case (queue_count)
                            3'd1: queue_lane0 <= allocation_lane;
                            3'd2: queue_lane1 <= allocation_lane;
                            3'd3: queue_lane2 <= allocation_lane;
                            default: queue_lane3 <= allocation_lane;
                        endcase
                    end
                    default: begin end
                endcase

                if (release_fire)
                    occupied_reg[head_lane] <= 1'b0;

                if (good_page_fire) begin
                    occupied_reg[allocation_lane] <= 1'b1;
                    lane_task_tag[allocation_lane] <= page_task_tag;
                    lane_epoch[allocation_lane] <= page_epoch;
                    lane_page_index[allocation_lane] <= page_index;
                    lane_stream_is_v[allocation_lane] <=
                        page_stream_is_v;
                    lane_raw_mode[allocation_lane] <= page_raw_mode;
                    lane_payload_bytes[allocation_lane] <=
                        page_payload_bytes;
                    lane_expected_symbols[allocation_lane] <=
                        page_expected_symbols;
                    lane_token_count[allocation_lane] <= page_token_count;
                    lane_scale_slice_bytes[allocation_lane] <=
                        page_scale_slice_bytes;

                    capture_active <= 1'b1;
                    capture_lane <= allocation_lane;
                    data_word_count <=
                        (page_payload_bytes + 16'd3) >> 2;
                    scale_word_count <=
                        (page_scale_slice_bytes + 9'd3) >> 2;
                    data_request_count <= 12'd0;
                    scale_request_count <= 8'd0;
                    data_outstanding <= 1'b0;
                    scale_outstanding <= 1'b0;
                    data_copy_done <= 1'b0;
                    scale_copy_done <= 1'b0;
                end else if (capture_active) begin
                    if (data_rd_en) begin
                        data_outstanding <= 1'b1;
                        data_outstanding_index <= data_request_count;
                        data_outstanding_keep <=
                            ((data_request_count + 1'b1) ==
                             data_word_count) ?
                            final_keep(
                                lane_payload_bytes[capture_lane][1:0]) :
                            4'b1111;
                        data_outstanding_last <=
                            ((data_request_count + 1'b1) ==
                             data_word_count);
                        data_outstanding_offset <=
                            14'd12 + {data_request_count, 2'b00};
                        data_request_count <= data_request_count + 1'b1;
                    end
                    if (scale_rd_en) begin
                        scale_outstanding <= 1'b1;
                        scale_outstanding_index <= scale_request_count;
                        scale_outstanding_keep <=
                            ((scale_request_count + 1'b1) ==
                             scale_word_count) ?
                            final_keep(
                                lane_scale_slice_bytes[capture_lane][1:0]) :
                            4'b1111;
                        scale_outstanding_last <=
                            ((scale_request_count + 1'b1) ==
                             scale_word_count);
                        scale_outstanding_offset <=
                            {scale_request_count[6:0], 2'b00};
                        scale_request_count <= scale_request_count + 1'b1;
                    end
                    if (data_response_accept) begin
                        data_outstanding <= 1'b0;
                        if (data_outstanding_last)
                            data_copy_done <= 1'b1;
                    end
                    if (scale_response_accept) begin
                        scale_outstanding <= 1'b0;
                        if (scale_outstanding_last)
                            scale_copy_done <= 1'b1;
                    end
                    if (capture_complete_now) begin
                        capture_active <= 1'b0;
                        data_copy_done <= 1'b0;
                        scale_copy_done <= 1'b0;
                        source_release <= 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("typed decode lane bank SCALE_BITS must be 12 or 16");
        if (MAX_SYMBOLS < 16384)
            $error("typed decode lane bank must cover page128 symbols");
        if (MAX_PAYLOAD_BYTES < 10240)
            $error("typed decode lane bank must cover raw V5 page128");
        if (MAX_SCALE_BYTES < ((128*SCALE_BITS + 7)/8))
            $error("typed decode lane bank scale RAM is too small");
    end
`endif
endmodule


module kv_v03_typed_decode_lane #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_SYMBOLS = 16384,
    parameter integer MAX_PAYLOAD_BYTES = 10240,
    parameter integer MAX_SCALE_BYTES = 256
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    allocate,
    input  wire                    alloc_stream_is_v,
    input  wire                    alloc_raw_mode,
    input  wire [15:0]             alloc_payload_bytes,
    input  wire [14:0]             alloc_expected_symbols,
    input  wire [7:0]              alloc_token_count,
    input  wire [8:0]              alloc_scale_slice_bytes,
    input  wire                    payload_wr_en,
    input  wire [11:0]             payload_wr_addr,
    input  wire [31:0]             payload_wr_data,
    input  wire                    scale_wr_en,
    input  wire [6:0]              scale_wr_addr,
    input  wire [31:0]             scale_wr_data,
    input  wire                    decode_start,
    input  wire                    flush,
    input  wire                    release_lane,
    input  wire                    p16_rd_en,
    input  wire [9:0]              p16_rd_addr,
    output reg                     p16_rd_valid,
    output reg  [79:0]             p16_rd_data,
    input  wire                    scale_rd_en,
    input  wire [6:0]              scale_rd_addr,
    output reg                     scale_rd_valid,
    output reg  [SCALE_BITS-1:0]   scale_rd_data,
    output wire                    busy,
    output reg                     committed,
    output reg                     complete_pulse,
    output reg                     error_valid,
    output reg  [1:0]              error_source,
    output reg  [7:0]              error_code
);
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_CAPTURE = 3'd1;
    localparam [2:0] ST_LAUNCH  = 3'd2;
    localparam [2:0] ST_RUN     = 3'd3;
    localparam [2:0] ST_DONE    = 3'd4;

    localparam [1:0] SOURCE_INTERNAL = 2'd0;
    localparam [1:0] SOURCE_DECODER  = 2'd1;
    localparam [1:0] SOURCE_SCALE    = 2'd2;
    localparam [7:0] ERR_PROTOCOL = 8'h05;
    localparam integer PAYLOAD_WORDS = (MAX_PAYLOAD_BYTES + 3) / 4;
    localparam integer SCALE_WORDS = (MAX_SCALE_BYTES + 3) / 4;
    localparam integer P16_WORDS = (MAX_SYMBOLS + 15) / 16;

    reg [2:0] state;
    reg stream_is_v_reg;
    reg raw_mode_reg;
    reg [15:0] payload_bytes_reg;
    reg [14:0] expected_symbols_reg;
    reg [7:0] token_count_reg;
    reg [8:0] scale_slice_bytes_reg;
    reg [11:0] payload_word_count_reg;
    reg [7:0] scale_word_count_reg;

    (* ram_style = "block" *) reg [31:0] payload_mem [0:PAYLOAD_WORDS-1];
    (* ram_style = "block" *) reg [31:0] scale_capture_mem [0:SCALE_WORDS-1];
    (* ram_style = "block" *) reg [79:0] p16_mem [0:P16_WORDS-1];
    (* ram_style = "block" *) reg [SCALE_BITS-1:0]
        decoded_scale_mem [0:127];

    function [3:0] final_keep;
        input [1:0] remainder;
        begin
            case (remainder)
                2'd1: final_keep = 4'b0001;
                2'd2: final_keep = 4'b0011;
                2'd3: final_keep = 4'b0111;
                default: final_keep = 4'b1111;
            endcase
        end
    endfunction

    wire engine_rst_n = rst_n && !flush;
    wire decoder_start = state == ST_LAUNCH;
    wire scale_start = state == ST_LAUNCH;

    reg [11:0] payload_feed_index;
    reg payload_pending_valid;
    reg [31:0] payload_pending_data;
    reg [3:0] payload_pending_keep;
    reg payload_pending_last;

    wire decoder_in_ready;
    wire decoder_out_valid;
    wire [1:0] decoder_out_count;
    wire signed [4:0] decoder_out_symbol0;
    wire signed [4:0] decoder_out_symbol1;
    wire decoder_out_last;
    wire decoder_busy;
    wire decoder_done;
    wire decoder_error_valid;
    wire [7:0] decoder_error_code;
    wire decoder_in_valid = (state == ST_RUN) && payload_pending_valid;
    wire payload_pending_fire = decoder_in_valid && decoder_in_ready;

    kv_v03_symbol_decoder #(
        .SYMBOL_WIDTH(5),
        .STREAM_IS_V(1),
        .RUNTIME_STREAM_SELECT(1),
        .SYMBOLS_PER_CYCLE(1),
        .MAX_SYMBOLS(MAX_SYMBOLS)
    ) u_decoder (
        .clk(clk), .rst_n(engine_rst_n), .start(decoder_start),
        .integrity_passed(1'b1), .stream_is_v(stream_is_v_reg),
        .raw_mode(raw_mode_reg), .expected_symbols(expected_symbols_reg),
        .in_valid(decoder_in_valid), .in_ready(decoder_in_ready),
        .in_data(payload_pending_data),
        .in_byte_valid(payload_pending_keep),
        .in_last(payload_pending_last),
        .out_valid(decoder_out_valid), .out_ready(state == ST_RUN),
        .out_count(decoder_out_count),
        .out_symbol0(decoder_out_symbol0),
        .out_symbol1(decoder_out_symbol1),
        .out_last(decoder_out_last), .busy(decoder_busy),
        .done(decoder_done), .error_valid(decoder_error_valid),
        .error_code(decoder_error_code)
    );

    reg [7:0] scale_feed_index;
    reg scale_pending_valid;
    reg [31:0] scale_pending_data;
    reg [3:0] scale_pending_keep;
    reg scale_pending_last;
    wire scale_in_ready;
    wire scale_out_valid;
    wire [SCALE_BITS-1:0] scale_out_data;
    wire scale_unpack_busy;
    wire scale_done;
    wire scale_error_valid;
    wire [7:0] scale_error_code;
    wire scale_in_valid = (state == ST_RUN) && scale_pending_valid;
    wire scale_pending_fire = scale_in_valid && scale_in_ready;

    kv_v03_scale_unpacker_param #(
        .SCALE_BITS(SCALE_BITS),
        .MAX_SCALES(128)
    ) u_scale_unpacker (
        .clk(clk), .rst_n(engine_rst_n), .start(scale_start),
        .expected_scales({1'b0, token_count_reg}),
        .in_valid(scale_in_valid), .in_ready(scale_in_ready),
        .in_data(scale_pending_data), .in_byte_valid(scale_pending_keep),
        .in_last(scale_pending_last), .out_valid(scale_out_valid),
        .out_ready(state == ST_RUN), .out_scale(scale_out_data),
        .busy(scale_unpack_busy), .done(scale_done),
        .error_valid(scale_error_valid), .error_code(scale_error_code)
    );

    reg [14:0] symbol_write_count;
    reg [8:0] scale_write_count;
    reg [79:0] pack_reg;
    reg decoder_done_seen;
    reg scale_done_seen;
    wire [10:0] committed_p16_words = expected_symbols_reg >> 4;
    assign busy = state != ST_IDLE;

    always @(posedge clk) begin
        if (!rst_n || flush) begin
            state <= ST_IDLE;
            stream_is_v_reg <= 1'b0;
            raw_mode_reg <= 1'b0;
            payload_bytes_reg <= 16'd0;
            expected_symbols_reg <= 15'd0;
            token_count_reg <= 8'd0;
            scale_slice_bytes_reg <= 9'd0;
            payload_word_count_reg <= 12'd0;
            scale_word_count_reg <= 8'd0;
            payload_feed_index <= 12'd0;
            payload_pending_valid <= 1'b0;
            payload_pending_data <= 32'd0;
            payload_pending_keep <= 4'd0;
            payload_pending_last <= 1'b0;
            scale_feed_index <= 8'd0;
            scale_pending_valid <= 1'b0;
            scale_pending_data <= 32'd0;
            scale_pending_keep <= 4'd0;
            scale_pending_last <= 1'b0;
            symbol_write_count <= 15'd0;
            scale_write_count <= 9'd0;
            pack_reg <= 80'd0;
            decoder_done_seen <= 1'b0;
            scale_done_seen <= 1'b0;
            committed <= 1'b0;
            complete_pulse <= 1'b0;
            error_valid <= 1'b0;
            error_source <= 2'd0;
            error_code <= 8'd0;
            p16_rd_valid <= 1'b0;
            p16_rd_data <= 80'd0;
            scale_rd_valid <= 1'b0;
            scale_rd_data <= {SCALE_BITS{1'b0}};
        end else begin
            complete_pulse <= 1'b0;
            error_valid <= 1'b0;
            p16_rd_valid <= 1'b0;
            scale_rd_valid <= 1'b0;

            if (state == ST_DONE && !release_lane) begin
                if (p16_rd_en &&
                    ({1'b0, p16_rd_addr} < committed_p16_words)) begin
                    p16_rd_valid <= 1'b1;
                    p16_rd_data <= p16_mem[p16_rd_addr];
                end
                if (scale_rd_en &&
                    ({1'b0, scale_rd_addr} < token_count_reg)) begin
                    scale_rd_valid <= 1'b1;
                    scale_rd_data <= decoded_scale_mem[scale_rd_addr];
                end
            end

            if (allocate) begin
                if (state != ST_IDLE) begin
                    state <= ST_IDLE;
                    committed <= 1'b0;
                    error_valid <= 1'b1;
                    error_source <= SOURCE_INTERNAL;
                    error_code <= ERR_PROTOCOL;
                end else begin
                    state <= ST_CAPTURE;
                    stream_is_v_reg <= alloc_stream_is_v;
                    raw_mode_reg <= alloc_raw_mode;
                    payload_bytes_reg <= alloc_payload_bytes;
                    expected_symbols_reg <= alloc_expected_symbols;
                    token_count_reg <= alloc_token_count;
                    scale_slice_bytes_reg <= alloc_scale_slice_bytes;
                    payload_word_count_reg <=
                        (alloc_payload_bytes + 16'd3) >> 2;
                    scale_word_count_reg <=
                        (alloc_scale_slice_bytes + 9'd3) >> 2;
                    committed <= 1'b0;
                end
            end else begin
                if (state == ST_CAPTURE) begin
                    if (payload_wr_en)
                        payload_mem[payload_wr_addr] <= payload_wr_data;
                    if (scale_wr_en)
                        scale_capture_mem[scale_wr_addr] <= scale_wr_data;
                    if (decode_start) begin
                        state <= ST_LAUNCH;
                        payload_feed_index <= 12'd0;
                        payload_pending_valid <= 1'b0;
                        scale_feed_index <= 8'd0;
                        scale_pending_valid <= 1'b0;
                        symbol_write_count <= 15'd0;
                        scale_write_count <= 9'd0;
                        pack_reg <= 80'd0;
                        decoder_done_seen <= 1'b0;
                        scale_done_seen <= 1'b0;
                    end
                end else if (state == ST_LAUNCH) begin
                    state <= ST_RUN;
                end else if (state == ST_RUN) begin
                    if (decoder_error_valid || scale_error_valid) begin
                        state <= ST_IDLE;
                        committed <= 1'b0;
                        payload_pending_valid <= 1'b0;
                        scale_pending_valid <= 1'b0;
                        error_valid <= 1'b1;
                        if (decoder_error_valid) begin
                            error_source <= SOURCE_DECODER;
                            error_code <= decoder_error_code;
                        end else begin
                            error_source <= SOURCE_SCALE;
                            error_code <= scale_error_code;
                        end
                    end else begin
                        if (payload_pending_fire)
                            payload_pending_valid <= 1'b0;
                        if ((!payload_pending_valid ||
                             payload_pending_fire) &&
                            (payload_feed_index <
                             payload_word_count_reg) &&
                            decoder_busy) begin
                            payload_pending_valid <= 1'b1;
                            payload_pending_data <=
                                payload_mem[payload_feed_index];
                            payload_pending_keep <=
                                ((payload_feed_index + 1'b1) ==
                                 payload_word_count_reg) ?
                                final_keep(payload_bytes_reg[1:0]) :
                                4'b1111;
                            payload_pending_last <=
                                ((payload_feed_index + 1'b1) ==
                                 payload_word_count_reg);
                            payload_feed_index <=
                                payload_feed_index + 1'b1;
                        end

                        if (scale_pending_fire)
                            scale_pending_valid <= 1'b0;
                        if ((!scale_pending_valid ||
                             scale_pending_fire) &&
                            (scale_feed_index < scale_word_count_reg) &&
                            scale_unpack_busy) begin
                            scale_pending_valid <= 1'b1;
                            scale_pending_data <=
                                scale_capture_mem[scale_feed_index[6:0]];
                            scale_pending_keep <=
                                ((scale_feed_index + 1'b1) ==
                                 scale_word_count_reg) ?
                                final_keep(scale_slice_bytes_reg[1:0]) :
                                4'b1111;
                            scale_pending_last <=
                                ((scale_feed_index + 1'b1) ==
                                 scale_word_count_reg);
                            scale_feed_index <= scale_feed_index + 1'b1;
                        end

                        if (decoder_out_valid) begin
                            if ((decoder_out_count != 1) ||
                                (symbol_write_count >=
                                 expected_symbols_reg)) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_source <= SOURCE_INTERNAL;
                                error_code <= ERR_PROTOCOL;
                            end else begin
                                pack_reg[
                                    (symbol_write_count[3:0]*5) +: 5] <=
                                    decoder_out_symbol0[4:0];
                                if (symbol_write_count[3:0] == 4'hf)
                                    p16_mem[
                                        symbol_write_count[13:4]] <=
                                        {decoder_out_symbol0[4:0],
                                         pack_reg[74:0]};
                                symbol_write_count <=
                                    symbol_write_count + 1'b1;
                            end
                        end
                        if (scale_out_valid) begin
                            if (scale_write_count >=
                                {1'b0, token_count_reg}) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_source <= SOURCE_INTERNAL;
                                error_code <= ERR_PROTOCOL;
                            end else begin
                                decoded_scale_mem[
                                    scale_write_count[6:0]] <=
                                    scale_out_data;
                                scale_write_count <=
                                    scale_write_count + 1'b1;
                            end
                        end
                        if (decoder_done)
                            decoder_done_seen <= 1'b1;
                        if (scale_done)
                            scale_done_seen <= 1'b1;

                        if ((decoder_done || decoder_done_seen) &&
                            (scale_done || scale_done_seen)) begin
                            if ((symbol_write_count !=
                                 expected_symbols_reg) ||
                                (scale_write_count !=
                                 {1'b0, token_count_reg})) begin
                                state <= ST_IDLE;
                                committed <= 1'b0;
                                error_valid <= 1'b1;
                                error_source <= SOURCE_INTERNAL;
                                error_code <= ERR_PROTOCOL;
                            end else begin
                                state <= ST_DONE;
                                committed <= 1'b1;
                                complete_pulse <= 1'b1;
                            end
                        end
                    end
                end else if (state == ST_DONE) begin
                    if (release_lane) begin
                        state <= ST_IDLE;
                        committed <= 1'b0;
                        p16_rd_valid <= 1'b0;
                        scale_rd_valid <= 1'b0;
                    end
                end
            end
        end
    end

    wire unused = decoder_out_last ^ scale_unpack_busy;

`ifndef SYNTHESIS
    initial begin
        if (MAX_PAYLOAD_BYTES < 10240)
            $error("typed decode lane payload RAM is too small");
        if (MAX_SYMBOLS < 16384)
            $error("typed decode lane P16 RAM is too small");
    end
`endif
endmodule


// Contiguous LSB-first fixed-width scale unpacker used by every lane.  The
// implementation is deliberately shared by UQ4.8 (12-bit) and UQ5.11
// (16-bit) builds so the lane-bank control does not duplicate datapaths.
module kv_v03_scale_unpacker_param #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_SCALES = 128
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start,
    input  wire [8:0]              expected_scales,
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire [31:0]             in_data,
    input  wire [3:0]              in_byte_valid,
    input  wire                    in_last,
    output wire                    out_valid,
    input  wire                    out_ready,
    output wire [SCALE_BITS-1:0]   out_scale,
    output wire                    busy,
    output reg                     done,
    output reg                     error_valid,
    output reg  [7:0]              error_code
);
    localparam [7:0] ERR_UNDERFLOW = 8'h01;
    localparam [7:0] ERR_OVERFLOW  = 8'h02;
    localparam [7:0] ERR_PROTOCOL  = 8'h03;

    reg active;
    reg [63:0] reservoir;
    reg [6:0] bit_count;
    reg [8:0] emitted_scales;
    reg [8:0] expected_reg;
    reg saw_last;

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    function integer byte_count;
        input [3:0] mask;
        begin
            case (mask)
                4'b0001: byte_count = 1;
                4'b0011: byte_count = 2;
                4'b0111: byte_count = 3;
                4'b1111: byte_count = 4;
                default: byte_count = 0;
            endcase
        end
    endfunction

    function [31:0] valid_data;
        input [31:0] data;
        input [3:0] mask;
        begin
            case (mask)
                4'b0001: valid_data = {24'b0, data[7:0]};
                4'b0011: valid_data = {16'b0, data[15:0]};
                4'b0111: valid_data = {8'b0, data[23:0]};
                default: valid_data = data;
            endcase
        end
    endfunction

    function low_tail_nonzero;
        input [63:0] value;
        input [2:0] count;
        reg [7:0] mask;
        begin
            mask = (8'h01 << count) - 1'b1;
            low_tail_nonzero = |(value[7:0] & mask);
        end
    endfunction

    assign busy = active;
    assign out_valid = active && (emitted_scales < expected_reg) &&
                       (bit_count >= SCALE_BITS);
    assign out_scale = reservoir[SCALE_BITS-1:0];
    assign in_ready = active && !saw_last && (bit_count <= 32) &&
                      !(out_valid && !out_ready);
    wire pop = out_valid && out_ready;
    wire push = in_valid && in_ready;

    reg [63:0] work_reservoir;
    reg [6:0] work_bit_count;
    reg [8:0] work_emitted;
    reg work_saw_last;
    integer pushed_bits;
    always @* begin
        work_reservoir = reservoir;
        work_bit_count = bit_count;
        work_emitted = emitted_scales;
        work_saw_last = saw_last;
        pushed_bits = 0;
        if (pop) begin
            work_reservoir = work_reservoir >> SCALE_BITS;
            work_bit_count = work_bit_count - SCALE_BITS;
            work_emitted = work_emitted + 1'b1;
        end
        if (push && valid_mask(in_byte_valid)) begin
            pushed_bits = byte_count(in_byte_valid) * 8;
            work_reservoir = work_reservoir |
                ({32'b0, valid_data(in_data, in_byte_valid)}
                 << work_bit_count);
            work_bit_count = work_bit_count + pushed_bits;
            if (in_last)
                work_saw_last = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            reservoir <= 64'd0;
            bit_count <= 7'd0;
            emitted_scales <= 9'd0;
            expected_reg <= 9'd0;
            saw_last <= 1'b0;
            done <= 1'b0;
            error_valid <= 1'b0;
            error_code <= 8'd0;
        end else begin
            done <= 1'b0;
            error_valid <= 1'b0;
            if (start) begin
                reservoir <= 64'd0;
                bit_count <= 7'd0;
                emitted_scales <= 9'd0;
                expected_reg <= expected_scales;
                saw_last <= 1'b0;
                if (expected_scales == 0 ||
                    expected_scales > MAX_SCALES) begin
                    active <= 1'b0;
                    error_valid <= 1'b1;
                    error_code <= ERR_PROTOCOL;
                end else begin
                    active <= 1'b1;
                end
            end else if (active) begin
                if (push && !valid_mask(in_byte_valid)) begin
                    active <= 1'b0;
                    error_valid <= 1'b1;
                    error_code <= ERR_PROTOCOL;
                end else begin
                    reservoir <= work_reservoir;
                    bit_count <= work_bit_count;
                    emitted_scales <= work_emitted;
                    saw_last <= work_saw_last;
                    if (work_saw_last &&
                        work_emitted < expected_reg &&
                        work_bit_count < SCALE_BITS) begin
                        active <= 1'b0;
                        error_valid <= 1'b1;
                        error_code <= ERR_UNDERFLOW;
                    end else if (work_saw_last &&
                                 work_emitted == expected_reg) begin
                        active <= 1'b0;
                        if (work_bit_count > 7 ||
                            low_tail_nonzero(work_reservoir,
                                             work_bit_count[2:0])) begin
                            error_valid <= 1'b1;
                            error_code <= ERR_OVERFLOW;
                        end else begin
                            done <= 1'b1;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("scale unpacker supports 12 or 16 bits");
        if (MAX_SCALES < 1 || MAX_SCALES > 511)
            $error("scale unpacker MAX_SCALES must be 1..511");
    end
`endif
endmodule

`default_nettype wire
