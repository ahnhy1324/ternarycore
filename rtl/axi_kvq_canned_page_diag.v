// axi_kvq_canned_page_diag.v -- host-loaded, CRC-gated canned page diagnostic.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module axi_kvq_canned_page_diag #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_CONTEXT = 128,
    parameter integer COMPILED_PROFILE_ID = 0,
    parameter integer COMPILED_K_CODEBOOK_ID = 1,
    parameter integer COMPILED_V_CODEBOOK_ID = 2,
    parameter integer QK_MULT_STYLE = 2,
    parameter integer AV_MULT_STYLE = 2,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 16
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [2:0]                        s_axi_awprot,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,
    output wire [1:0]                        s_axi_bresp,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [2:0]                        s_axi_arprot,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                        s_axi_rresp,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready
);
    localparam [15:0] REG_CTRL              = 16'h0000;
    localparam [15:0] REG_STATUS            = 16'h0004;
    localparam [15:0] REG_CONTEXT           = 16'h0008;
    localparam [15:0] REG_PAGE_DESC         = 16'h000c;
    localparam [15:0] REG_EPOCH             = 16'h0010;
    localparam [15:0] REG_K_TAG_LO          = 16'h0014;
    localparam [15:0] REG_K_TAG_HI          = 16'h0018;
    localparam [15:0] REG_V_TAG_LO          = 16'h001c;
    localparam [15:0] REG_V_TAG_HI          = 16'h0020;
    localparam [15:0] REG_K_WINDOW          = 16'h0024;
    localparam [15:0] REG_V_WINDOW          = 16'h0028;
    localparam [15:0] REG_PAGE_MODES        = 16'h002c;
    localparam [15:0] REG_ERROR             = 16'h0030;
    localparam [15:0] REG_ERROR_SUBCODE     = 16'h0034;
    localparam [15:0] REG_ID                = 16'h0038;
    localparam [15:0] REG_GEOMETRY          = 16'h003c;
    localparam [15:0] REG_SCALE_FORMAT      = 16'h0040;
    localparam [15:0] REG_PROGRESS          = 16'h0044;
    localparam [15:0] REG_WRAPPER_CYCLES    = 16'h0048;
    localparam [15:0] REG_K_VALID_DATA_REQ  = 16'h004c;
    localparam [15:0] REG_V_VALID_DATA_REQ  = 16'h0050;
    localparam [15:0] REG_K_VALID_SCALE_REQ = 16'h0054;
    localparam [15:0] REG_V_VALID_SCALE_REQ = 16'h0058;
    localparam [15:0] REG_K_COPY_DATA_REQ   = 16'h005c;
    localparam [15:0] REG_V_COPY_DATA_REQ   = 16'h0060;
    localparam [15:0] REG_K_COPY_SCALE_REQ  = 16'h0064;
    localparam [15:0] REG_V_COPY_SCALE_REQ  = 16'h0068;
    localparam [15:0] REG_K_P16_REQ         = 16'h006c;
    localparam [15:0] REG_V_P16_REQ         = 16'h0070;
    localparam [15:0] REG_K_SCALE_REQ       = 16'h0074;
    localparam [15:0] REG_V_SCALE_REQ       = 16'h0078;
    localparam [15:0] REG_K_STARVE          = 16'h007c;
    localparam [15:0] REG_V_STARVE          = 16'h0080;
    localparam [15:0] REG_K_STARVE_HIGH     = 16'h0084;
    localparam [15:0] REG_V_STARVE_HIGH     = 16'h0088;
    localparam [15:0] REG_SCORE_COUNT       = 16'h008c;
    localparam [15:0] REG_RESULT_COUNT      = 16'h0090;
    localparam [15:0] REG_ROW_ABORT_COUNT   = 16'h0094;
    localparam [15:0] REG_RAW_PAGE_COUNT    = 16'h0098;
    localparam [15:0] REG_DECODER_FAULTS    = 16'h009c;
    localparam [15:0] REG_ERROR_K_TAG_LO    = 16'h00a0;
    localparam [15:0] REG_ERROR_K_TAG_HI    = 16'h00a4;
    localparam [15:0] REG_ERROR_V_TAG_LO    = 16'h00a8;
    localparam [15:0] REG_ERROR_V_TAG_HI    = 16'h00ac;
    localparam [15:0] REG_ERROR_EPOCH_PAGE  = 16'h00b0;
    localparam [15:0] REG_DENOM0            = 16'h0100;
    localparam [15:0] REG_RECIP0            = 16'h0120;

    localparam [15:0] Q_BASE                = 16'h1000;
    localparam [15:0] K_PAGE_BASE           = 16'h2000;
    localparam [15:0] V_PAGE_BASE           = 16'h5000;
    localparam [15:0] K_SCALE_BASE          = 16'h8000;
    localparam [15:0] V_SCALE_BASE          = 16'h8400;
    localparam [15:0] SCORE_BASE            = 16'h9000;
    localparam [15:0] RESULT_BASE           = 16'ha000;

    localparam integer MAX_PAGE_BYTES = 10256;
    localparam integer PAGE_WORDS = (MAX_PAGE_BYTES + 3) / 4;
    localparam integer SCALE_BYTES_MAX = 256;
    localparam integer SCALE_WORDS = SCALE_BYTES_MAX / 4;
    localparam [31:0] CORE_ID = 32'h4b56_0304;

    localparam [3:0] ST_IDLE        = 4'd0,
                     ST_Q_LOAD      = 4'd1,
                     ST_VALIDATE    = 4'd2,
                     ST_DECODE      = 4'd3,
                     ST_ARITH_START = 4'd4,
                     ST_ARITH_RUN   = 4'd5,
                     ST_DRAIN       = 4'd6,
                     ST_FAULT       = 4'd7;

    localparam [7:0] ERR_CONFIG    = 8'h01,
                     ERR_VALIDATOR = 8'h02,
                     ERR_LANE      = 8'h03,
                     ERR_ARITH     = 8'h04,
                     ERR_ABORT     = 8'h05,
                     ERR_BUSY      = 8'h06,
                     ERR_INTERNAL  = 8'hff;

    localparam [2:0] SRC_NONE  = 3'd0,
                     SRC_HOST  = 3'd1,
                     SRC_K     = 3'd2,
                     SRC_V     = 3'd3,
                     SRC_ARITH = 3'd4;

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobe;
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobe[byte_index])
                    merge_wstrb[(byte_index*8) +: 8] =
                        new_value[(byte_index*8) +: 8];
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

    reg aw_hold, w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [31:0] wdata_hold;
    reg [3:0] wstrb_hold;
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp = 2'b00;
    wire write_commit = aw_hold && w_hold && !s_axi_bvalid;
    wire ctrl_write = write_commit && awaddr_hold[15:0] == REG_CTRL &&
                      wstrb_hold[0];
    wire ctrl_start = ctrl_write && wdata_hold[0];
    wire ctrl_clear = ctrl_write && wdata_hold[1];
    wire ctrl_abort = ctrl_write && wdata_hold[2];
    wire ctrl_clear_counters = ctrl_write && wdata_hold[3];

    reg [3:0] state;
    reg [12:0] context_reg;
    reg [4:0] page_index_reg;
    reg [5:0] page_count_reg;
    reg [15:0] epoch_reg;
    reg [63:0] k_tag_reg, v_tag_reg;
    reg [13:0] k_window_reg, v_window_reg;
    reg expected_k_raw, expected_v_raw;

    (* ram_style = "block" *) reg [31:0] q_mem [0:127];
    (* ram_style = "block" *) reg [31:0] k_page_mem [0:PAGE_WORDS-1];
    (* ram_style = "block" *) reg [31:0] v_page_mem [0:PAGE_WORDS-1];
    (* ram_style = "block" *) reg [31:0] k_scale_mem [0:SCALE_WORDS-1];
    (* ram_style = "block" *) reg [31:0] v_scale_mem [0:SCALE_WORDS-1];
    reg [127:0] q_word_valid;
    reg [PAGE_WORDS-1:0] k_page_word_valid, v_page_word_valid;
    reg [SCALE_WORDS-1:0] k_scale_word_valid, v_scale_word_valid;
    reg [11:0] k_page_valid_count, v_page_valid_count;
    reg [6:0] k_scale_valid_count, v_scale_valid_count;

    (* ram_style = "block" *) reg [16:0] score_mem [0:511];
    (* ram_style = "block" *) reg [66:0] result_mem [0:511];
    reg [9:0] stored_score_count;
    reg [9:0] stored_result_count;

    reg done_sticky, error_sticky, aborted_sticky, result_valid_sticky;
    reg [7:0] error_code_reg, error_subcode_reg;
    reg [2:0] error_source_reg;
    reg [63:0] error_k_tag_reg, error_v_tag_reg;
    reg [15:0] error_epoch_reg;
    reg [4:0] error_page_reg;
    reg [31:0] wrapper_cycles;
    reg [31:0] k_validator_data_requests, v_validator_data_requests;
    reg [31:0] k_validator_scale_requests, v_validator_scale_requests;
    reg [31:0] k_copy_data_requests, v_copy_data_requests;
    reg [31:0] k_copy_scale_requests, v_copy_scale_requests;
    reg [31:0] row_abort_count, raw_page_count, decoder_fault_count;

    wire top_busy = state != ST_IDLE && state != ST_FAULT;
    wire top_draining = state == ST_DRAIN;

    wire [8:0] expected_scale_bytes =
        (SCALE_BITS == 12) ? ((context_reg * 12 + 7) >> 3) :
                             (context_reg << 1);
    wire [14:0] expected_symbols = {2'b0, context_reg} << 7;
    wire [11:0] k_required_words = (k_window_reg + 3) >> 2;
    wire [11:0] v_required_words = (v_window_reg + 3) >> 2;
    wire [6:0] scale_required_words = (expected_scale_bytes + 3) >> 2;

    wire storage_ready = &q_word_valid && context_reg != 0 &&
        context_reg <= MAX_CONTEXT && page_count_reg != 0 &&
        page_count_reg <= 32 && page_index_reg < page_count_reg &&
        k_window_reg >= 12 && k_window_reg <= MAX_PAGE_BYTES &&
        v_window_reg >= 12 && v_window_reg <= MAX_PAGE_BYTES &&
        k_page_valid_count >= k_required_words &&
        v_page_valid_count >= v_required_words &&
        k_scale_valid_count >= scale_required_words &&
        v_scale_valid_count >= scale_required_words;

    // CRC/page validators --------------------------------------------------
    reg k_validator_started, v_validator_started;
    reg [11:0] k_validator_data_index, v_validator_data_index;
    reg [6:0] k_validator_scale_index, v_validator_scale_index;
    reg k_validator_data_word_valid, v_validator_data_word_valid;
    reg k_validator_scale_word_valid, v_validator_scale_word_valid;
    reg [31:0] k_page_read_data, v_page_read_data;
    reg [31:0] k_scale_read_data, v_scale_read_data;
    wire k_validator_cmd_ready, v_validator_cmd_ready;
    wire k_validator_busy, v_validator_busy;
    wire k_validator_error, v_validator_error;
    wire [7:0] k_validator_error_code, v_validator_error_code;
    wire k_verified_valid, v_verified_valid;
    wire k_verified_ready, v_verified_ready;
    wire [7:0] k_verified_tokens, v_verified_tokens;
    wire [14:0] k_verified_symbols, v_verified_symbols;
    wire k_verified_raw, v_verified_raw;
    wire k_verified_stream, v_verified_stream;
    wire [15:0] k_verified_payload, v_verified_payload;
    wire [8:0] k_verified_scale_bytes, v_verified_scale_bytes;
    wire [7:0] k_verified_scale_format, v_verified_scale_format;
    wire validator_abort;

    wire k_validator_data_valid = state == ST_VALIDATE &&
        k_validator_started && k_validator_data_word_valid;
    wire v_validator_data_valid = state == ST_VALIDATE &&
        v_validator_started && v_validator_data_word_valid;
    wire k_validator_data_ready, v_validator_data_ready;
    wire k_validator_scale_valid = state == ST_VALIDATE &&
        k_validator_started && k_validator_scale_word_valid;
    wire v_validator_scale_valid = state == ST_VALIDATE &&
        v_validator_started && v_validator_scale_word_valid;
    wire k_validator_scale_ready, v_validator_scale_ready;

    wire [3:0] k_validator_data_keep =
        (k_validator_data_index + 1 == k_required_words) ?
        final_keep(k_window_reg[1:0]) : 4'hf;
    wire [3:0] v_validator_data_keep =
        (v_validator_data_index + 1 == v_required_words) ?
        final_keep(v_window_reg[1:0]) : 4'hf;
    wire [3:0] k_validator_scale_keep =
        (k_validator_scale_index + 1 == scale_required_words) ?
        final_keep(expected_scale_bytes[1:0]) : 4'hf;
    wire [3:0] v_validator_scale_keep =
        (v_validator_scale_index + 1 == scale_required_words) ?
        final_keep(expected_scale_bytes[1:0]) : 4'hf;
    wire [31:0] k_validator_data_word = k_page_read_data;
    wire [31:0] v_validator_data_word = v_page_read_data;
    wire [31:0] k_validator_scale_word = k_scale_read_data;
    wire [31:0] v_validator_scale_word = v_scale_read_data;

    kv_v03_page128_record_validator #(
        .TAG_WIDTH(64), .SCALE_BITS(SCALE_BITS),
        .COMPILED_CODEBOOK_ID(COMPILED_K_CODEBOOK_ID),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES)
    ) u_k_validator (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(state == ST_VALIDATE && !k_validator_started),
        .cmd_ready(k_validator_cmd_ready), .cmd_page_index(page_index_reg),
        .cmd_page_count(page_count_reg),
        .cmd_token_base({1'b0, page_index_reg, 7'b0}),
        .cmd_token_count(context_reg[7:0]),
        .cmd_expected_symbols(expected_symbols),
        .cmd_page_window_bytes({18'd0, k_window_reg}),
        .cmd_scale_slice_bytes(expected_scale_bytes),
        .cmd_stream_is_v(1'b0), .cmd_task_tag(k_tag_reg),
        .abort(validator_abort), .data_valid(k_validator_data_valid),
        .data_ready(k_validator_data_ready),
        .data_data(k_validator_data_word),
        .data_byte_valid(k_validator_data_keep),
        .data_last(k_validator_data_index + 1 == k_required_words),
        .data_byte_offset({k_validator_data_index, 2'b00}),
        .data_task_tag(k_tag_reg), .data_page_index(page_index_reg),
        .data_stream_is_v(1'b0),
        .scale_valid(k_validator_scale_valid),
        .scale_ready(k_validator_scale_ready),
        .scale_data(k_validator_scale_word),
        .scale_byte_valid(k_validator_scale_keep),
        .scale_last(k_validator_scale_index + 1 == scale_required_words),
        .scale_byte_offset({5'd0, k_validator_scale_index, 2'b00}),
        .scale_task_tag(k_tag_reg), .scale_page_index(page_index_reg),
        .scale_stream_is_v(1'b0), .verified_valid(k_verified_valid),
        .verified_ready(k_verified_ready), .verified_task_tag(),
        .verified_page_index(), .verified_page_count(),
        .verified_token_base(), .verified_token_count(k_verified_tokens),
        .verified_expected_symbols(k_verified_symbols),
        .verified_raw_mode(k_verified_raw),
        .verified_stream_is_v(k_verified_stream),
        .verified_payload_bytes(k_verified_payload),
        .verified_scale_format_id(k_verified_scale_format),
        .verified_record_bytes(), .verified_page_window_bytes(),
        .verified_scale_slice_bytes(k_verified_scale_bytes),
        .verified_padding_bytes(), .busy(k_validator_busy),
        .aborted(), .aborted_task_tag(), .aborted_page_index(),
        .aborted_stream_is_v(), .error_valid(k_validator_error),
        .error_code(k_validator_error_code), .error_task_tag(),
        .error_page_index(), .error_stream_is_v()
    );

    kv_v03_page128_record_validator #(
        .TAG_WIDTH(64), .SCALE_BITS(SCALE_BITS),
        .COMPILED_CODEBOOK_ID(COMPILED_V_CODEBOOK_ID),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES)
    ) u_v_validator (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(state == ST_VALIDATE && !v_validator_started),
        .cmd_ready(v_validator_cmd_ready), .cmd_page_index(page_index_reg),
        .cmd_page_count(page_count_reg),
        .cmd_token_base({1'b0, page_index_reg, 7'b0}),
        .cmd_token_count(context_reg[7:0]),
        .cmd_expected_symbols(expected_symbols),
        .cmd_page_window_bytes({18'd0, v_window_reg}),
        .cmd_scale_slice_bytes(expected_scale_bytes),
        .cmd_stream_is_v(1'b1), .cmd_task_tag(v_tag_reg),
        .abort(validator_abort), .data_valid(v_validator_data_valid),
        .data_ready(v_validator_data_ready),
        .data_data(v_validator_data_word),
        .data_byte_valid(v_validator_data_keep),
        .data_last(v_validator_data_index + 1 == v_required_words),
        .data_byte_offset({v_validator_data_index, 2'b00}),
        .data_task_tag(v_tag_reg), .data_page_index(page_index_reg),
        .data_stream_is_v(1'b1),
        .scale_valid(v_validator_scale_valid),
        .scale_ready(v_validator_scale_ready),
        .scale_data(v_validator_scale_word),
        .scale_byte_valid(v_validator_scale_keep),
        .scale_last(v_validator_scale_index + 1 == scale_required_words),
        .scale_byte_offset({5'd0, v_validator_scale_index, 2'b00}),
        .scale_task_tag(v_tag_reg), .scale_page_index(page_index_reg),
        .scale_stream_is_v(1'b1), .verified_valid(v_verified_valid),
        .verified_ready(v_verified_ready), .verified_task_tag(),
        .verified_page_index(), .verified_page_count(),
        .verified_token_base(), .verified_token_count(v_verified_tokens),
        .verified_expected_symbols(v_verified_symbols),
        .verified_raw_mode(v_verified_raw),
        .verified_stream_is_v(v_verified_stream),
        .verified_payload_bytes(v_verified_payload),
        .verified_scale_format_id(v_verified_scale_format),
        .verified_record_bytes(), .verified_page_window_bytes(),
        .verified_scale_slice_bytes(v_verified_scale_bytes),
        .verified_padding_bytes(), .busy(v_validator_busy),
        .aborted(), .aborted_task_tag(), .aborted_page_index(),
        .aborted_stream_is_v(), .error_valid(v_validator_error),
        .error_code(v_validator_error_code), .error_task_tag(),
        .error_page_index(), .error_stream_is_v()
    );

    // Two real four-lane decode banks --------------------------------------
    wire k_lane_page_ready, v_lane_page_ready;
    wire k_lane_publish_valid, v_lane_publish_valid;
    wire k_lane_publish_ready, v_lane_publish_ready;
    wire k_lane_page_active, v_lane_page_active;
    wire [63:0] k_lane_tag, v_lane_tag;
    wire [15:0] k_lane_epoch, v_lane_epoch;
    wire [4:0] k_lane_page, v_lane_page;
    wire k_lane_stream, v_lane_stream, k_lane_raw, v_lane_raw;
    wire [15:0] k_lane_payload, v_lane_payload;
    wire [14:0] k_lane_symbols, v_lane_symbols;
    wire [7:0] k_lane_tokens, v_lane_tokens;
    wire [8:0] k_lane_scale_bytes, v_lane_scale_bytes;
    wire k_lane_busy, v_lane_busy, k_lane_draining, v_lane_draining;
    wire k_lane_sticky, v_lane_sticky;
    wire [7:0] k_lane_error_code, v_lane_error_code;
    wire [7:0] k_lane_error_subcode, v_lane_error_subcode;
    wire k_lane_clear_ready, v_lane_clear_ready;
    wire k_lane_row_abort, v_lane_row_abort;
    wire lane_abort, lane_clear;

    wire validators_pair_valid = k_verified_valid && v_verified_valid;
    wire validators_pair_typed = validators_pair_valid &&
        k_verified_raw == expected_k_raw &&
        v_verified_raw == expected_v_raw && !k_verified_stream &&
        v_verified_stream && k_verified_tokens == context_reg[7:0] &&
        v_verified_tokens == context_reg[7:0] &&
        k_verified_symbols == expected_symbols &&
        v_verified_symbols == expected_symbols &&
        k_verified_scale_bytes == expected_scale_bytes &&
        v_verified_scale_bytes == expected_scale_bytes;
    wire verified_type_fault = state == ST_VALIDATE &&
                               validators_pair_valid &&
                               !validators_pair_typed;
    wire lane_page_fire = state == ST_VALIDATE && validators_pair_typed &&
                          k_lane_page_ready && v_lane_page_ready;
    assign k_verified_ready = lane_page_fire;
    assign v_verified_ready = lane_page_fire;

    wire k_lane_data_rd_en, v_lane_data_rd_en;
    wire [11:0] k_lane_data_rd_addr, v_lane_data_rd_addr;
    reg k_lane_data_rd_valid, v_lane_data_rd_valid;
    wire [31:0] k_lane_data_rd_data = k_page_read_data;
    wire [31:0] v_lane_data_rd_data = v_page_read_data;
    reg [3:0] k_lane_data_rd_keep, v_lane_data_rd_keep;
    reg k_lane_data_rd_last, v_lane_data_rd_last;
    reg [13:0] k_lane_data_rd_offset, v_lane_data_rd_offset;
    wire k_lane_scale_rd_en, v_lane_scale_rd_en;
    wire [6:0] k_lane_scale_rd_addr, v_lane_scale_rd_addr;
    reg k_lane_scale_rd_valid, v_lane_scale_rd_valid;
    wire [31:0] k_lane_scale_rd_data = k_scale_read_data;
    wire [31:0] v_lane_scale_rd_data = v_scale_read_data;
    reg [3:0] k_lane_scale_rd_keep, v_lane_scale_rd_keep;
    reg k_lane_scale_rd_last, v_lane_scale_rd_last;
    reg [8:0] k_lane_scale_rd_offset, v_lane_scale_rd_offset;
    reg k_lane_data_pending, v_lane_data_pending;
    reg [11:0] k_lane_data_pending_addr, v_lane_data_pending_addr;
    reg k_lane_scale_pending, v_lane_scale_pending;
    reg [6:0] k_lane_scale_pending_addr, v_lane_scale_pending_addr;
    reg [15:0] k_payload_latched, v_payload_latched;
    reg [8:0] k_scale_bytes_latched, v_scale_bytes_latched;

    wire k_validator_data_advance = k_validator_data_word_valid &&
        k_validator_data_ready;
    wire v_validator_data_advance = v_validator_data_word_valid &&
        v_validator_data_ready;
    wire k_validator_scale_advance = k_validator_scale_word_valid &&
        k_validator_scale_ready;
    wire v_validator_scale_advance = v_validator_scale_word_valid &&
        v_validator_scale_ready;
    wire k_validator_data_fetch = state == ST_VALIDATE &&
        k_validator_started &&
        ((!k_validator_data_word_valid &&
          k_validator_data_index < k_required_words) ||
         (k_validator_data_advance &&
          k_validator_data_index + 1 < k_required_words));
    wire v_validator_data_fetch = state == ST_VALIDATE &&
        v_validator_started &&
        ((!v_validator_data_word_valid &&
          v_validator_data_index < v_required_words) ||
         (v_validator_data_advance &&
          v_validator_data_index + 1 < v_required_words));
    wire k_validator_scale_fetch = state == ST_VALIDATE &&
        k_validator_started &&
        ((!k_validator_scale_word_valid &&
          k_validator_scale_index < scale_required_words) ||
         (k_validator_scale_advance &&
          k_validator_scale_index + 1 < scale_required_words));
    wire v_validator_scale_fetch = state == ST_VALIDATE &&
        v_validator_started &&
        ((!v_validator_scale_word_valid &&
          v_validator_scale_index < scale_required_words) ||
         (v_validator_scale_advance &&
          v_validator_scale_index + 1 < scale_required_words));
    wire [11:0] k_validator_data_fetch_addr =
        k_validator_data_index + (k_validator_data_advance ? 1'b1 : 1'b0);
    wire [11:0] v_validator_data_fetch_addr =
        v_validator_data_index + (v_validator_data_advance ? 1'b1 : 1'b0);
    wire [6:0] k_validator_scale_fetch_addr =
        k_validator_scale_index + (k_validator_scale_advance ? 1'b1 : 1'b0);
    wire [6:0] v_validator_scale_fetch_addr =
        v_validator_scale_index + (v_validator_scale_advance ? 1'b1 : 1'b0);
    wire k_page_read_en = k_validator_data_fetch ||
        (state != ST_VALIDATE && k_lane_data_pending);
    wire v_page_read_en = v_validator_data_fetch ||
        (state != ST_VALIDATE && v_lane_data_pending);
    wire k_scale_read_en = k_validator_scale_fetch ||
        (state != ST_VALIDATE && k_lane_scale_pending);
    wire v_scale_read_en = v_validator_scale_fetch ||
        (state != ST_VALIDATE && v_lane_scale_pending);
    wire [11:0] k_page_read_addr = k_validator_data_fetch ?
        k_validator_data_fetch_addr : k_lane_data_pending_addr;
    wire [11:0] v_page_read_addr = v_validator_data_fetch ?
        v_validator_data_fetch_addr : v_lane_data_pending_addr;
    wire [6:0] k_scale_read_addr = k_validator_scale_fetch ?
        k_validator_scale_fetch_addr : k_lane_scale_pending_addr;
    wire [6:0] v_scale_read_addr = v_validator_scale_fetch ?
        v_validator_scale_fetch_addr : v_lane_scale_pending_addr;

    wire arith_k_p16_en, arith_v_p16_en;
    wire [9:0] arith_k_p16_addr, arith_v_p16_addr;
    wire k_lane_p16_raw_valid, v_lane_p16_raw_valid;
    wire [79:0] k_lane_p16_raw_codes, v_lane_p16_raw_codes;
    reg k_lane_p16_valid, v_lane_p16_valid;
    reg [79:0] k_lane_p16_codes, v_lane_p16_codes;
    wire arith_k_scale_en, arith_v_scale_en;
    wire [6:0] arith_k_scale_addr, arith_v_scale_addr;
    wire k_lane_token_scale_raw_valid, v_lane_token_scale_raw_valid;
    wire [SCALE_BITS-1:0] k_lane_token_scale_raw,
                          v_lane_token_scale_raw;
    reg k_lane_token_scale_valid, v_lane_token_scale_valid;
    reg [SCALE_BITS-1:0] k_lane_token_scale, v_lane_token_scale;
    wire arith_k_page_release, arith_v_page_release;

    kv_v03_typed_decode_lane_bank_4x1 #(
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_PROFILE_ID(COMPILED_PROFILE_ID),
        .COMPILED_K_CODEBOOK_ID(COMPILED_K_CODEBOOK_ID),
        .COMPILED_V_CODEBOOK_ID(COMPILED_V_CODEBOOK_ID)
    ) u_k_lane_bank (
        .clk(clk), .rst_n(rst_n), .page_valid(lane_page_fire),
        .page_ready(k_lane_page_ready), .page_task_tag(k_tag_reg),
        .page_epoch(epoch_reg), .page_index(page_index_reg),
        .page_stream_is_v(1'b0), .page_expected_stream_is_v(1'b0),
        .page_raw_mode(k_verified_raw),
        .page_payload_bytes(k_verified_payload),
        .page_expected_symbols(k_verified_symbols),
        .page_token_count(k_verified_tokens),
        .page_scale_slice_bytes(k_verified_scale_bytes), .source_release(),
        .data_rd_en(k_lane_data_rd_en),
        .data_rd_word_addr(k_lane_data_rd_addr),
        .data_rd_valid(k_lane_data_rd_valid),
        .data_rd_data(k_lane_data_rd_data),
        .data_rd_byte_valid(k_lane_data_rd_keep),
        .data_rd_last(k_lane_data_rd_last),
        .data_rd_byte_offset(k_lane_data_rd_offset),
        .scale_rd_en(k_lane_scale_rd_en),
        .scale_rd_word_addr(k_lane_scale_rd_addr),
        .scale_rd_valid(k_lane_scale_rd_valid),
        .scale_rd_data(k_lane_scale_rd_data),
        .scale_rd_byte_valid(k_lane_scale_rd_keep),
        .scale_rd_last(k_lane_scale_rd_last),
        .scale_rd_byte_offset(k_lane_scale_rd_offset),
        .abort_valid(lane_abort), .abort_task_tag(k_tag_reg),
        .abort_epoch(epoch_reg), .abort_page_index(page_index_reg),
        .abort_stream_is_v(1'b0), .clear_fault(lane_clear),
        .clear_ready(k_lane_clear_ready),
        .publish_valid(k_lane_publish_valid),
        .publish_ready(k_lane_publish_ready),
        .page_active(k_lane_page_active),
        .page_release(arith_k_page_release),
        .published_task_tag(k_lane_tag),
        .published_epoch(k_lane_epoch),
        .published_page_index(k_lane_page),
        .published_stream_is_v(k_lane_stream),
        .published_raw_mode(k_lane_raw),
        .published_payload_bytes(k_lane_payload),
        .published_expected_symbols(k_lane_symbols),
        .published_token_count(k_lane_tokens),
        .published_scale_slice_bytes(k_lane_scale_bytes),
        .p16_rd_en(arith_k_p16_en), .p16_rd_addr(arith_k_p16_addr),
        .p16_rd_valid(k_lane_p16_raw_valid),
        .p16_rd_codes(k_lane_p16_raw_codes),
        .token_scale_rd_en(arith_k_scale_en),
        .token_scale_rd_addr(arith_k_scale_addr),
        .token_scale_rd_valid(k_lane_token_scale_raw_valid),
        .token_scale_rd_data(k_lane_token_scale_raw),
        .busy(k_lane_busy), .draining(k_lane_draining),
        .lane_occupied(), .lane_decode_busy(), .lane_complete(),
        .sticky_error(k_lane_sticky),
        .sticky_error_code(k_lane_error_code),
        .sticky_error_subcode(k_lane_error_subcode),
        .sticky_task_tag(), .sticky_epoch(), .sticky_page_index(),
        .sticky_stream_is_v(), .row_abort(k_lane_row_abort)
    );

    kv_v03_typed_decode_lane_bank_4x1 #(
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_PROFILE_ID(COMPILED_PROFILE_ID),
        .COMPILED_K_CODEBOOK_ID(COMPILED_K_CODEBOOK_ID),
        .COMPILED_V_CODEBOOK_ID(COMPILED_V_CODEBOOK_ID)
    ) u_v_lane_bank (
        .clk(clk), .rst_n(rst_n), .page_valid(lane_page_fire),
        .page_ready(v_lane_page_ready), .page_task_tag(v_tag_reg),
        .page_epoch(epoch_reg), .page_index(page_index_reg),
        .page_stream_is_v(1'b1), .page_expected_stream_is_v(1'b1),
        .page_raw_mode(v_verified_raw),
        .page_payload_bytes(v_verified_payload),
        .page_expected_symbols(v_verified_symbols),
        .page_token_count(v_verified_tokens),
        .page_scale_slice_bytes(v_verified_scale_bytes), .source_release(),
        .data_rd_en(v_lane_data_rd_en),
        .data_rd_word_addr(v_lane_data_rd_addr),
        .data_rd_valid(v_lane_data_rd_valid),
        .data_rd_data(v_lane_data_rd_data),
        .data_rd_byte_valid(v_lane_data_rd_keep),
        .data_rd_last(v_lane_data_rd_last),
        .data_rd_byte_offset(v_lane_data_rd_offset),
        .scale_rd_en(v_lane_scale_rd_en),
        .scale_rd_word_addr(v_lane_scale_rd_addr),
        .scale_rd_valid(v_lane_scale_rd_valid),
        .scale_rd_data(v_lane_scale_rd_data),
        .scale_rd_byte_valid(v_lane_scale_rd_keep),
        .scale_rd_last(v_lane_scale_rd_last),
        .scale_rd_byte_offset(v_lane_scale_rd_offset),
        .abort_valid(lane_abort), .abort_task_tag(v_tag_reg),
        .abort_epoch(epoch_reg), .abort_page_index(page_index_reg),
        .abort_stream_is_v(1'b1), .clear_fault(lane_clear),
        .clear_ready(v_lane_clear_ready),
        .publish_valid(v_lane_publish_valid),
        .publish_ready(v_lane_publish_ready),
        .page_active(v_lane_page_active),
        .page_release(arith_v_page_release),
        .published_task_tag(v_lane_tag),
        .published_epoch(v_lane_epoch),
        .published_page_index(v_lane_page),
        .published_stream_is_v(v_lane_stream),
        .published_raw_mode(v_lane_raw),
        .published_payload_bytes(v_lane_payload),
        .published_expected_symbols(v_lane_symbols),
        .published_token_count(v_lane_tokens),
        .published_scale_slice_bytes(v_lane_scale_bytes),
        .p16_rd_en(arith_v_p16_en), .p16_rd_addr(arith_v_p16_addr),
        .p16_rd_valid(v_lane_p16_raw_valid),
        .p16_rd_codes(v_lane_p16_raw_codes),
        .token_scale_rd_en(arith_v_scale_en),
        .token_scale_rd_addr(arith_v_scale_addr),
        .token_scale_rd_valid(v_lane_token_scale_raw_valid),
        .token_scale_rd_data(v_lane_token_scale_raw),
        .busy(v_lane_busy), .draining(v_lane_draining),
        .lane_occupied(), .lane_decode_busy(), .lane_complete(),
        .sticky_error(v_lane_sticky),
        .sticky_error_code(v_lane_error_code),
        .sticky_error_subcode(v_lane_error_subcode),
        .sticky_task_tag(), .sticky_epoch(), .sticky_page_index(),
        .sticky_stream_is_v(), .row_abort(v_lane_row_abort)
    );

    assign k_lane_publish_ready = state == ST_DECODE &&
        k_lane_publish_valid && v_lane_publish_valid;
    assign v_lane_publish_ready = k_lane_publish_ready;

    // Arithmetic core ------------------------------------------------------
    reg [9:0] q_load_index;
    wire arith_start_ready, arith_clear_ready, arith_busy, arith_draining;
    wire arith_done, arith_aborted, arith_sticky, arith_row_abort;
    wire [7:0] arith_error_code, arith_error_subcode;
    wire arith_score_valid;
    wire [1:0] arith_score_row;
    wire [11:0] arith_score_index;
    wire signed [15:0] arith_score_data;
    wire arith_score_saturated;
    wire arith_result_valid;
    wire [1:0] arith_result_head;
    wire [6:0] arith_result_dimension;
    wire signed [47:0] arith_result_numerator;
    wire signed [17:0] arith_result_normalized;
    wire arith_result_saturated;
    wire [111:0] arith_denominators;
    wire [51:0] arith_reciprocals;
    wire [19:0] arith_reciprocal_exponents;
    wire [4:0] arith_progress_state;
    wire [6:0] arith_progress_token;
    wire [1:0] arith_progress_head;
    wire [2:0] arith_progress_group;
    wire [31:0] arith_perf_cycles;
    wire [31:0] arith_k_p16_requests, arith_v_p16_requests;
    wire [31:0] arith_k_scale_requests, arith_v_scale_requests;
    wire [31:0] arith_k_starvation, arith_v_starvation;
    wire [31:0] arith_k_starvation_high, arith_v_starvation_high;
    wire [31:0] arith_score_count, arith_result_count;
    reg arith_clear_counters_reg;
    wire arith_abort;
    wire arith_clear;
    wire [31:0] q_load_word = q_mem[q_load_index[8:2]];
    reg signed [7:0] q_load_byte;
    always @* begin
        case (q_load_index[1:0])
            2'd0: q_load_byte = q_load_word[7:0];
            2'd1: q_load_byte = q_load_word[15:8];
            2'd2: q_load_byte = q_load_word[23:16];
            default: q_load_byte = q_load_word[31:24];
        endcase
    end

    kv_v03_canned_page_arithmetic #(
        .SCALE_BITS(SCALE_BITS), .MAX_CONTEXT(MAX_CONTEXT),
        .QK_MULT_STYLE(QK_MULT_STYLE), .AV_MULT_STYLE(AV_MULT_STYLE)
    ) u_arithmetic (
        .clk(clk), .rst_n(rst_n),
        .start_valid(state == ST_ARITH_START),
        .start_ready(arith_start_ready), .context_len(context_reg),
        .abort(arith_abort), .clear_fault(arith_clear),
        .clear_ready(arith_clear_ready),
        .clear_counters(arith_clear_counters_reg),
        .q_wr_en(state == ST_Q_LOAD), .q_wr_row(q_load_index[8:7]),
        .q_wr_addr(q_load_index[6:0]), .q_wr_data(q_load_byte),
        .queries_ready(), .k_page_active(k_lane_page_active),
        .k_task_tag(k_lane_tag), .k_epoch(k_lane_epoch),
        .k_page_index(k_lane_page), .k_stream_is_v(k_lane_stream),
        .k_raw_mode(k_lane_raw), .k_expected_symbols(k_lane_symbols),
        .k_token_count(k_lane_tokens),
        .k_scale_slice_bytes(k_lane_scale_bytes),
        .k_p16_rd_en(arith_k_p16_en), .k_p16_rd_addr(arith_k_p16_addr),
        .k_p16_rd_valid(k_lane_p16_valid),
        .k_p16_rd_codes(k_lane_p16_codes),
        .k_scale_rd_en(arith_k_scale_en),
        .k_scale_rd_addr(arith_k_scale_addr),
        .k_scale_rd_valid(k_lane_token_scale_valid),
        .k_scale_rd_data(k_lane_token_scale),
        .k_page_release(arith_k_page_release),
        .v_page_active(v_lane_page_active), .v_task_tag(v_lane_tag),
        .v_epoch(v_lane_epoch), .v_page_index(v_lane_page),
        .v_stream_is_v(v_lane_stream), .v_raw_mode(v_lane_raw),
        .v_expected_symbols(v_lane_symbols), .v_token_count(v_lane_tokens),
        .v_scale_slice_bytes(v_lane_scale_bytes),
        .v_p16_rd_en(arith_v_p16_en), .v_p16_rd_addr(arith_v_p16_addr),
        .v_p16_rd_valid(v_lane_p16_valid),
        .v_p16_rd_codes(v_lane_p16_codes),
        .v_scale_rd_en(arith_v_scale_en),
        .v_scale_rd_addr(arith_v_scale_addr),
        .v_scale_rd_valid(v_lane_token_scale_valid),
        .v_scale_rd_data(v_lane_token_scale),
        .v_page_release(arith_v_page_release),
        .score_valid(arith_score_valid),
        .score_ready(state == ST_ARITH_RUN), .score_row(arith_score_row),
        .score_index(arith_score_index), .score_data(arith_score_data),
        .score_saturated(arith_score_saturated),
        .result_valid(arith_result_valid),
        .result_ready(state == ST_ARITH_RUN),
        .result_head(arith_result_head),
        .result_dimension(arith_result_dimension),
        .result_numerator(arith_result_numerator),
        .result_normalized(arith_result_normalized),
        .result_saturated(arith_result_saturated), .result_last(),
        .result_k_task_tag(), .result_v_task_tag(), .result_epoch(),
        .result_page_index(), .result_k_raw_mode(), .result_v_raw_mode(),
        .denominators(arith_denominators),
        .reciprocal_codes(arith_reciprocals),
        .reciprocal_exponents(arith_reciprocal_exponents),
        .busy(arith_busy), .draining(arith_draining), .done(arith_done),
        .aborted(arith_aborted), .sticky_error(arith_sticky),
        .sticky_error_code(arith_error_code),
        .sticky_error_subcode(arith_error_subcode),
        .sticky_k_task_tag(), .sticky_v_task_tag(), .sticky_epoch(),
        .sticky_page_index(), .row_abort(arith_row_abort),
        .progress_state(arith_progress_state),
        .progress_token(arith_progress_token),
        .progress_head(arith_progress_head),
        .progress_group(arith_progress_group),
        .perf_cycles(arith_perf_cycles),
        .k_p16_read_requests(arith_k_p16_requests),
        .k_scale_read_requests(arith_k_scale_requests),
        .v_p16_read_requests(arith_v_p16_requests),
        .v_scale_read_requests(arith_v_scale_requests),
        .k_read_starvation_cycles(arith_k_starvation),
        .v_read_starvation_cycles(arith_v_starvation),
        .k_starvation_high_water(arith_k_starvation_high),
        .v_starvation_high_water(arith_v_starvation_high),
        .read_outstanding_high_water(), .arithmetic_active_cycles(),
        .score_stall_cycles(), .result_stall_cycles(),
        .score_count(arith_score_count), .result_count(arith_result_count)
    );

    wire busy_write_fault = write_commit && !ctrl_write && top_busy;
    wire busy_start_fault = ctrl_start && state != ST_IDLE;
    wire child_fault = k_validator_error || v_validator_error ||
                       k_lane_sticky || v_lane_sticky || arith_sticky ||
                       verified_type_fault;
    wire fault_entry = state != ST_DRAIN && state != ST_FAULT &&
        ((ctrl_abort && state != ST_IDLE) || busy_write_fault ||
         busy_start_fault || child_fault);
    reg abort_children;
    assign validator_abort = abort_children;
    assign lane_abort = abort_children;
    assign arith_abort = abort_children;

    wire k_lane_fault_quiet = k_lane_sticky ? k_lane_clear_ready : !k_lane_busy;
    wire v_lane_fault_quiet = v_lane_sticky ? v_lane_clear_ready : !v_lane_busy;
    wire arith_fault_quiet = arith_sticky ? arith_clear_ready :
                             (!arith_busy && !arith_draining);
    wire children_clearable = !k_validator_busy && !v_validator_busy &&
        k_lane_fault_quiet && v_lane_fault_quiet && arith_fault_quiet &&
        !k_lane_data_pending && !v_lane_data_pending &&
        !k_lane_scale_pending && !v_lane_scale_pending;
    wire top_clear_ready = state == ST_FAULT && children_clearable;
    assign lane_clear = ctrl_clear && top_clear_ready;
    assign arith_clear = ctrl_clear && top_clear_ready;

    // The validators and lane banks use the same four synchronous memory
    // read ports in successive top-level states. Keeping every large-memory
    // read synchronous lets Vivado infer RAMB resources instead of LUTRAM.
    // Lane responses are still serviced during abort so accepted copy
    // obligations always drain.
    always @(posedge clk) begin
        if (!rst_n) begin
            k_lane_data_rd_valid <= 1'b0;
            v_lane_data_rd_valid <= 1'b0;
            k_lane_scale_rd_valid <= 1'b0;
            v_lane_scale_rd_valid <= 1'b0;
            k_lane_p16_valid <= 1'b0;
            v_lane_p16_valid <= 1'b0;
            k_lane_token_scale_valid <= 1'b0;
            v_lane_token_scale_valid <= 1'b0;
            k_lane_data_pending <= 1'b0;
            v_lane_data_pending <= 1'b0;
            k_lane_scale_pending <= 1'b0;
            v_lane_scale_pending <= 1'b0;
            k_validator_data_word_valid <= 1'b0;
            v_validator_data_word_valid <= 1'b0;
            k_validator_scale_word_valid <= 1'b0;
            v_validator_scale_word_valid <= 1'b0;
            k_page_read_data <= 32'd0;
            v_page_read_data <= 32'd0;
            k_scale_read_data <= 32'd0;
            v_scale_read_data <= 32'd0;
        end else begin
            k_lane_data_rd_valid <= 1'b0;
            v_lane_data_rd_valid <= 1'b0;
            k_lane_scale_rd_valid <= 1'b0;
            v_lane_scale_rd_valid <= 1'b0;
            k_lane_p16_valid <= k_lane_p16_raw_valid;
            v_lane_p16_valid <= v_lane_p16_raw_valid;
            k_lane_token_scale_valid <= k_lane_token_scale_raw_valid;
            v_lane_token_scale_valid <= v_lane_token_scale_raw_valid;
            if (k_lane_p16_raw_valid)
                k_lane_p16_codes <= k_lane_p16_raw_codes;
            if (v_lane_p16_raw_valid)
                v_lane_p16_codes <= v_lane_p16_raw_codes;
            if (k_lane_token_scale_raw_valid)
                k_lane_token_scale <= k_lane_token_scale_raw;
            if (v_lane_token_scale_raw_valid)
                v_lane_token_scale <= v_lane_token_scale_raw;
            if (k_page_read_en)
                k_page_read_data <= k_page_mem[k_page_read_addr];
            if (v_page_read_en)
                v_page_read_data <= v_page_mem[v_page_read_addr];
            if (k_scale_read_en)
                k_scale_read_data <= k_scale_mem[k_scale_read_addr];
            if (v_scale_read_en)
                v_scale_read_data <= v_scale_mem[v_scale_read_addr];
            if (state == ST_VALIDATE) begin
                if (!k_validator_started) begin
                    k_validator_data_word_valid <= 1'b0;
                    k_validator_scale_word_valid <= 1'b0;
                end else begin
                    if (k_validator_data_word_valid &&
                        k_validator_data_ready) begin
                        if (k_validator_data_index + 1 < k_required_words) begin
                            k_validator_data_word_valid <= 1'b1;
                        end else begin
                            k_validator_data_word_valid <= 1'b0;
                        end
                    end else if (!k_validator_data_word_valid &&
                                 k_validator_data_index < k_required_words) begin
                        k_validator_data_word_valid <= 1'b1;
                    end
                    if (k_validator_scale_word_valid &&
                        k_validator_scale_ready) begin
                        if (k_validator_scale_index + 1 <
                            scale_required_words) begin
                            k_validator_scale_word_valid <= 1'b1;
                        end else begin
                            k_validator_scale_word_valid <= 1'b0;
                        end
                    end else if (!k_validator_scale_word_valid &&
                                 k_validator_scale_index <
                                 scale_required_words) begin
                        k_validator_scale_word_valid <= 1'b1;
                    end
                end
                if (!v_validator_started) begin
                    v_validator_data_word_valid <= 1'b0;
                    v_validator_scale_word_valid <= 1'b0;
                end else begin
                    if (v_validator_data_word_valid &&
                        v_validator_data_ready) begin
                        if (v_validator_data_index + 1 < v_required_words) begin
                            v_validator_data_word_valid <= 1'b1;
                        end else begin
                            v_validator_data_word_valid <= 1'b0;
                        end
                    end else if (!v_validator_data_word_valid &&
                                 v_validator_data_index < v_required_words) begin
                        v_validator_data_word_valid <= 1'b1;
                    end
                    if (v_validator_scale_word_valid &&
                        v_validator_scale_ready) begin
                        if (v_validator_scale_index + 1 <
                            scale_required_words) begin
                            v_validator_scale_word_valid <= 1'b1;
                        end else begin
                            v_validator_scale_word_valid <= 1'b0;
                        end
                    end else if (!v_validator_scale_word_valid &&
                                 v_validator_scale_index <
                                 scale_required_words) begin
                        v_validator_scale_word_valid <= 1'b1;
                    end
                end
            end else begin
                k_validator_data_word_valid <= 1'b0;
                v_validator_data_word_valid <= 1'b0;
                k_validator_scale_word_valid <= 1'b0;
                v_validator_scale_word_valid <= 1'b0;
            end
            if (state != ST_VALIDATE && k_lane_data_pending) begin
                k_lane_data_rd_valid <= 1'b1;
                k_lane_data_rd_keep <=
                    (k_lane_data_pending_addr - 2 ==
                     ((k_payload_latched + 3) >> 2)) ?
                    final_keep(k_payload_latched[1:0]) : 4'hf;
                k_lane_data_rd_last <=
                    (k_lane_data_pending_addr - 2 ==
                     ((k_payload_latched + 3) >> 2));
                k_lane_data_rd_offset <=
                    {k_lane_data_pending_addr, 2'b00};
                k_lane_data_pending <= 1'b0;
            end
            if (state != ST_VALIDATE && v_lane_data_pending) begin
                v_lane_data_rd_valid <= 1'b1;
                v_lane_data_rd_keep <=
                    (v_lane_data_pending_addr - 2 ==
                     ((v_payload_latched + 3) >> 2)) ?
                    final_keep(v_payload_latched[1:0]) : 4'hf;
                v_lane_data_rd_last <=
                    (v_lane_data_pending_addr - 2 ==
                     ((v_payload_latched + 3) >> 2));
                v_lane_data_rd_offset <=
                    {v_lane_data_pending_addr, 2'b00};
                v_lane_data_pending <= 1'b0;
            end
            if (state != ST_VALIDATE && k_lane_scale_pending) begin
                k_lane_scale_rd_valid <= 1'b1;
                k_lane_scale_rd_keep <=
                    (k_lane_scale_pending_addr + 1 ==
                     ((k_scale_bytes_latched + 3) >> 2)) ?
                    final_keep(k_scale_bytes_latched[1:0]) : 4'hf;
                k_lane_scale_rd_last <=
                    (k_lane_scale_pending_addr + 1 ==
                     ((k_scale_bytes_latched + 3) >> 2));
                k_lane_scale_rd_offset <=
                    {k_lane_scale_pending_addr, 2'b00};
                k_lane_scale_pending <= 1'b0;
            end
            if (state != ST_VALIDATE && v_lane_scale_pending) begin
                v_lane_scale_rd_valid <= 1'b1;
                v_lane_scale_rd_keep <=
                    (v_lane_scale_pending_addr + 1 ==
                     ((v_scale_bytes_latched + 3) >> 2)) ?
                    final_keep(v_scale_bytes_latched[1:0]) : 4'hf;
                v_lane_scale_rd_last <=
                    (v_lane_scale_pending_addr + 1 ==
                     ((v_scale_bytes_latched + 3) >> 2));
                v_lane_scale_rd_offset <=
                    {v_lane_scale_pending_addr, 2'b00};
                v_lane_scale_pending <= 1'b0;
            end
            if (k_lane_data_rd_en) begin
                k_lane_data_pending <= 1'b1;
                k_lane_data_pending_addr <= k_lane_data_rd_addr;
            end
            if (v_lane_data_rd_en) begin
                v_lane_data_pending <= 1'b1;
                v_lane_data_pending_addr <= v_lane_data_rd_addr;
            end
            if (k_lane_scale_rd_en) begin
                k_lane_scale_pending <= 1'b1;
                k_lane_scale_pending_addr <= k_lane_scale_rd_addr;
            end
            if (v_lane_scale_rd_en) begin
                v_lane_scale_pending <= 1'b1;
                v_lane_scale_pending_addr <= v_lane_scale_rd_addr;
            end
        end
    end

    integer write_slot;
    integer write_byte;
    integer result_read_index;
    integer result_read_lane;
    integer reset_index;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold <= 1'b0;
            w_hold <= 1'b0;
            awaddr_hold <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold <= 32'd0;
            wstrb_hold <= 4'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= 32'd0;
            state <= ST_IDLE;
            context_reg <= 13'd128;
            page_index_reg <= 5'd0;
            page_count_reg <= 6'd1;
            epoch_reg <= 16'd0;
            k_tag_reg <= 64'd0;
            v_tag_reg <= 64'd0;
            k_window_reg <= 14'd0;
            v_window_reg <= 14'd0;
            expected_k_raw <= 1'b0;
            expected_v_raw <= 1'b0;
            q_word_valid <= 128'd0;
            k_page_word_valid <= {PAGE_WORDS{1'b0}};
            v_page_word_valid <= {PAGE_WORDS{1'b0}};
            k_scale_word_valid <= {SCALE_WORDS{1'b0}};
            v_scale_word_valid <= {SCALE_WORDS{1'b0}};
            k_page_valid_count <= 12'd0;
            v_page_valid_count <= 12'd0;
            k_scale_valid_count <= 7'd0;
            v_scale_valid_count <= 7'd0;
            stored_score_count <= 10'd0;
            stored_result_count <= 10'd0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            aborted_sticky <= 1'b0;
            result_valid_sticky <= 1'b0;
            error_code_reg <= 8'd0;
            error_subcode_reg <= 8'd0;
            error_source_reg <= SRC_NONE;
            error_k_tag_reg <= 64'd0;
            error_v_tag_reg <= 64'd0;
            error_epoch_reg <= 16'd0;
            error_page_reg <= 5'd0;
            wrapper_cycles <= 32'd0;
            k_validator_data_requests <= 32'd0;
            v_validator_data_requests <= 32'd0;
            k_validator_scale_requests <= 32'd0;
            v_validator_scale_requests <= 32'd0;
            k_copy_data_requests <= 32'd0;
            v_copy_data_requests <= 32'd0;
            k_copy_scale_requests <= 32'd0;
            v_copy_scale_requests <= 32'd0;
            row_abort_count <= 32'd0;
            raw_page_count <= 32'd0;
            decoder_fault_count <= 32'd0;
            k_validator_started <= 1'b0;
            v_validator_started <= 1'b0;
            k_validator_data_index <= 12'd0;
            v_validator_data_index <= 12'd0;
            k_validator_scale_index <= 7'd0;
            v_validator_scale_index <= 7'd0;
            k_payload_latched <= 16'd0;
            v_payload_latched <= 16'd0;
            k_scale_bytes_latched <= 9'd0;
            v_scale_bytes_latched <= 9'd0;
            q_load_index <= 10'd0;
            abort_children <= 1'b0;
            arith_clear_counters_reg <= 1'b0;
        end else begin
            abort_children <= 1'b0;
            arith_clear_counters_reg <= 1'b0;

            if (top_busy)
                wrapper_cycles <= wrapper_cycles + 1'b1;
            if (k_validator_data_valid && k_validator_data_ready)
                k_validator_data_requests <=
                    k_validator_data_requests + 1'b1;
            if (v_validator_data_valid && v_validator_data_ready)
                v_validator_data_requests <=
                    v_validator_data_requests + 1'b1;
            if (k_validator_scale_valid && k_validator_scale_ready)
                k_validator_scale_requests <=
                    k_validator_scale_requests + 1'b1;
            if (v_validator_scale_valid && v_validator_scale_ready)
                v_validator_scale_requests <=
                    v_validator_scale_requests + 1'b1;
            if (k_lane_data_rd_en)
                k_copy_data_requests <= k_copy_data_requests + 1'b1;
            if (v_lane_data_rd_en)
                v_copy_data_requests <= v_copy_data_requests + 1'b1;
            if (k_lane_scale_rd_en)
                k_copy_scale_requests <= k_copy_scale_requests + 1'b1;
            if (v_lane_scale_rd_en)
                v_copy_scale_requests <= v_copy_scale_requests + 1'b1;
            if (k_lane_row_abort || v_lane_row_abort || arith_row_abort)
                row_abort_count <= row_abort_count + 1'b1;

            if (arith_score_valid && state == ST_ARITH_RUN) begin
                score_mem[{arith_score_index[6:0], arith_score_row}] <=
                    {arith_score_saturated, arith_score_data};
                stored_score_count <= stored_score_count + 1'b1;
            end
            if (arith_result_valid && state == ST_ARITH_RUN) begin
                result_mem[{arith_result_head, arith_result_dimension}] <= {
                    arith_result_saturated, arith_result_normalized,
                    arith_result_numerator};
                stored_result_count <= stored_result_count + 1'b1;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
            if (write_commit) begin
                aw_hold <= 1'b0;
                w_hold <= 1'b0;
                s_axi_bvalid <= 1'b1;

                if (!top_busy) begin
                    case (awaddr_hold[15:0])
                        REG_CONTEXT:
                            context_reg <= wdata_hold[12:0];
                        REG_PAGE_DESC: begin
                            page_index_reg <= wdata_hold[4:0];
                            page_count_reg <= wdata_hold[13:8];
                        end
                        REG_EPOCH:
                            epoch_reg <= wdata_hold[15:0];
                        REG_K_TAG_LO:
                            k_tag_reg[31:0] <= merge_wstrb(
                                k_tag_reg[31:0], wdata_hold, wstrb_hold);
                        REG_K_TAG_HI:
                            k_tag_reg[63:32] <= merge_wstrb(
                                k_tag_reg[63:32], wdata_hold, wstrb_hold);
                        REG_V_TAG_LO:
                            v_tag_reg[31:0] <= merge_wstrb(
                                v_tag_reg[31:0], wdata_hold, wstrb_hold);
                        REG_V_TAG_HI:
                            v_tag_reg[63:32] <= merge_wstrb(
                                v_tag_reg[63:32], wdata_hold, wstrb_hold);
                        REG_K_WINDOW:
                            k_window_reg <= wdata_hold[13:0];
                        REG_V_WINDOW:
                            v_window_reg <= wdata_hold[13:0];
                        REG_PAGE_MODES: begin
                            expected_k_raw <= wdata_hold[0];
                            expected_v_raw <= wdata_hold[1];
                        end
                        default: begin end
                    endcase

                    if (awaddr_hold[15:0] >= Q_BASE &&
                        awaddr_hold[15:0] < Q_BASE + 16'h0200) begin
                        write_slot = (awaddr_hold[15:0] - Q_BASE) >> 2;
                        for (write_byte = 0; write_byte < 4;
                             write_byte = write_byte + 1)
                            if (wstrb_hold[write_byte])
                                q_mem[write_slot][write_byte*8 +: 8] <=
                                    wdata_hold[write_byte*8 +: 8];
                        if (wstrb_hold == 4'hf)
                            q_word_valid[write_slot] <= 1'b1;
                    end else if (awaddr_hold[15:0] >= K_PAGE_BASE &&
                        awaddr_hold[15:0] < K_PAGE_BASE + MAX_PAGE_BYTES) begin
                        write_slot = (awaddr_hold[15:0] - K_PAGE_BASE) >> 2;
                        for (write_byte = 0; write_byte < 4;
                             write_byte = write_byte + 1)
                            if (wstrb_hold[write_byte])
                                k_page_mem[write_slot][write_byte*8 +: 8] <=
                                    wdata_hold[write_byte*8 +: 8];
                        if (wstrb_hold == 4'hf) begin
                            k_page_word_valid[write_slot] <= 1'b1;
                            if (!k_page_word_valid[write_slot])
                                k_page_valid_count <=
                                    k_page_valid_count + 1'b1;
                        end
                    end else if (awaddr_hold[15:0] >= V_PAGE_BASE &&
                        awaddr_hold[15:0] < V_PAGE_BASE + MAX_PAGE_BYTES) begin
                        write_slot = (awaddr_hold[15:0] - V_PAGE_BASE) >> 2;
                        for (write_byte = 0; write_byte < 4;
                             write_byte = write_byte + 1)
                            if (wstrb_hold[write_byte])
                                v_page_mem[write_slot][write_byte*8 +: 8] <=
                                    wdata_hold[write_byte*8 +: 8];
                        if (wstrb_hold == 4'hf) begin
                            v_page_word_valid[write_slot] <= 1'b1;
                            if (!v_page_word_valid[write_slot])
                                v_page_valid_count <=
                                    v_page_valid_count + 1'b1;
                        end
                    end else if (awaddr_hold[15:0] >= K_SCALE_BASE &&
                        awaddr_hold[15:0] < K_SCALE_BASE + 16'h0100) begin
                        write_slot = (awaddr_hold[15:0] - K_SCALE_BASE) >> 2;
                        for (write_byte = 0; write_byte < 4;
                             write_byte = write_byte + 1)
                            if (wstrb_hold[write_byte])
                                k_scale_mem[write_slot][write_byte*8 +: 8] <=
                                    wdata_hold[write_byte*8 +: 8];
                        if (wstrb_hold == 4'hf) begin
                            k_scale_word_valid[write_slot] <= 1'b1;
                            if (!k_scale_word_valid[write_slot])
                                k_scale_valid_count <=
                                    k_scale_valid_count + 1'b1;
                        end
                    end else if (awaddr_hold[15:0] >= V_SCALE_BASE &&
                        awaddr_hold[15:0] < V_SCALE_BASE + 16'h0100) begin
                        write_slot = (awaddr_hold[15:0] - V_SCALE_BASE) >> 2;
                        for (write_byte = 0; write_byte < 4;
                             write_byte = write_byte + 1)
                            if (wstrb_hold[write_byte])
                                v_scale_mem[write_slot][write_byte*8 +: 8] <=
                                    wdata_hold[write_byte*8 +: 8];
                        if (wstrb_hold == 4'hf) begin
                            v_scale_word_valid[write_slot] <= 1'b1;
                            if (!v_scale_word_valid[write_slot])
                                v_scale_valid_count <=
                                    v_scale_valid_count + 1'b1;
                        end
                    end
                end

                if (ctrl_clear_counters && state == ST_IDLE) begin
                    wrapper_cycles <= 32'd0;
                    k_validator_data_requests <= 32'd0;
                    v_validator_data_requests <= 32'd0;
                    k_validator_scale_requests <= 32'd0;
                    v_validator_scale_requests <= 32'd0;
                    k_copy_data_requests <= 32'd0;
                    v_copy_data_requests <= 32'd0;
                    k_copy_scale_requests <= 32'd0;
                    v_copy_scale_requests <= 32'd0;
                    row_abort_count <= 32'd0;
                    raw_page_count <= 32'd0;
                    decoder_fault_count <= 32'd0;
                    arith_clear_counters_reg <= 1'b1;
                end
                if (ctrl_clear && state == ST_IDLE) begin
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                    aborted_sticky <= 1'b0;
                    result_valid_sticky <= 1'b0;
                    error_code_reg <= 8'd0;
                    error_subcode_reg <= 8'd0;
                    error_source_reg <= SRC_NONE;
                end else if (ctrl_clear && top_clear_ready) begin
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                    aborted_sticky <= 1'b0;
                    result_valid_sticky <= 1'b0;
                    error_code_reg <= 8'd0;
                    error_subcode_reg <= 8'd0;
                    error_source_reg <= SRC_NONE;
                    state <= ST_IDLE;
                end

                if (ctrl_start && state == ST_IDLE) begin
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                    aborted_sticky <= 1'b0;
                    result_valid_sticky <= 1'b0;
                    stored_score_count <= 10'd0;
                    stored_result_count <= 10'd0;
                    if (!storage_ready || k_lane_busy || v_lane_busy ||
                        arith_busy || k_validator_busy || v_validator_busy) begin
                        error_sticky <= 1'b1;
                        error_code_reg <= ERR_CONFIG;
                        error_subcode_reg <= 8'h01;
                        error_source_reg <= SRC_HOST;
                        error_k_tag_reg <= k_tag_reg;
                        error_v_tag_reg <= v_tag_reg;
                        error_epoch_reg <= epoch_reg;
                        error_page_reg <= page_index_reg;
                        abort_children <= 1'b1;
                        state <= ST_DRAIN;
                    end else begin
                        q_load_index <= 10'd0;
                        arith_clear_counters_reg <= 1'b1;
                        state <= ST_Q_LOAD;
                    end
                end
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= 32'd0;
                case (s_axi_araddr[15:0])
                    REG_CTRL: s_axi_rdata <= 32'd0;
                    REG_STATUS: s_axi_rdata <= {
                        16'd0, top_clear_ready, v_lane_sticky, k_lane_sticky,
                        arith_sticky, 3'd0, result_valid_sticky,
                        aborted_sticky, error_sticky, done_sticky,
                        top_draining, top_busy};
                    REG_CONTEXT: s_axi_rdata <= {19'd0, context_reg};
                    REG_PAGE_DESC: s_axi_rdata <=
                        {18'd0, page_count_reg, 3'd0, page_index_reg};
                    REG_EPOCH: s_axi_rdata <= {16'd0, epoch_reg};
                    REG_K_TAG_LO: s_axi_rdata <= k_tag_reg[31:0];
                    REG_K_TAG_HI: s_axi_rdata <= k_tag_reg[63:32];
                    REG_V_TAG_LO: s_axi_rdata <= v_tag_reg[31:0];
                    REG_V_TAG_HI: s_axi_rdata <= v_tag_reg[63:32];
                    REG_K_WINDOW: s_axi_rdata <= {18'd0, k_window_reg};
                    REG_V_WINDOW: s_axi_rdata <= {18'd0, v_window_reg};
                    REG_PAGE_MODES: s_axi_rdata <=
                        {30'd0, expected_v_raw, expected_k_raw};
                    REG_ERROR: s_axi_rdata <= {
                        8'd0, error_page_reg, error_source_reg,
                        error_subcode_reg, error_code_reg};
                    REG_ERROR_SUBCODE: s_axi_rdata <=
                        {11'd0, error_epoch_reg, error_page_reg};
                    REG_ID: s_axi_rdata <= CORE_ID;
                    REG_GEOMETRY: s_axi_rdata <=
                        {8'd4, 8'd128, 8'd128, 8'd16};
                    REG_SCALE_FORMAT: s_axi_rdata <=
                        {8'd0, SCALE_BITS[7:0], 8'd8,
                         (SCALE_BITS == 12) ? 8'd1 : 8'd2};
                    REG_PROGRESS: s_axi_rdata <=
                        {4'd0, state, arith_progress_state,
                         arith_progress_head, arith_progress_group,
                         arith_progress_token, 7'd0};
                    REG_WRAPPER_CYCLES: s_axi_rdata <= wrapper_cycles;
                    REG_K_VALID_DATA_REQ:
                        s_axi_rdata <= k_validator_data_requests;
                    REG_V_VALID_DATA_REQ:
                        s_axi_rdata <= v_validator_data_requests;
                    REG_K_VALID_SCALE_REQ:
                        s_axi_rdata <= k_validator_scale_requests;
                    REG_V_VALID_SCALE_REQ:
                        s_axi_rdata <= v_validator_scale_requests;
                    REG_K_COPY_DATA_REQ:
                        s_axi_rdata <= k_copy_data_requests;
                    REG_V_COPY_DATA_REQ:
                        s_axi_rdata <= v_copy_data_requests;
                    REG_K_COPY_SCALE_REQ:
                        s_axi_rdata <= k_copy_scale_requests;
                    REG_V_COPY_SCALE_REQ:
                        s_axi_rdata <= v_copy_scale_requests;
                    REG_K_P16_REQ: s_axi_rdata <= arith_k_p16_requests;
                    REG_V_P16_REQ: s_axi_rdata <= arith_v_p16_requests;
                    REG_K_SCALE_REQ: s_axi_rdata <= arith_k_scale_requests;
                    REG_V_SCALE_REQ: s_axi_rdata <= arith_v_scale_requests;
                    REG_K_STARVE: s_axi_rdata <= arith_k_starvation;
                    REG_V_STARVE: s_axi_rdata <= arith_v_starvation;
                    REG_K_STARVE_HIGH:
                        s_axi_rdata <= arith_k_starvation_high;
                    REG_V_STARVE_HIGH:
                        s_axi_rdata <= arith_v_starvation_high;
                    REG_SCORE_COUNT: s_axi_rdata <= arith_score_count;
                    REG_RESULT_COUNT: s_axi_rdata <= arith_result_count;
                    REG_ROW_ABORT_COUNT: s_axi_rdata <= row_abort_count;
                    REG_RAW_PAGE_COUNT: s_axi_rdata <= raw_page_count;
                    REG_DECODER_FAULTS: s_axi_rdata <= decoder_fault_count;
                    REG_ERROR_K_TAG_LO: s_axi_rdata <= error_k_tag_reg[31:0];
                    REG_ERROR_K_TAG_HI: s_axi_rdata <= error_k_tag_reg[63:32];
                    REG_ERROR_V_TAG_LO: s_axi_rdata <= error_v_tag_reg[31:0];
                    REG_ERROR_V_TAG_HI: s_axi_rdata <= error_v_tag_reg[63:32];
                    REG_ERROR_EPOCH_PAGE: s_axi_rdata <=
                        {11'd0, error_epoch_reg, error_page_reg};
                    default: begin
                        if (s_axi_araddr[15:0] >= REG_DENOM0 &&
                            s_axi_araddr[15:0] < REG_DENOM0 + 16'h0010) begin
                            result_read_index =
                                (s_axi_araddr[15:0] - REG_DENOM0) >> 2;
                            if (result_valid_sticky)
                                s_axi_rdata <= {4'd0,
                                    arith_denominators[
                                        (result_read_index*28) +: 28]};
                        end else if (s_axi_araddr[15:0] >= REG_RECIP0 &&
                            s_axi_araddr[15:0] < REG_RECIP0 + 16'h0010) begin
                            result_read_index =
                                (s_axi_araddr[15:0] - REG_RECIP0) >> 2;
                            if (result_valid_sticky)
                                s_axi_rdata <= {14'd0,
                                    arith_reciprocal_exponents[
                                        (result_read_index*5) +: 5],
                                    arith_reciprocals[
                                        (result_read_index*13) +: 13]};
                        end else if (s_axi_araddr[15:0] >= SCORE_BASE &&
                            s_axi_araddr[15:0] < SCORE_BASE + 16'h0800) begin
                            result_read_index =
                                (s_axi_araddr[15:0] - SCORE_BASE) >> 2;
                            if (result_valid_sticky)
                                s_axi_rdata <= {15'd0,
                                    score_mem[result_read_index]};
                        end else if (s_axi_araddr[15:0] >= RESULT_BASE &&
                            s_axi_araddr[15:0] < RESULT_BASE + 16'h1800) begin
                            result_read_index =
                                (s_axi_araddr[15:0] - RESULT_BASE) / 12;
                            result_read_lane =
                                (s_axi_araddr[15:0] - RESULT_BASE) % 12;
                            if (result_valid_sticky) begin
                                case (result_read_lane)
                                    0: s_axi_rdata <=
                                        result_mem[result_read_index][31:0];
                                    4: s_axi_rdata <= {16'd0,
                                        result_mem[result_read_index][47:32]};
                                    8: s_axi_rdata <= {13'd0,
                                        result_mem[result_read_index][66],
                                        result_mem[result_read_index][65:48]};
                                    default: s_axi_rdata <= 32'd0;
                                endcase
                            end
                        end
                    end
                endcase
            end

            if (fault_entry) begin
                result_valid_sticky <= 1'b0;
                done_sticky <= 1'b0;
                error_sticky <= 1'b1;
                abort_children <= 1'b1;
                error_k_tag_reg <= k_tag_reg;
                error_v_tag_reg <= v_tag_reg;
                error_epoch_reg <= epoch_reg;
                error_page_reg <= page_index_reg;
                state <= ST_DRAIN;
                if (ctrl_abort && state != ST_IDLE) begin
                    error_code_reg <= ERR_ABORT;
                    error_subcode_reg <= state;
                    error_source_reg <= SRC_HOST;
                    aborted_sticky <= 1'b1;
                end else if (busy_write_fault || busy_start_fault) begin
                    error_code_reg <= ERR_BUSY;
                    error_subcode_reg <= state;
                    error_source_reg <= SRC_HOST;
                end else if (k_validator_error) begin
                    error_code_reg <= ERR_VALIDATOR;
                    error_subcode_reg <= k_validator_error_code;
                    error_source_reg <= SRC_K;
                end else if (v_validator_error) begin
                    error_code_reg <= ERR_VALIDATOR;
                    error_subcode_reg <= v_validator_error_code;
                    error_source_reg <= SRC_V;
                end else if (verified_type_fault) begin
                    error_code_reg <= ERR_VALIDATOR;
                    error_subcode_reg <= 8'hfe;
                    error_source_reg <= SRC_HOST;
                end else if (k_lane_sticky) begin
                    error_code_reg <= ERR_LANE;
                    error_subcode_reg <= k_lane_error_code;
                    error_source_reg <= SRC_K;
                    if (k_lane_error_code == 8'h07)
                        decoder_fault_count <= decoder_fault_count + 1'b1;
                end else if (v_lane_sticky) begin
                    error_code_reg <= ERR_LANE;
                    error_subcode_reg <= v_lane_error_code;
                    error_source_reg <= SRC_V;
                    if (v_lane_error_code == 8'h07)
                        decoder_fault_count <= decoder_fault_count + 1'b1;
                end else begin
                    error_code_reg <= ERR_ARITH;
                    error_subcode_reg <= arith_error_code;
                    error_source_reg <= SRC_ARITH;
                end
            end else begin
                case (state)
                    ST_IDLE: begin end
                    ST_Q_LOAD: begin
                        if (q_load_index == 10'd511) begin
                            k_validator_started <= 1'b0;
                            v_validator_started <= 1'b0;
                            k_validator_data_index <= 12'd0;
                            v_validator_data_index <= 12'd0;
                            k_validator_scale_index <= 7'd0;
                            v_validator_scale_index <= 7'd0;
                            state <= ST_VALIDATE;
                        end else begin
                            q_load_index <= q_load_index + 1'b1;
                        end
                    end
                    ST_VALIDATE: begin
                        if (!k_validator_started && k_validator_cmd_ready)
                            k_validator_started <= 1'b1;
                        if (!v_validator_started && v_validator_cmd_ready)
                            v_validator_started <= 1'b1;
                        if (k_validator_data_valid && k_validator_data_ready)
                            k_validator_data_index <=
                                k_validator_data_index + 1'b1;
                        if (v_validator_data_valid && v_validator_data_ready)
                            v_validator_data_index <=
                                v_validator_data_index + 1'b1;
                        if (k_validator_scale_valid && k_validator_scale_ready)
                            k_validator_scale_index <=
                                k_validator_scale_index + 1'b1;
                        if (v_validator_scale_valid && v_validator_scale_ready)
                            v_validator_scale_index <=
                                v_validator_scale_index + 1'b1;
                        if (lane_page_fire) begin
                            k_payload_latched <= k_verified_payload;
                            v_payload_latched <= v_verified_payload;
                            k_scale_bytes_latched <= k_verified_scale_bytes;
                            v_scale_bytes_latched <= v_verified_scale_bytes;
                            raw_page_count <= raw_page_count +
                                k_verified_raw + v_verified_raw;
                            state <= ST_DECODE;
                        end
                    end
                    ST_DECODE: begin
                        if (k_lane_publish_valid && v_lane_publish_valid) begin
                            state <= ST_ARITH_START;
                        end
                    end
                    ST_ARITH_START: begin
                        if (arith_start_ready)
                            state <= ST_ARITH_RUN;
                    end
                    ST_ARITH_RUN: begin
                        if (arith_done) begin
                            if (stored_score_count != context_reg*4 ||
                                stored_result_count != 512) begin
                                result_valid_sticky <= 1'b0;
                                error_sticky <= 1'b1;
                                error_code_reg <= ERR_INTERNAL;
                                error_subcode_reg <= 8'h01;
                                error_source_reg <= SRC_ARITH;
                                abort_children <= 1'b1;
                                state <= ST_DRAIN;
                            end else begin
                                done_sticky <= 1'b1;
                                result_valid_sticky <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end
                    ST_DRAIN: begin
                        if (children_clearable)
                            state <= ST_FAULT;
                    end
                    ST_FAULT: begin end
                    default: begin
                        result_valid_sticky <= 1'b0;
                        error_sticky <= 1'b1;
                        error_code_reg <= ERR_INTERNAL;
                        error_subcode_reg <= state;
                        error_source_reg <= SRC_HOST;
                        abort_children <= 1'b1;
                        state <= ST_DRAIN;
                    end
                endcase
            end
        end
    end

    wire unused_axi_prot = ^s_axi_awprot ^ ^s_axi_arprot;
    wire unused_child_status = k_lane_draining ^ v_lane_draining ^
        arith_aborted ^ ^arith_error_subcode ^ ^arith_perf_cycles ^
        ^stored_score_count ^ ^stored_result_count;

`ifndef SYNTHESIS
    initial begin
        if (C_S_AXI_DATA_WIDTH != 32 || C_S_AXI_ADDR_WIDTH != 16)
            $error("axi_kvq_canned_page_diag requires AXI-Lite 32/16");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("axi_kvq_canned_page_diag SCALE_BITS must be 12 or 16");
        if (MAX_CONTEXT != 128)
            $error("axi_kvq_canned_page_diag canned ABI fixes context 128");
        if (QK_MULT_STYLE < 0 || QK_MULT_STYLE > 2)
            $error("axi_kvq_canned_page_diag QK_MULT_STYLE must be 0..2");
        if (AV_MULT_STYLE < 0 || AV_MULT_STYLE > 2)
            $error("axi_kvq_canned_page_diag AV_MULT_STYLE must be 0..2");
    end
`endif
endmodule

`default_nettype wire
