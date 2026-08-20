// kv_v03_raw_v5_av_engine.v -- raw DDR V5 to signed-48 AV diagnostic path.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// V vectors come from the read-only AXI master.  Per-token UQ4.8 scale and
// four little-endian P16 exponent codes come from a local request/response
// port owned by the eventual AXI-Lite wrapper.  Keeping metadata local makes
// this Phase-2 unit test the V5 transport and existing AV arithmetic without
// prematurely defining the final paged-cache ABI.
module kv_v03_raw_v5_av_engine #(
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
    input  wire [AXI_ADDR_WIDTH-1:0]    v_base_addr,

    output wire                         meta_req_valid,
    input  wire                         meta_req_ready,
    output wire [6:0]                   meta_req_token,
    input  wire                         meta_rsp_valid,
    output wire                         meta_rsp_ready,
    input  wire [SCALE_WIDTH-1:0]       meta_scale,
    input  wire [63:0]                  meta_exp_codes,

    output reg                          busy,
    output wire                         draining,
    output reg                          done,
    output reg                          aborted,
    output reg                          error,
    output reg  [7:0]                   error_code,
    output reg  [31:0]                  perf_cycles,
    output wire [31:0]                  read_beats,
    output wire [31:0]                  ar_stall_cycles,
    output wire [31:0]                  r_stall_cycles,

    output wire [6:0]                   progress_token,
    output wire [1:0]                   progress_head,
    output wire [2:0]                   progress_group,
    output wire [3:0]                   progress_state,

    output wire                         result_valid,
    input  wire                         result_ready,
    output wire [1:0]                   result_head,
    output wire [2:0]                   result_group,
    output wire [767:0]                 result_numerators,
    output wire                         result_last,

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
    localparam [3:0] ST_IDLE        = 4'd0,
                     ST_FETCH       = 4'd1,
                     ST_FEED        = 4'd2,
                     ST_RESULT      = 4'd3,
                     ST_ABORT_DRAIN = 4'd4,
                     ST_ERROR_DRAIN = 4'd5;

    // Top-level diagnostic error ABI.  AXI transport codes 0x10..0x15 pass
    // through unchanged; arithmetic diagnostics use the requested 0x22..24
    // range, and a busy-start cancellation is deliberately conspicuous.
    localparam [7:0] ERR_CONTEXT            = 8'h01;
    localparam [7:0] ERR_V_ADDRESS          = 8'h04;
    localparam [7:0] ERR_INTERNAL           = 8'h24;
    localparam [7:0] ERR_BUSY_START         = 8'h80;

    reg [3:0] state;
    reg [12:0] context_reg;
    reg [AXI_ADDR_WIDTH-1:0] v_base_reg;
    reg [6:0] token_index;
    reg [1:0] feed_head;
    reg [2:0] feed_group;

    reg v_cmd_sent;
    reg meta_cmd_sent;
    reg v_have;
    reg meta_have;
    reg [639:0] v_codes_hold;
    reg [SCALE_WIDTH-1:0] scale_hold;
    reg [63:0] exp_codes_hold;
    reg [31:0] meta_timeout_count;

    reg meta_drain_pending;
    reg meta_drain_timeout_reported;
    reg [31:0] meta_drain_timeout_count;

    reg reader_abort;
    reg reader_clear_counters;
    reg av_start;
    reg av_soft_reset;

    function [7:0] map_reader_error;
        input [7:0] code;
        begin
            case (code)
                8'h01, 8'h02: map_reader_error = ERR_V_ADDRESS;
                8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15:
                    map_reader_error = code;
                default: map_reader_error = ERR_INTERNAL;
            endcase
        end
    endfunction

    function [7:0] map_av_error;
        input [7:0] code;
        begin
            case (code)
                8'h05: map_av_error = 8'h22; // zero UQ4.8 V scale
                8'h04: map_av_error = 8'h23; // reserved signed-V5 -16
                default: map_av_error = ERR_INTERNAL;
            endcase
        end
    endfunction

    wire [32:0] requested_bytes_ext =
        {20'b0, context_len} * 33'd80;
    wire [32:0] request_last_addr_ext =
        {1'b0, v_base_addr} + requested_bytes_ext - 1'b1;
    wire [31:0] token_byte_offset =
        ({25'b0, token_index} << 6) +
        ({25'b0, token_index} << 4);
    wire [AXI_ADDR_WIDTH-1:0] reader_cmd_addr =
        v_base_reg + token_byte_offset;

    wire reader_cmd_valid;
    wire reader_cmd_ready;
    wire reader_vector_valid;
    wire reader_vector_ready;
    wire [639:0] reader_vector_codes;
    wire reader_busy;
    wire reader_draining;
    wire reader_aborted;
    wire reader_error;
    wire [7:0] reader_error_code;

    wire reader_cmd_handshake = reader_cmd_valid && reader_cmd_ready;
    wire reader_vector_handshake = reader_vector_valid &&
                                           reader_vector_ready;
    wire meta_req_handshake = meta_req_valid && meta_req_ready;
    wire meta_rsp_handshake = meta_rsp_valid && meta_rsp_ready;

    // A new request is not launched in a cycle that is cancelling the current
    // job.  This closes the same-cycle accepted-AR/forgotten-command hole.
    assign reader_cmd_valid = busy && state == ST_FETCH && !v_cmd_sent &&
                              !abort && !start;
    assign reader_vector_ready = busy && state == ST_FETCH && v_cmd_sent &&
                                 !v_have && !abort && !start;
    assign meta_req_valid = busy && state == ST_FETCH && !meta_cmd_sent &&
                            !abort && !start;
    assign meta_req_token = token_index;
    assign meta_rsp_ready = ((busy && state == ST_FETCH && meta_cmd_sent &&
                              !meta_have && !abort && !start) ||
                             ((state == ST_ABORT_DRAIN ||
                               state == ST_ERROR_DRAIN) &&
                              meta_drain_pending));

    wire fetch_v_complete = v_have || reader_vector_handshake;
    wire fetch_meta_complete = meta_have ||
                               (state == ST_FETCH && meta_rsp_handshake);
    wire meta_outstanding_now = meta_cmd_sent && !meta_have &&
                                !meta_rsp_handshake;

    wire meta_req_timeout_now = busy && state == ST_FETCH &&
        !meta_cmd_sent && meta_req_valid && !meta_req_ready &&
        (meta_timeout_count >= TIMEOUT_CYCLES-1);
    wire meta_rsp_timeout_now = busy && state == ST_FETCH &&
        meta_cmd_sent && !meta_have && !meta_rsp_handshake &&
        (meta_timeout_count >= TIMEOUT_CYCLES-1);
    wire meta_drain_timeout_now =
        (state == ST_ABORT_DRAIN || state == ST_ERROR_DRAIN) &&
        meta_drain_pending && !meta_rsp_handshake &&
        !meta_drain_timeout_reported &&
        (meta_drain_timeout_count >= TIMEOUT_CYCLES-1);

    kv_v03_raw_v5_axi_reader #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_v_reader (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(reader_cmd_valid), .cmd_ready(reader_cmd_ready),
        .cmd_addr(reader_cmd_addr), .abort(reader_abort),
        .vector_valid(reader_vector_valid),
        .vector_ready(reader_vector_ready),
        .vector_codes(reader_vector_codes),
        .busy(reader_busy), .draining(reader_draining),
        .aborted(reader_aborted), .error(reader_error),
        .error_code(reader_error_code),
        .clear_counters(reader_clear_counters),
        .read_beats(read_beats),
        .ar_stall_cycles(ar_stall_cycles),
        .r_stall_cycles(r_stall_cycles),
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

    wire av_rst_n = rst_n && !av_soft_reset;
    wire av_in_valid = busy && state == ST_FEED && !abort && !start;
    wire av_in_ready;
    wire [79:0] av_in_v_codes =
        v_codes_hold[(feed_group*80) +: 80];
    wire [15:0] av_in_exp_code =
        exp_codes_hold[(feed_head*16) +: 16];
    wire av_out_valid;
    wire av_out_ready = busy && state == ST_RESULT && !abort && !start &&
                        result_ready;
    wire [1:0] av_out_head;
    wire [2:0] av_out_group;
    wire [767:0] av_out_numerators;
    wire av_out_last;
    wire av_busy;
    wire av_done;
    wire av_error;
    wire [7:0] av_error_code;

    // kv_v03_av_accumulator is the existing v0.3 ABI arithmetic block.  Its
    // guard intentionally fixes MAX_CONTEXT=4096; this diagnostic engine
    // enforces the smaller 128-token limit before presenting context_len.
    kv_v03_av_accumulator #(
        .MAX_CONTEXT(4096),
        .MULT_STYLE(MULT_STYLE),
        .SCALE_WIDTH(SCALE_WIDTH)
    ) u_av (
        .clk(clk), .rst_n(av_rst_n),
        .start(av_start), .context_len(context_reg),
        .in_valid(av_in_valid), .in_ready(av_in_ready),
        .in_head(feed_head), .in_group(feed_group),
        .in_exp_code(av_in_exp_code), .in_v_scale(scale_hold),
        .in_v_codes(av_in_v_codes),
        .out_valid(av_out_valid), .out_ready(av_out_ready),
        .out_head(av_out_head), .out_group(av_out_group),
        .out_numerators(av_out_numerators), .out_last(av_out_last),
        .busy(av_busy), .done(av_done),
        .error_valid(av_error), .error_code(av_error_code)
    );

    assign result_valid = busy && state == ST_RESULT && !abort && !start &&
                          av_out_valid;
    assign result_head = av_out_head;
    assign result_group = av_out_group;
    assign result_numerators = av_out_numerators;
    assign result_last = result_valid && av_out_last;

    assign draining = (state == ST_ABORT_DRAIN) ||
                      (state == ST_ERROR_DRAIN) || reader_draining ||
                      meta_drain_pending;
    assign progress_token = token_index;
    assign progress_head = feed_head;
    assign progress_group = feed_group;
    assign progress_state = state;

    wire av_input_handshake = av_in_valid && av_in_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state                       <= ST_IDLE;
            context_reg                 <= 13'b0;
            v_base_reg                  <= {AXI_ADDR_WIDTH{1'b0}};
            token_index                 <= 7'b0;
            feed_head                   <= 2'b0;
            feed_group                  <= 3'b0;
            v_cmd_sent                  <= 1'b0;
            meta_cmd_sent               <= 1'b0;
            v_have                      <= 1'b0;
            meta_have                   <= 1'b0;
            v_codes_hold                <= 640'b0;
            scale_hold                  <= {SCALE_WIDTH{1'b0}};
            exp_codes_hold              <= 64'b0;
            meta_timeout_count          <= 32'b0;
            meta_drain_pending          <= 1'b0;
            meta_drain_timeout_reported <= 1'b0;
            meta_drain_timeout_count    <= 32'b0;
            reader_abort                <= 1'b0;
            reader_clear_counters       <= 1'b0;
            av_start                    <= 1'b0;
            av_soft_reset               <= 1'b0;
            busy                        <= 1'b0;
            done                        <= 1'b0;
            aborted                     <= 1'b0;
            error                       <= 1'b0;
            error_code                  <= 8'b0;
            perf_cycles                 <= 32'b0;
        end else begin
            done                  <= 1'b0;
            aborted               <= 1'b0;
            error                 <= 1'b0;
            reader_abort          <= 1'b0;
            reader_clear_counters <= 1'b0;
            av_start              <= 1'b0;
            av_soft_reset         <= 1'b0;

            if (busy)
                perf_cycles <= perf_cycles + 1'b1;

            if ((state == ST_ABORT_DRAIN || state == ST_ERROR_DRAIN) &&
                meta_drain_pending) begin
                if (meta_rsp_handshake) begin
                    meta_drain_pending       <= 1'b0;
                    meta_drain_timeout_count <= 32'b0;
                end else if (!meta_drain_timeout_reported) begin
                    meta_drain_timeout_count <=
                        meta_drain_timeout_count + 1'b1;
                end
            end

            // Preserve the first transport fault while its accepted burst is
            // draining.  This gives software one stable root cause rather
            // than replacing it with a secondary drain symptom.
            if (busy && reader_error && state != ST_ERROR_DRAIN) begin
                error         <= 1'b1;
                error_code    <= map_reader_error(reader_error_code);
                av_soft_reset <= 1'b1;
                v_have        <= 1'b0;
                meta_have     <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                meta_drain_timeout_count <= 32'b0;
                meta_drain_timeout_reported <= 1'b0;
                if (reader_busy || meta_outstanding_now) begin
                    if (reader_busy)
                        reader_abort <= 1'b1;
                    state <= ST_ERROR_DRAIN;
                end else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (busy && av_error && state != ST_ERROR_DRAIN &&
                         !(av_error_code == 8'h02 &&
                           state == ST_ABORT_DRAIN)) begin
                error         <= 1'b1;
                error_code    <= map_av_error(av_error_code);
                av_soft_reset <= 1'b1;
                v_have        <= 1'b0;
                meta_have     <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                meta_drain_timeout_count <= 32'b0;
                meta_drain_timeout_reported <= 1'b0;
                if (reader_busy || meta_outstanding_now) begin
                    if (reader_busy)
                        reader_abort <= 1'b1;
                    state <= ST_ERROR_DRAIN;
                end else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (busy && abort && state != ST_ABORT_DRAIN &&
                         state != ST_ERROR_DRAIN) begin
                av_soft_reset <= 1'b1;
                v_have        <= 1'b0;
                meta_have     <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                meta_drain_timeout_count <= 32'b0;
                meta_drain_timeout_reported <= 1'b0;
                if (reader_busy || meta_outstanding_now) begin
                    if (reader_busy)
                        reader_abort <= 1'b1;
                    state <= ST_ABORT_DRAIN;
                end else begin
                    busy    <= 1'b0;
                    aborted <= 1'b1;
                    state   <= ST_IDLE;
                end
            end else if (busy && start && state != ST_ERROR_DRAIN) begin
                // Busy-start is a fail-closed cancellation, not a pause.  No
                // request/response handshake is enabled in this cycle.
                error         <= 1'b1;
                error_code    <= ERR_BUSY_START;
                av_soft_reset <= 1'b1;
                v_have        <= 1'b0;
                meta_have     <= 1'b0;
                meta_drain_pending <= meta_outstanding_now;
                meta_drain_timeout_count <= 32'b0;
                meta_drain_timeout_reported <= 1'b0;
                if (reader_busy || meta_outstanding_now) begin
                    if (reader_busy)
                        reader_abort <= 1'b1;
                    state <= ST_ERROR_DRAIN;
                end else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (meta_req_timeout_now || meta_rsp_timeout_now) begin
                error      <= 1'b1;
                error_code <= ERR_INTERNAL;
                av_soft_reset <= 1'b1;
                v_have        <= 1'b0;
                meta_have     <= 1'b0;
                meta_drain_pending <= meta_rsp_timeout_now;
                meta_drain_timeout_count <= 32'b0;
                meta_drain_timeout_reported <= 1'b0;
                if (reader_busy || meta_rsp_timeout_now) begin
                    if (reader_busy)
                        reader_abort <= 1'b1;
                    state <= ST_ERROR_DRAIN;
                end else begin
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end
            end else if (meta_drain_timeout_now) begin
                meta_drain_timeout_reported <= 1'b1;
                // An abort had no earlier error; convert it into a typed,
                // sticky failure.  If already handling an error, keep that
                // first code unchanged.
                if (state == ST_ABORT_DRAIN) begin
                    error      <= 1'b1;
                    error_code <= ERR_INTERNAL;
                    state      <= ST_ERROR_DRAIN;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        busy          <= 1'b0;
                        v_cmd_sent    <= 1'b0;
                        meta_cmd_sent <= 1'b0;
                        v_have        <= 1'b0;
                        meta_have     <= 1'b0;
                        meta_drain_pending <= 1'b0;
                        if (start && !abort) begin
                            error_code <= 8'b0;
                            if (context_len == 0 ||
                                context_len > MAX_CONTEXT) begin
                                error      <= 1'b1;
                                error_code <= ERR_CONTEXT;
                            end else if (v_base_addr[3:0] != 0) begin
                                error      <= 1'b1;
                                error_code <= ERR_V_ADDRESS;
                            end else if (request_last_addr_ext[32]) begin
                                error      <= 1'b1;
                                error_code <= ERR_V_ADDRESS;
                            end else if (reader_busy) begin
                                error      <= 1'b1;
                                error_code <= ERR_INTERNAL;
                            end else if (av_busy) begin
                                error      <= 1'b1;
                                error_code <= ERR_INTERNAL;
                            end else begin
                                context_reg           <= context_len;
                                v_base_reg            <= v_base_addr;
                                token_index           <= 7'b0;
                                feed_head             <= 2'b0;
                                feed_group            <= 3'b0;
                                meta_timeout_count    <= 32'b0;
                                perf_cycles           <= 32'b0;
                                reader_clear_counters <= 1'b1;
                                av_start              <= 1'b1;
                                busy                  <= 1'b1;
                                state                 <= ST_FETCH;
                            end
                        end
                    end

                    ST_FETCH: begin
                        if (reader_cmd_handshake)
                            v_cmd_sent <= 1'b1;
                        if (meta_req_handshake) begin
                            meta_cmd_sent      <= 1'b1;
                            meta_timeout_count <= 32'b0;
                        end
                        if (reader_vector_handshake) begin
                            v_codes_hold <= reader_vector_codes;
                            v_have       <= 1'b1;
                        end
                        if (meta_rsp_handshake) begin
                            scale_hold        <= meta_scale;
                            exp_codes_hold    <= meta_exp_codes;
                            meta_have         <= 1'b1;
                            meta_timeout_count <= 32'b0;
                        end

                        if (!meta_cmd_sent) begin
                            if (!meta_req_handshake)
                                meta_timeout_count <=
                                    meta_timeout_count + 1'b1;
                        end else if (!meta_have && !meta_rsp_handshake) begin
                            meta_timeout_count <= meta_timeout_count + 1'b1;
                        end

                        if (fetch_v_complete && fetch_meta_complete) begin
                            feed_head  <= 2'b0;
                            feed_group <= 3'b0;
                            state      <= ST_FEED;
                        end
                    end

                    ST_FEED: begin
                        if (av_input_handshake) begin
                            if (feed_group == 7) begin
                                feed_group <= 3'b0;
                                if (feed_head == 3) begin
                                    feed_head <= 2'b0;
                                    if ({6'b0, token_index} ==
                                        context_reg - 1'b1) begin
                                        state <= ST_RESULT;
                                    end else begin
                                        token_index   <= token_index + 1'b1;
                                        v_cmd_sent    <= 1'b0;
                                        meta_cmd_sent <= 1'b0;
                                        v_have        <= 1'b0;
                                        meta_have     <= 1'b0;
                                        meta_timeout_count <= 32'b0;
                                        state <= ST_FETCH;
                                    end
                                end else begin
                                    feed_head <= feed_head + 1'b1;
                                end
                            end else begin
                                feed_group <= feed_group + 1'b1;
                            end
                        end
                    end

                    ST_RESULT: begin
                        if (av_done) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
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
                        busy          <= 1'b0;
                        av_soft_reset <= 1'b1;
                        state         <= ST_IDLE;
                    end
                endcase
            end
        end
    end

    wire unused_reader_aborted = reader_aborted;

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("kv_v03_raw_v5_av_engine: MAX_CONTEXT must be 1..128");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("kv_v03_raw_v5_av_engine: SCALE_WIDTH must be 12 or 16");
        if (AXI_ADDR_WIDTH != 32)
            $error("kv_v03_raw_v5_av_engine: AXI_ADDR_WIDTH must be 32");
        if (AXI_DATA_WIDTH != 64 && AXI_DATA_WIDTH != 128)
            $error("kv_v03_raw_v5_av_engine: AXI_DATA_WIDTH must be 64 or 128");
        if (AXI_ID_WIDTH != 1)
            $error("kv_v03_raw_v5_av_engine: AXI_ID_WIDTH must be 1");
        if (TIMEOUT_CYCLES < 1)
            $error("kv_v03_raw_v5_av_engine: TIMEOUT_CYCLES must be positive");
        if (MULT_STYLE < 0 || MULT_STYLE > 2)
            $error("kv_v03_raw_v5_av_engine: MULT_STYLE must be 0..2");
    end
`endif
endmodule

`default_nettype wire
