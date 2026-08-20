// kv_v03_decoded_page_buffer.v -- fail-closed private decoded-page staging.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// This block consumes one page which has already passed the page-record CRC
// gate.  Header bytes [0:11] and the record trailer are deliberately never
// presented to the symbol decoder.  Codes and scales remain tentative until
// both parsers complete exactly; only the commit handshake publishes them.
module kv_v03_decoded_page_buffer #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_SYMBOLS = 16384,
    parameter integer MAX_SCALES = 128,
    parameter integer MAX_PAYLOAD_BYTES = 10240
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    start_valid,
    output wire                    start_ready,
    input  wire [63:0]             start_task_tag,
    input  wire [4:0]              start_page_index,
    input  wire                    start_stream_is_v,
    input  wire                    start_raw_mode,
    input  wire [15:0]             start_payload_bytes,
    input  wire [14:0]             start_expected_symbols,
    input  wire [7:0]              start_token_count,
    input  wire [8:0]              start_scale_slice_bytes,

    input  wire                    abort,
    input  wire                    page_release,

    // Publication and ownership.  commit_valid is held until accepted.  The
    // committed memories remain owned and readable until page_release.
    output wire                    commit_valid,
    input  wire                    commit_ready,
    output wire                    page_active,
    output wire                    busy,
    output wire [63:0]             page_task_tag,
    output wire [4:0]              page_index,
    output wire                    page_stream_is_v,
    output wire                    page_raw_mode,
    output wire [15:0]             page_payload_bytes,
    output wire [14:0]             page_expected_symbols,
    output wire [7:0]              page_token_count,
    output wire [8:0]              page_scale_slice_bytes,

    // One-request-at-a-time synchronous scratch interfaces.  Data word zero
    // is the first record-header word; payload reads therefore begin at word
    // address three.  Scale word zero is the first byte of this page's slice.
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

    // Synchronous committed-memory reads.  Requests outside the committed
    // descriptor's range intentionally produce no valid pulse.
    input  wire                    code_rd_en,
    input  wire [13:0]             code_rd_addr,
    output wire                    code_rd_valid,
    output reg signed [4:0]        code_rd_data,
    input  wire                    committed_scale_rd_en,
    input  wire [6:0]              committed_scale_rd_addr,
    output wire                    committed_scale_rd_valid,
    output reg  [SCALE_BITS-1:0]   committed_scale_rd_data,

    output reg                     error_valid,
    output reg  [2:0]              error_source,
    output reg  [7:0]              error_code,
    output reg  [63:0]             error_task_tag,
    output reg  [4:0]              error_page_index,
    output reg                     error_stream_is_v,
    output reg                     aborted,
    output reg  [63:0]             aborted_task_tag,
    output reg  [4:0]              aborted_page_index,
    output reg                     aborted_stream_is_v,

    input  wire                    clear_counters,
    output reg  [31:0]             decoder_starvation_cycles,
    output reg  [31:0]             scale_starvation_cycles,
    output reg  [31:0]             raw_fallback_count
);
    localparam [2:0] ST_IDLE   = 3'd0,
                     ST_LAUNCH = 3'd1,
                     ST_RUN    = 3'd2,
                     ST_COMMIT = 3'd3,
                     ST_ACTIVE = 3'd4,
                     ST_DRAIN  = 3'd5;

    localparam [2:0] ERROR_SOURCE_DESCRIPTOR = 3'd1,
                     ERROR_SOURCE_DATA       = 3'd2,
                     ERROR_SOURCE_DECODER    = 3'd3,
                     ERROR_SOURCE_SCALE      = 3'd4;

    localparam [7:0] ERR_DESCRIPTOR = 8'h01,
                     ERR_UNEXPECTED = 8'h01,
                     ERR_OFFSET     = 8'h02,
                     ERR_FRAMING    = 8'h03,
                     ERR_COUNT      = 8'h04;

    reg [2:0] state;

    reg [63:0] task_tag_reg;
    reg [4:0] page_index_reg;
    reg stream_is_v_reg;
    reg raw_mode_reg;
    reg [15:0] payload_bytes_reg;
    reg [14:0] expected_symbols_reg;
    reg [7:0] token_count_reg;
    reg [8:0] scale_slice_bytes_reg;

    reg [11:0] data_word_count_reg;
    reg [7:0] scale_word_count_reg;
    reg [11:0] data_request_count;
    reg [7:0] scale_request_count;

    reg data_outstanding;
    reg [11:0] data_outstanding_index;
    reg [3:0] data_outstanding_keep;
    reg data_outstanding_last;
    reg [13:0] data_outstanding_offset;
    reg scale_outstanding;
    reg [7:0] scale_outstanding_index;
    reg [3:0] scale_outstanding_keep;
    reg scale_outstanding_last;
    reg [8:0] scale_outstanding_offset;

    reg data_pending_valid;
    reg [31:0] data_pending_data;
    reg [3:0] data_pending_keep;
    reg data_pending_last;
    reg scale_pending_valid;
    reg [31:0] scale_pending_data;
    reg [3:0] scale_pending_keep;
    reg scale_pending_last;

    reg [14:0] code_write_count;
    reg [8:0] scale_write_count;
    reg decoder_done_seen;
    reg scale_done_seen;

    (* ram_style = "block" *) reg signed [4:0] code_mem [0:MAX_SYMBOLS-1];
    (* ram_style = "block" *) reg [SCALE_BITS-1:0] scale_mem [0:MAX_SCALES-1];

    reg code_rd_valid_reg;
    reg committed_scale_rd_valid_reg;
    assign code_rd_valid = code_rd_valid_reg && (state == ST_ACTIVE) &&
                           !abort;
    assign committed_scale_rd_valid = committed_scale_rd_valid_reg &&
                                      (state == ST_ACTIVE) && !abort;

    // Never acknowledge a new descriptor in the same cycle as an untagged
    // late scratch response; that response is reported against the retained
    // old descriptor instead of being allowed to steal a valid/ready beat.
    assign start_ready = (state == ST_IDLE) &&
                         !data_rd_valid && !scale_rd_valid;
    wire start_fire = start_valid && start_ready;
    assign commit_valid = (state == ST_COMMIT);
    assign page_active = (state == ST_ACTIVE);
    assign busy = (state != ST_IDLE);

    assign page_task_tag = task_tag_reg;
    assign page_index = page_index_reg;
    assign page_stream_is_v = stream_is_v_reg;
    assign page_raw_mode = raw_mode_reg;
    assign page_payload_bytes = payload_bytes_reg;
    assign page_expected_symbols = expected_symbols_reg;
    assign page_token_count = token_count_reg;
    assign page_scale_slice_bytes = scale_slice_bytes_reg;

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

    wire [14:0] descriptor_symbols = {start_token_count, 7'b0};
    wire [19:0] descriptor_raw_bits = start_expected_symbols *
                                      (start_stream_is_v ? 20'd5 : 20'd4);
    wire [15:0] descriptor_raw_bytes =
        (descriptor_raw_bits + 20'd7) >> 3;
    wire [16:0] descriptor_scale_bits = start_token_count * SCALE_BITS;
    wire [8:0] descriptor_scale_bytes =
        (descriptor_scale_bits + 17'd7) >> 3;
    wire descriptor_bad = (start_token_count == 0) ||
                          (start_token_count > MAX_SCALES) ||
                          (start_expected_symbols == 0) ||
                          (start_expected_symbols > MAX_SYMBOLS) ||
                          (start_expected_symbols != descriptor_symbols) ||
                          (start_payload_bytes == 0) ||
                          (start_payload_bytes > MAX_PAYLOAD_BYTES) ||
                          (start_scale_slice_bytes != descriptor_scale_bytes) ||
                          (start_raw_mode &&
                           (start_payload_bytes != descriptor_raw_bytes)) ||
                          (!start_raw_mode &&
                           (start_payload_bytes >= descriptor_raw_bytes));

    wire decoder_start = (state == ST_LAUNCH);
    wire decoder_in_valid = data_pending_valid && (state == ST_RUN);
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

    kv_v03_symbol_decoder #(
        .SYMBOL_WIDTH(5),
        .STREAM_IS_V(1),
        .RUNTIME_STREAM_SELECT(1),
        .SYMBOLS_PER_CYCLE(1),
        .MAX_SYMBOLS(MAX_SYMBOLS)
    ) u_decoder (
        .clk(clk), .rst_n(rst_n), .start(decoder_start),
        .integrity_passed(1'b1), .stream_is_v(stream_is_v_reg),
        .raw_mode(raw_mode_reg), .expected_symbols(expected_symbols_reg),
        .in_valid(decoder_in_valid), .in_ready(decoder_in_ready),
        .in_data(data_pending_data),
        .in_byte_valid(data_pending_keep), .in_last(data_pending_last),
        .out_valid(decoder_out_valid), .out_ready(state == ST_RUN),
        .out_count(decoder_out_count), .out_symbol0(decoder_out_symbol0),
        .out_symbol1(decoder_out_symbol1), .out_last(decoder_out_last),
        .busy(decoder_busy), .done(decoder_done),
        .error_valid(decoder_error_valid),
        .error_code(decoder_error_code)
    );

    wire scale_start = (state == ST_LAUNCH);
    wire scale_in_valid = scale_pending_valid && (state == ST_RUN);
    wire scale_in_ready;
    wire scale_out_valid;
    wire [SCALE_BITS-1:0] scale_out_data;
    wire scale_busy;
    wire scale_done;
    wire scale_error_valid;
    wire [7:0] scale_error_code;

    generate
        if (SCALE_BITS == 12) begin : g_scale12
            wire [11:0] scale12_out;
            kv_v03_scale12_reader #(
                .MAX_SCALES(MAX_SCALES)
            ) u_scale12_reader (
                .clk(clk), .rst_n(rst_n), .start(scale_start),
                .expected_scales({1'b0, token_count_reg}),
                .in_valid(scale_in_valid), .in_ready(scale_in_ready),
                .in_data(scale_pending_data),
                .in_byte_valid(scale_pending_keep),
                .in_last(scale_pending_last), .out_valid(scale_out_valid),
                .out_ready(state == ST_RUN), .out_scale(scale12_out),
                .busy(scale_busy), .done(scale_done),
                .error_valid(scale_error_valid),
                .error_code(scale_error_code)
            );
            assign scale_out_data = scale12_out;
        end else begin : g_scale16
            reg active;
            reg [63:0] reservoir;
            reg [6:0] bit_count;
            reg [8:0] emitted;
            reg [8:0] expected;
            reg saw_last;
            reg done_reg;
            reg error_reg;
            reg [7:0] error_code_reg;

            wire pop = scale_out_valid && (state == ST_RUN);
            wire push = scale_in_valid && scale_in_ready;
            assign scale_in_ready = active && !saw_last &&
                                    (bit_count <= 32);
            assign scale_out_valid = active && (emitted < expected) &&
                                     (bit_count >= 16);
            assign scale_out_data = reservoir[15:0];
            assign scale_busy = active;
            assign scale_done = done_reg;
            assign scale_error_valid = error_reg;
            assign scale_error_code = error_code_reg;

            reg [63:0] work_reservoir;
            reg [6:0] work_bit_count;
            reg [8:0] work_emitted;
            reg work_saw_last;
            integer pushed_bits;
            always @* begin
                work_reservoir = reservoir;
                work_bit_count = bit_count;
                work_emitted = emitted;
                work_saw_last = saw_last;
                pushed_bits = 0;
                if (pop) begin
                    work_reservoir = work_reservoir >> 16;
                    work_bit_count = work_bit_count - 16;
                    work_emitted = work_emitted + 1'b1;
                end
                if (push && valid_mask(scale_pending_keep)) begin
                    case (scale_pending_keep)
                        4'b0001: pushed_bits = 8;
                        4'b0011: pushed_bits = 16;
                        4'b0111: pushed_bits = 24;
                        default: pushed_bits = 32;
                    endcase
                    work_reservoir = work_reservoir |
                        ({32'b0, scale_pending_data} << work_bit_count);
                    work_bit_count = work_bit_count + pushed_bits;
                    if (scale_pending_last)
                        work_saw_last = 1'b1;
                end
            end

            always @(posedge clk) begin
                if (!rst_n) begin
                    active <= 1'b0;
                    reservoir <= 64'b0;
                    bit_count <= 7'b0;
                    emitted <= 9'b0;
                    expected <= 9'b0;
                    saw_last <= 1'b0;
                    done_reg <= 1'b0;
                    error_reg <= 1'b0;
                    error_code_reg <= 8'b0;
                end else begin
                    done_reg <= 1'b0;
                    error_reg <= 1'b0;
                    if (scale_start) begin
                        active <= 1'b1;
                        reservoir <= 64'b0;
                        bit_count <= 7'b0;
                        emitted <= 9'b0;
                        expected <= {1'b0, token_count_reg};
                        saw_last <= 1'b0;
                    end else if (active) begin
                        reservoir <= work_reservoir;
                        bit_count <= work_bit_count;
                        emitted <= work_emitted;
                        saw_last <= work_saw_last;
                        if (push && !valid_mask(scale_pending_keep)) begin
                            active <= 1'b0;
                            error_reg <= 1'b1;
                            error_code_reg <= 8'h03;
                        end else if (work_saw_last &&
                                     work_emitted < expected &&
                                     work_bit_count < 16) begin
                            active <= 1'b0;
                            error_reg <= 1'b1;
                            error_code_reg <= 8'h01;
                        end else if (work_saw_last &&
                                     work_emitted == expected) begin
                            active <= 1'b0;
                            if (work_bit_count != 0) begin
                                error_reg <= 1'b1;
                                error_code_reg <= 8'h02;
                            end else begin
                                done_reg <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    wire [3:0] data_issue_keep =
        ((data_request_count + 1'b1) == data_word_count_reg) ?
        final_keep(payload_bytes_reg[1:0]) : 4'b1111;
    wire data_issue_last =
        ((data_request_count + 1'b1) == data_word_count_reg);
    wire [13:0] data_issue_offset =
        14'd12 + {data_request_count, 2'b00};
    assign data_rd_en = (state == ST_RUN) && !abort &&
                        !decoder_error_valid && !scale_error_valid &&
                        !data_rd_valid && !data_outstanding &&
                        !data_pending_valid &&
                        (data_request_count < data_word_count_reg) &&
                        !decoder_done_seen;
    assign data_rd_word_addr = 12'd3 + data_request_count;

    wire [3:0] scale_issue_keep =
        ((scale_request_count + 1'b1) == scale_word_count_reg) ?
        final_keep(scale_slice_bytes_reg[1:0]) : 4'b1111;
    wire scale_issue_last =
        ((scale_request_count + 1'b1) == scale_word_count_reg);
    wire [8:0] scale_issue_offset = {scale_request_count[6:0], 2'b00};
    assign scale_rd_en = (state == ST_RUN) && !abort &&
                         !decoder_error_valid && !scale_error_valid &&
                         !scale_rd_valid && !scale_outstanding &&
                         !scale_pending_valid &&
                         (scale_request_count < scale_word_count_reg) &&
                         !scale_done_seen;
    assign scale_rd_word_addr = scale_request_count[6:0];

    wire data_response_bad = data_rd_valid &&
        (!data_outstanding || !valid_mask(data_rd_byte_valid) ||
         ((data_rd_byte_valid & data_outstanding_keep) !=
          data_outstanding_keep) ||
         (data_rd_byte_offset != data_outstanding_offset) ||
         (data_rd_last && !data_outstanding_last));
    wire scale_response_bad = scale_rd_valid &&
        (!scale_outstanding || !valid_mask(scale_rd_byte_valid) ||
         ((scale_rd_byte_valid & scale_outstanding_keep) !=
          scale_outstanding_keep) ||
         (scale_rd_byte_offset != scale_outstanding_offset) ||
         (scale_rd_last != scale_outstanding_last));

    wire data_pending_fire = decoder_in_valid && decoder_in_ready;
    wire scale_pending_fire = scale_in_valid && scale_in_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            task_tag_reg <= 64'b0;
            page_index_reg <= 5'b0;
            stream_is_v_reg <= 1'b0;
            raw_mode_reg <= 1'b0;
            payload_bytes_reg <= 16'b0;
            expected_symbols_reg <= 15'b0;
            token_count_reg <= 8'b0;
            scale_slice_bytes_reg <= 9'b0;
            data_word_count_reg <= 12'b0;
            scale_word_count_reg <= 8'b0;
            data_request_count <= 12'b0;
            scale_request_count <= 8'b0;
            data_outstanding <= 1'b0;
            data_outstanding_index <= 12'b0;
            data_outstanding_keep <= 4'b0;
            data_outstanding_last <= 1'b0;
            data_outstanding_offset <= 14'b0;
            scale_outstanding <= 1'b0;
            scale_outstanding_index <= 8'b0;
            scale_outstanding_keep <= 4'b0;
            scale_outstanding_last <= 1'b0;
            scale_outstanding_offset <= 9'b0;
            data_pending_valid <= 1'b0;
            data_pending_data <= 32'b0;
            data_pending_keep <= 4'b0;
            data_pending_last <= 1'b0;
            scale_pending_valid <= 1'b0;
            scale_pending_data <= 32'b0;
            scale_pending_keep <= 4'b0;
            scale_pending_last <= 1'b0;
            code_write_count <= 15'b0;
            scale_write_count <= 9'b0;
            decoder_done_seen <= 1'b0;
            scale_done_seen <= 1'b0;
            code_rd_valid_reg <= 1'b0;
            code_rd_data <= 5'sd0;
            committed_scale_rd_valid_reg <= 1'b0;
            committed_scale_rd_data <= {SCALE_BITS{1'b0}};
            error_valid <= 1'b0;
            error_source <= 3'b0;
            error_code <= 8'b0;
            error_task_tag <= 64'b0;
            error_page_index <= 5'b0;
            error_stream_is_v <= 1'b0;
            aborted <= 1'b0;
            aborted_task_tag <= 64'b0;
            aborted_page_index <= 5'b0;
            aborted_stream_is_v <= 1'b0;
            decoder_starvation_cycles <= 32'b0;
            scale_starvation_cycles <= 32'b0;
            raw_fallback_count <= 32'b0;
        end else begin
            error_valid <= 1'b0;
            aborted <= 1'b0;
            code_rd_valid_reg <= 1'b0;
            committed_scale_rd_valid_reg <= 1'b0;

            if (clear_counters) begin
                decoder_starvation_cycles <= 32'b0;
                scale_starvation_cycles <= 32'b0;
                raw_fallback_count <= 32'b0;
            end else if (state == ST_RUN) begin
                if (decoder_busy && decoder_in_ready &&
                    !data_pending_valid &&
                    ((data_request_count < data_word_count_reg) ||
                     data_outstanding))
                    decoder_starvation_cycles <=
                        decoder_starvation_cycles + 1'b1;
                if (scale_busy && scale_in_ready &&
                    !scale_pending_valid &&
                    ((scale_request_count < scale_word_count_reg) ||
                     scale_outstanding))
                    scale_starvation_cycles <=
                        scale_starvation_cycles + 1'b1;
            end

            if ((state == ST_ACTIVE) && !abort && !page_release) begin
                if (code_rd_en &&
                    ({1'b0, code_rd_addr} < expected_symbols_reg)) begin
                    code_rd_valid_reg <= 1'b1;
                    code_rd_data <= code_mem[code_rd_addr];
                end
                if (committed_scale_rd_en &&
                    ({2'b0, committed_scale_rd_addr} <
                     {1'b0, token_count_reg})) begin
                    committed_scale_rd_valid_reg <= 1'b1;
                    committed_scale_rd_data <=
                        scale_mem[committed_scale_rd_addr];
                end
            end

            if (abort && (state != ST_IDLE) && (state != ST_DRAIN)) begin
                aborted <= 1'b1;
                aborted_task_tag <= task_tag_reg;
                aborted_page_index <= page_index_reg;
                aborted_stream_is_v <= stream_is_v_reg;
                data_pending_valid <= 1'b0;
                scale_pending_valid <= 1'b0;
                decoder_done_seen <= 1'b0;
                scale_done_seen <= 1'b0;
                data_outstanding <= data_outstanding && !data_rd_valid;
                scale_outstanding <= scale_outstanding && !scale_rd_valid;
                if ((data_outstanding && !data_rd_valid) ||
                    (scale_outstanding && !scale_rd_valid))
                    state <= ST_DRAIN;
                else
                    state <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        data_pending_valid <= 1'b0;
                        scale_pending_valid <= 1'b0;
                        data_outstanding <= 1'b0;
                        scale_outstanding <= 1'b0;
                        if (data_rd_valid || scale_rd_valid) begin
                            error_valid <= 1'b1;
                            error_source <= data_rd_valid ?
                                ERROR_SOURCE_DATA : ERROR_SOURCE_SCALE;
                            error_code <= ERR_UNEXPECTED;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                        end else if (start_fire) begin
                            task_tag_reg <= start_task_tag;
                            page_index_reg <= start_page_index;
                            stream_is_v_reg <= start_stream_is_v;
                            raw_mode_reg <= start_raw_mode;
                            payload_bytes_reg <= start_payload_bytes;
                            expected_symbols_reg <=
                                start_expected_symbols;
                            token_count_reg <= start_token_count;
                            scale_slice_bytes_reg <=
                                start_scale_slice_bytes;
                            data_word_count_reg <=
                                (start_payload_bytes + 16'd3) >> 2;
                            scale_word_count_reg <=
                                (start_scale_slice_bytes + 9'd3) >> 2;
                            data_request_count <= 12'b0;
                            scale_request_count <= 8'b0;
                            code_write_count <= 15'b0;
                            scale_write_count <= 9'b0;
                            decoder_done_seen <= 1'b0;
                            scale_done_seen <= 1'b0;
                            if (descriptor_bad) begin
                                error_valid <= 1'b1;
                                error_source <= ERROR_SOURCE_DESCRIPTOR;
                                error_code <= ERR_DESCRIPTOR;
                                error_task_tag <= start_task_tag;
                                error_page_index <= start_page_index;
                                error_stream_is_v <= start_stream_is_v;
                            end else begin
                                state <= ST_LAUNCH;
                            end
                        end
                    end

                    ST_LAUNCH: begin
                        state <= ST_RUN;
                    end

                    ST_RUN: begin
                        if (decoder_error_valid || scale_error_valid ||
                            data_response_bad || scale_response_bad) begin
                            error_valid <= 1'b1;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                            if (decoder_error_valid) begin
                                error_source <= ERROR_SOURCE_DECODER;
                                error_code <= decoder_error_code;
                            end else if (scale_error_valid) begin
                                error_source <= ERROR_SOURCE_SCALE;
                                error_code <= scale_error_code;
                            end else if (data_response_bad) begin
                                error_source <= ERROR_SOURCE_DATA;
                                if (!data_outstanding)
                                    error_code <= ERR_UNEXPECTED;
                                else if (data_rd_byte_offset !=
                                         data_outstanding_offset)
                                    error_code <= ERR_OFFSET;
                                else
                                    error_code <= ERR_FRAMING;
                            end else begin
                                error_source <= ERROR_SOURCE_SCALE;
                                if (!scale_outstanding)
                                    error_code <= ERR_UNEXPECTED;
                                else if (scale_rd_byte_offset !=
                                         scale_outstanding_offset)
                                    error_code <= ERR_OFFSET;
                                else
                                    error_code <= ERR_FRAMING;
                            end
                            data_pending_valid <= 1'b0;
                            scale_pending_valid <= 1'b0;
                            decoder_done_seen <= 1'b0;
                            scale_done_seen <= 1'b0;
                            data_outstanding <=
                                data_outstanding && !data_rd_valid;
                            scale_outstanding <=
                                scale_outstanding && !scale_rd_valid;
                            if ((data_outstanding && !data_rd_valid) ||
                                (scale_outstanding && !scale_rd_valid))
                                state <= ST_DRAIN;
                            else
                                state <= ST_IDLE;
                        end else begin
                            if (data_rd_en) begin
                                data_outstanding <= 1'b1;
                                data_outstanding_index <=
                                    data_request_count;
                                data_outstanding_keep <= data_issue_keep;
                                data_outstanding_last <= data_issue_last;
                                data_outstanding_offset <= data_issue_offset;
                                data_request_count <=
                                    data_request_count + 1'b1;
                            end
                            if (scale_rd_en) begin
                                scale_outstanding <= 1'b1;
                                scale_outstanding_index <=
                                    scale_request_count;
                                scale_outstanding_keep <= scale_issue_keep;
                                scale_outstanding_last <= scale_issue_last;
                                scale_outstanding_offset <=
                                    scale_issue_offset;
                                scale_request_count <=
                                    scale_request_count + 1'b1;
                            end

                            if (data_rd_valid) begin
                                data_outstanding <= 1'b0;
                                data_pending_valid <= 1'b1;
                                data_pending_data <= data_rd_data;
                                data_pending_keep <= data_outstanding_keep;
                                data_pending_last <= data_outstanding_last;
                            end else if (data_pending_fire) begin
                                data_pending_valid <= 1'b0;
                            end
                            if (scale_rd_valid) begin
                                scale_outstanding <= 1'b0;
                                scale_pending_valid <= 1'b1;
                                scale_pending_data <= scale_rd_data;
                                scale_pending_keep <= scale_outstanding_keep;
                                scale_pending_last <= scale_outstanding_last;
                            end else if (scale_pending_fire) begin
                                scale_pending_valid <= 1'b0;
                            end

                            if (decoder_out_valid) begin
                                if ((decoder_out_count != 1) ||
                                    (code_write_count >=
                                     expected_symbols_reg)) begin
                                    error_valid <= 1'b1;
                                    error_source <= ERROR_SOURCE_DECODER;
                                    error_code <= ERR_COUNT;
                                    error_task_tag <= task_tag_reg;
                                    error_page_index <= page_index_reg;
                                    error_stream_is_v <= stream_is_v_reg;
                                    data_pending_valid <= 1'b0;
                                    scale_pending_valid <= 1'b0;
                                    state <= ST_IDLE;
                                end else begin
                                    code_mem[code_write_count[13:0]] <=
                                        decoder_out_symbol0;
                                    code_write_count <=
                                        code_write_count + 1'b1;
                                end
                            end
                            if (scale_out_valid) begin
                                if (scale_write_count >=
                                    {1'b0, token_count_reg}) begin
                                    error_valid <= 1'b1;
                                    error_source <= ERROR_SOURCE_SCALE;
                                    error_code <= ERR_COUNT;
                                    error_task_tag <= task_tag_reg;
                                    error_page_index <= page_index_reg;
                                    error_stream_is_v <= stream_is_v_reg;
                                    data_pending_valid <= 1'b0;
                                    scale_pending_valid <= 1'b0;
                                    state <= ST_IDLE;
                                end else begin
                                    scale_mem[scale_write_count[6:0]] <=
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
                                if ((code_write_count !=
                                     expected_symbols_reg) ||
                                    (scale_write_count !=
                                     {1'b0, token_count_reg})) begin
                                    error_valid <= 1'b1;
                                    error_source <=
                                        (code_write_count !=
                                         expected_symbols_reg) ?
                                        ERROR_SOURCE_DECODER :
                                        ERROR_SOURCE_SCALE;
                                    error_code <= ERR_COUNT;
                                    error_task_tag <= task_tag_reg;
                                    error_page_index <= page_index_reg;
                                    error_stream_is_v <= stream_is_v_reg;
                                    state <= ST_IDLE;
                                end else begin
                                    state <= ST_COMMIT;
                                end
                            end
                        end
                    end

                    ST_COMMIT: begin
                        if (commit_ready) begin
                            state <= ST_ACTIVE;
                            if (!clear_counters && raw_mode_reg)
                                raw_fallback_count <=
                                    raw_fallback_count + 1'b1;
                        end
                    end

                    ST_ACTIVE: begin
                        if (page_release)
                            state <= ST_IDLE;
                    end

                    ST_DRAIN: begin
                        if (data_rd_valid)
                            data_outstanding <= 1'b0;
                        if (scale_rd_valid)
                            scale_outstanding <= 1'b0;
                        if ((!data_outstanding || data_rd_valid) &&
                            (!scale_outstanding || scale_rd_valid))
                            state <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_decoded_page_buffer: SCALE_BITS must be 12 or 16");
        if (MAX_SYMBOLS < 16384)
            $error("kv_v03_decoded_page_buffer: MAX_SYMBOLS must cover page128");
        if (MAX_SCALES < 128)
            $error("kv_v03_decoded_page_buffer: MAX_SCALES must cover page128");
        if (MAX_PAYLOAD_BYTES < 10240)
            $error("kv_v03_decoded_page_buffer: payload RAM bound is too small");
    end
`endif
endmodule

`default_nettype wire
