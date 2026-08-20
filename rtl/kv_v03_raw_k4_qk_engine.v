// kv_v03_raw_k4_qk_engine.v -- raw DDR K4 to signed-Q8.8 score path.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// Dense K4 storage is 64 bytes/token: 128 little-endian signed four-bit
// values, with the low nibble holding the lower dimension.  One K vector and
// one scale are fetched per token, then reused for all four query rows.
module kv_v03_raw_k4_qk_engine #(
    parameter integer MAX_CONTEXT     = 128,
    parameter integer AXI_ADDR_WIDTH  = 32,
    parameter integer AXI_DATA_WIDTH  = 64,
    parameter integer AXI_ID_WIDTH    = 1,
    parameter integer TIMEOUT_CYCLES  = 65536,
    parameter integer MULT_STYLE      = 2,
    parameter integer SCALE_WIDTH     = 12
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start,
    input  wire                         abort,
    input  wire [12:0]                  context_len,
    input  wire [AXI_ADDR_WIDTH-1:0]    k_base_addr,
    // row-major [head][dimension], signed INT8 in each byte.  The owner keeps
    // this stable while busy.
    input  wire [4095:0]                q_vectors,

    output wire                         meta_req_valid,
    input  wire                         meta_req_ready,
    output wire [6:0]                   meta_req_token,
    input  wire                         meta_rsp_valid,
    output wire                         meta_rsp_ready,
    input  wire [SCALE_WIDTH-1:0]       meta_scale,

    output reg                          busy,
    output wire                         draining,
    output reg                          done,
    output reg                          aborted,
    output reg                          error_valid,
    output reg  [7:0]                   error_code,
    // {state[3:0], head[1:0], token[6:0], 3'b000}
    output reg  [15:0]                  error_tag,

    output reg  [31:0]                  perf_cycles,
    output wire [31:0]                  read_beats,
    output wire [31:0]                  burst_count,
    output wire [31:0]                  ar_stall_cycles,
    output wire [31:0]                  r_wait_cycles,
    output reg  [31:0]                  metadata_wait_cycles,
    output reg  [31:0]                  dot_active_cycles,
    output reg  [31:0]                  score_stall_cycles,
    output reg  [31:0]                  score_count,

    output wire [6:0]                   progress_token,
    output wire [1:0]                   progress_head,
    output wire [2:0]                   progress_slice,
    output wire [3:0]                   progress_state,

    output wire                         score_valid,
    input  wire                         score_ready,
    output wire [1:0]                   score_row,
    output wire [11:0]                  score_index,
    output wire signed [15:0]           score,
    output wire                         score_saturated,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]                   m_axi_arlen,
    output wire [2:0]                   m_axi_arsize,
    output wire [1:0]                   m_axi_arburst,
    output wire                         m_axi_arlock,
    output wire [3:0]                   m_axi_arcache,
    output wire [2:0]                   m_axi_arprot,
    output wire [3:0]                   m_axi_arqos,
    output wire                         m_axi_arvalid,
    input  wire                         m_axi_arready,
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output wire                         m_axi_rready
);
    localparam integer SCALE_FRACTION_BITS =
        (SCALE_WIDTH == 16) ? 11 : 8;
    localparam integer AXI_BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam integer AXI_BYTE_SHIFT = $clog2(AXI_BYTES_PER_BEAT);

    localparam [3:0] ST_IDLE        = 4'd0,
                     ST_FETCH       = 4'd1,
                     ST_FEED        = 4'd2,
                     ST_DOT_WAIT    = 4'd3,
                     ST_SCORE       = 4'd4,
                     ST_ABORT_DRAIN = 4'd5,
                     ST_ERROR_DRAIN = 4'd6;

    localparam [7:0] ERR_CONTEXT      = 8'h01;
    localparam [7:0] ERR_K_ADDRESS    = 8'h04;
    localparam [7:0] ERR_META_TIMEOUT = 8'h20;
    localparam [7:0] ERR_INVALID_K    = 8'h21;
    localparam [7:0] ERR_INTERNAL     = 8'h24;
    localparam [7:0] ERR_BUSY_START   = 8'h80;

    reg [3:0] state;
    reg [12:0] context_reg;
    reg [AXI_ADDR_WIDTH-1:0] k_base_reg;
    reg [6:0] token_index;
    reg [1:0] feed_head;
    reg [2:0] feed_slice;
    reg [511:0] k_codes_hold;
    reg [SCALE_WIDTH-1:0] scale_hold;
    reg k_cmd_sent;
    reg k_have;
    reg meta_cmd_sent;
    reg meta_have;
    reg [31:0] meta_timeout_count;
    reg meta_drain_pending;
    reg reader_abort;
    reg reader_clear_counters;
    reg core_abort;

    wire [32:0] requested_bytes_ext = {20'b0, context_len} << 6;
    wire [32:0] request_last_addr_ext =
        {1'b0, k_base_addr} + requested_bytes_ext - 1'b1;
    wire [AXI_ADDR_WIDTH-1:0] reader_cmd_addr =
        k_base_reg + ({25'b0, token_index} << 6);

    wire reader_cmd_ready;
    wire reader_data_valid;
    wire [AXI_DATA_WIDTH-1:0] reader_data;
    wire [AXI_BYTES_PER_BEAT-1:0] reader_data_keep;
    wire reader_data_last;
    wire [13:0] reader_data_byte_offset;
    wire reader_busy;
    wire reader_draining;
    wire reader_done;
    wire reader_aborted;
    wire reader_error_valid;
    wire [7:0] reader_error_code;
    wire [7:0] reader_error_tag;
    wire [31:0] reader_output_stall_cycles;

    wire reader_cmd_valid = busy && state == ST_FETCH && !k_cmd_sent &&
                            !abort && !start;
    wire reader_data_ready = busy && state == ST_FETCH && k_cmd_sent &&
                             !k_have && !abort && !start;
    wire reader_cmd_fire = reader_cmd_valid && reader_cmd_ready;
    wire reader_data_fire = reader_data_valid && reader_data_ready;

    kv_v03_hp64_range_reader #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH),
        .TAG_WIDTH(8),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_BYTES(64)
    ) u_k_reader (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(reader_cmd_valid), .cmd_ready(reader_cmd_ready),
        .cmd_addr(reader_cmd_addr), .cmd_bytes(14'd64),
        .cmd_tag({1'b0, token_index}), .abort(reader_abort),
        .data_valid(reader_data_valid), .data_ready(reader_data_ready),
        .data(reader_data), .data_keep(reader_data_keep),
        .data_last(reader_data_last),
        .data_byte_offset(reader_data_byte_offset), .data_tag(),
        .busy(reader_busy), .draining(reader_draining),
        .done(reader_done), .done_tag(),
        .aborted(reader_aborted), .aborted_tag(),
        .error_valid(reader_error_valid),
        .error_code(reader_error_code), .error_tag(reader_error_tag),
        .clear_counters(reader_clear_counters),
        .read_beats(read_beats), .burst_count(burst_count),
        .ar_stall_cycles(ar_stall_cycles),
        .r_wait_cycles(r_wait_cycles),
        .output_stall_cycles(reader_output_stall_cycles),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    assign meta_req_valid = busy && state == ST_FETCH && !meta_cmd_sent &&
                            !abort && !start;
    assign meta_req_token = token_index;
    assign meta_rsp_ready =
        (busy && state == ST_FETCH && meta_cmd_sent && !meta_have &&
         !abort && !start) ||
        ((state == ST_ABORT_DRAIN || state == ST_ERROR_DRAIN) &&
         meta_drain_pending);
    wire meta_req_fire = meta_req_valid && meta_req_ready;
    wire meta_rsp_fire = meta_rsp_valid && meta_rsp_ready;
    wire meta_outstanding_now = meta_cmd_sent && !meta_have && !meta_rsp_fire;
    wire fetch_k_complete = k_have || reader_done;
    wire fetch_meta_complete = meta_have ||
                               (state == ST_FETCH && meta_rsp_fire);
    wire meta_timeout_now = busy && state == ST_FETCH &&
        ((!meta_cmd_sent && meta_req_valid && !meta_req_ready) ||
         (meta_cmd_sent && !meta_have && !meta_rsp_fire)) &&
        (meta_timeout_count >= TIMEOUT_CYCLES-1);

    wire dot_in_valid = busy && state == ST_FEED && !abort && !start;
    wire [127:0] dot_q_lanes =
        q_vectors[(feed_head*1024 + feed_slice*128) +: 128];
    wire [63:0] dot_k_lanes = k_codes_hold[(feed_slice*64) +: 64];
    wire dot_out_valid;
    wire signed [31:0] dot_result;
    wire dot_invalid_code;

    qk_group_dot #(
        .GROUP_SIZE(128), .Q_WIDTH(8), .K_WIDTH(4),
        .SCALE_WIDTH(SCALE_WIDTH), .ACC_WIDTH(32),
        .MULT_STYLE(MULT_STYLE)
    ) u_qk_dot (
        .clk(clk), .rst_n(rst_n), .abort(core_abort),
        .in_valid(dot_in_valid),
        .vector_start(feed_slice == 0),
        .vector_last(feed_slice == 7),
        .q_lanes(dot_q_lanes), .k_lanes(dot_k_lanes),
        .group_scale(scale_hold),
        .out_valid(dot_out_valid), .result(dot_result),
        .invalid_code(dot_invalid_code)
    );

    wire quant_in_ready;
    wire quant_out_valid;
    wire quant_out_ready = busy && state == ST_SCORE && !abort && !start &&
                           score_ready;
    wire [1:0] quant_out_row;
    wire [11:0] quant_out_index;
    wire signed [15:0] quant_out_score;
    wire quant_out_saturated;

    kv_v03_qk_score_quantizer #(
        .INPUT_WIDTH(32),
        .SCALE_FRACTION_BITS(SCALE_FRACTION_BITS),
        .OUTPUT_FRACTION_BITS(8)
    ) u_quantizer (
        .clk(clk), .rst_n(rst_n), .abort(core_abort),
        .in_valid(busy && state == ST_DOT_WAIT && dot_out_valid &&
                  !dot_invalid_code && !abort && !start),
        .in_ready(quant_in_ready), .in_row(feed_head),
        .in_index({5'b0, token_index}), .in_score(dot_result),
        .out_valid(quant_out_valid), .out_ready(quant_out_ready),
        .out_row(quant_out_row), .out_index(quant_out_index),
        .out_score(quant_out_score),
        .out_saturated(quant_out_saturated)
    );

    assign score_valid = busy && state == ST_SCORE && quant_out_valid &&
                         !abort && !start;
    assign score_row = quant_out_row;
    assign score_index = quant_out_index;
    assign score = quant_out_score;
    assign score_saturated = quant_out_saturated;
    wire score_fire = score_valid && score_ready;

    assign draining = state == ST_ABORT_DRAIN || state == ST_ERROR_DRAIN ||
                      reader_draining || meta_drain_pending;
    assign progress_token = token_index;
    assign progress_head = feed_head;
    assign progress_slice = feed_slice;
    assign progress_state = state;

    function [7:0] map_reader_error;
        input [7:0] code;
        begin
            case (code)
                8'h01, 8'h02, 8'h03: map_reader_error = ERR_K_ADDRESS;
                8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15:
                    map_reader_error = code;
                default: map_reader_error = ERR_INTERNAL;
            endcase
        end
    endfunction

    function [15:0] make_error_tag;
        input [3:0] tagged_state;
        input [1:0] tagged_head;
        input [6:0] tagged_token;
        begin
            make_error_tag = {tagged_state, tagged_head, tagged_token, 3'b000};
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            context_reg          <= 13'd0;
            k_base_reg           <= {AXI_ADDR_WIDTH{1'b0}};
            token_index          <= 7'd0;
            feed_head            <= 2'd0;
            feed_slice           <= 3'd0;
            k_codes_hold         <= 512'd0;
            scale_hold           <= {SCALE_WIDTH{1'b0}};
            k_cmd_sent           <= 1'b0;
            k_have               <= 1'b0;
            meta_cmd_sent        <= 1'b0;
            meta_have            <= 1'b0;
            meta_timeout_count   <= 32'd0;
            meta_drain_pending   <= 1'b0;
            reader_abort         <= 1'b0;
            reader_clear_counters <= 1'b0;
            core_abort           <= 1'b0;
            busy                 <= 1'b0;
            done                 <= 1'b0;
            aborted              <= 1'b0;
            error_valid          <= 1'b0;
            error_code           <= 8'd0;
            error_tag            <= 16'd0;
            perf_cycles          <= 32'd0;
            metadata_wait_cycles <= 32'd0;
            dot_active_cycles    <= 32'd0;
            score_stall_cycles   <= 32'd0;
            score_count          <= 32'd0;
        end else begin
            done                  <= 1'b0;
            aborted               <= 1'b0;
            error_valid           <= 1'b0;
            reader_abort          <= 1'b0;
            reader_clear_counters <= 1'b0;
            core_abort            <= 1'b0;

            if (busy)
                perf_cycles <= perf_cycles + 1'b1;
            if (busy && state == ST_FETCH &&
                ((!meta_cmd_sent && !meta_req_ready) ||
                 (meta_cmd_sent && !meta_have && !meta_rsp_valid)))
                metadata_wait_cycles <= metadata_wait_cycles + 1'b1;
            if (busy && (state == ST_FEED || state == ST_DOT_WAIT))
                dot_active_cycles <= dot_active_cycles + 1'b1;
            if (score_valid && !score_ready)
                score_stall_cycles <= score_stall_cycles + 1'b1;
            if (score_fire)
                score_count <= score_count + 1'b1;

            if ((state == ST_ABORT_DRAIN || state == ST_ERROR_DRAIN) &&
                meta_drain_pending && meta_rsp_fire)
                meta_drain_pending <= 1'b0;

            // First fault wins.  Accepted AXI and metadata obligations remain
            // owned until their termination handshakes have been observed.
            if (busy && reader_error_valid && state != ST_ERROR_DRAIN) begin
                error_valid  <= 1'b1;
                error_code   <= map_reader_error(reader_error_code);
                error_tag    <= make_error_tag(state, feed_head,
                                               reader_error_tag[6:0]);
                core_abort   <= 1'b1;
                k_have       <= 1'b0;
                meta_have    <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                if (reader_busy)
                    reader_abort <= 1'b1;
                if (reader_busy || meta_outstanding_now)
                    state <= ST_ERROR_DRAIN;
                else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (busy && abort && state != ST_ABORT_DRAIN &&
                         state != ST_ERROR_DRAIN) begin
                core_abort <= 1'b1;
                k_have     <= 1'b0;
                meta_have  <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                if (reader_busy)
                    reader_abort <= 1'b1;
                if (reader_busy || meta_outstanding_now)
                    state <= ST_ABORT_DRAIN;
                else begin
                    busy    <= 1'b0;
                    aborted <= 1'b1;
                    state   <= ST_IDLE;
                end
            end else if (busy && start && state != ST_ERROR_DRAIN) begin
                error_valid <= 1'b1;
                error_code  <= ERR_BUSY_START;
                error_tag   <= make_error_tag(state, feed_head, token_index);
                core_abort  <= 1'b1;
                k_have      <= 1'b0;
                meta_have   <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                if (reader_busy)
                    reader_abort <= 1'b1;
                if (reader_busy || meta_outstanding_now)
                    state <= ST_ERROR_DRAIN;
                else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (meta_timeout_now) begin
                error_valid <= 1'b1;
                error_code  <= ERR_META_TIMEOUT;
                error_tag   <= make_error_tag(state, feed_head, token_index);
                core_abort  <= 1'b1;
                k_have      <= 1'b0;
                meta_have   <= 1'b0;
                meta_drain_pending <= meta_cmd_sent && !meta_have;
                if (reader_busy)
                    reader_abort <= 1'b1;
                if (reader_busy || (meta_cmd_sent && !meta_have))
                    state <= ST_ERROR_DRAIN;
                else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (busy && state == ST_DOT_WAIT && dot_out_valid &&
                         dot_invalid_code) begin
                error_valid <= 1'b1;
                error_code  <= ERR_INVALID_K;
                error_tag   <= make_error_tag(state, feed_head, token_index);
                core_abort  <= 1'b1;
                busy        <= 1'b0;
                state       <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        busy               <= 1'b0;
                        k_cmd_sent         <= 1'b0;
                        k_have             <= 1'b0;
                        meta_cmd_sent      <= 1'b0;
                        meta_have          <= 1'b0;
                        meta_drain_pending <= 1'b0;
                        meta_timeout_count <= 32'd0;
                        if (start && !abort) begin
                            error_code <= 8'd0;
                            error_tag  <= 16'd0;
                            if (context_len == 0 ||
                                context_len > MAX_CONTEXT) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_CONTEXT;
                                error_tag   <= make_error_tag(
                                    ST_IDLE, 2'd0, 7'd0);
                            end else if (k_base_addr[AXI_BYTE_SHIFT-1:0] != 0 ||
                                         request_last_addr_ext[32]) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_K_ADDRESS;
                                error_tag   <= make_error_tag(
                                    ST_IDLE, 2'd0, 7'd0);
                            end else if (reader_busy) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_INTERNAL;
                                error_tag   <= make_error_tag(
                                    ST_IDLE, 2'd0, 7'd0);
                            end else begin
                                context_reg          <= context_len;
                                k_base_reg           <= k_base_addr;
                                token_index          <= 7'd0;
                                feed_head            <= 2'd0;
                                feed_slice           <= 3'd0;
                                perf_cycles          <= 32'd0;
                                metadata_wait_cycles <= 32'd0;
                                dot_active_cycles    <= 32'd0;
                                score_stall_cycles   <= 32'd0;
                                score_count          <= 32'd0;
                                reader_clear_counters <= 1'b1;
                                busy                 <= 1'b1;
                                state                <= ST_FETCH;
                            end
                        end
                    end

                    ST_FETCH: begin
                        if (reader_cmd_fire)
                            k_cmd_sent <= 1'b1;
                        if (reader_data_fire) begin
                            k_codes_hold[(reader_data_byte_offset*8) +:
                                         AXI_DATA_WIDTH]
                                <= reader_data;
                        end
                        if (reader_done)
                            k_have <= 1'b1;
                        if (meta_req_fire) begin
                            meta_cmd_sent      <= 1'b1;
                            meta_timeout_count <= 32'd0;
                        end
                        if (meta_rsp_fire) begin
                            scale_hold         <= meta_scale;
                            meta_have          <= 1'b1;
                            meta_timeout_count <= 32'd0;
                        end
                        if ((!meta_cmd_sent && !meta_req_fire) ||
                            (meta_cmd_sent && !meta_have && !meta_rsp_fire))
                            meta_timeout_count <= meta_timeout_count + 1'b1;

                        if (fetch_k_complete && fetch_meta_complete) begin
                            feed_head  <= 2'd0;
                            feed_slice <= 3'd0;
                            state      <= ST_FEED;
                        end
                    end

                    ST_FEED: begin
                        if (feed_slice == 7) begin
                            feed_slice <= 3'd0;
                            state      <= ST_DOT_WAIT;
                        end else begin
                            feed_slice <= feed_slice + 1'b1;
                        end
                    end

                    ST_DOT_WAIT: begin
                        if (dot_out_valid && !dot_invalid_code) begin
                            if (quant_in_ready)
                                state <= ST_SCORE;
                            else begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_INTERNAL;
                                error_tag   <= make_error_tag(
                                    state, feed_head, token_index);
                                core_abort <= 1'b1;
                                busy       <= 1'b0;
                                state      <= ST_IDLE;
                            end
                        end
                    end

                    ST_SCORE: begin
                        if (score_fire) begin
                            if (feed_head != 3) begin
                                feed_head  <= feed_head + 1'b1;
                                feed_slice <= 3'd0;
                                state      <= ST_FEED;
                            end else if ({6'd0, token_index} !=
                                         context_reg - 1'b1) begin
                                token_index       <= token_index + 1'b1;
                                feed_head         <= 2'd0;
                                feed_slice        <= 3'd0;
                                k_cmd_sent        <= 1'b0;
                                k_have            <= 1'b0;
                                meta_cmd_sent     <= 1'b0;
                                meta_have         <= 1'b0;
                                meta_timeout_count <= 32'd0;
                                state             <= ST_FETCH;
                            end else begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end

                    ST_ABORT_DRAIN: begin
                        if (!reader_busy && !meta_drain_pending) begin
                            busy    <= 1'b0;
                            aborted <= 1'b1;
                            state   <= ST_IDLE;
                        end
                    end

                    ST_ERROR_DRAIN: begin
                        if (!reader_busy && !meta_drain_pending) begin
                            busy  <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end

                    default: begin
                        core_abort <= 1'b1;
                        busy       <= 1'b0;
                        state      <= ST_IDLE;
                    end
                endcase
            end
        end
    end

    wire unused_reader_aborted = reader_aborted;
    wire unused_reader_data_last = reader_data_last;
    wire [AXI_BYTES_PER_BEAT-1:0] unused_reader_data_keep =
        reader_data_keep;
    wire [31:0] unused_reader_output_stall_cycles =
        reader_output_stall_cycles;

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("kv_v03_raw_k4_qk_engine MAX_CONTEXT must be 1..128");
        if (AXI_ADDR_WIDTH != 32)
            $error("kv_v03_raw_k4_qk_engine AXI_ADDR_WIDTH must be 32");
        if (AXI_DATA_WIDTH != 64 && AXI_DATA_WIDTH != 128)
            $error("kv_v03_raw_k4_qk_engine AXI_DATA_WIDTH must be 64 or 128");
        if (AXI_ID_WIDTH != 1)
            $error("kv_v03_raw_k4_qk_engine AXI_ID_WIDTH must be 1");
        if (TIMEOUT_CYCLES < 1)
            $error("kv_v03_raw_k4_qk_engine TIMEOUT_CYCLES must be positive");
        if (MULT_STYLE < 0 || MULT_STYLE > 2)
            $error("kv_v03_raw_k4_qk_engine MULT_STYLE must be 0..2");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("kv_v03_raw_k4_qk_engine SCALE_WIDTH must be 12 or 16");
    end
`endif
endmodule

`default_nettype wire
