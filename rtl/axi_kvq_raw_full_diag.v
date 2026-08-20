// axi_kvq_raw_full_diag.v -- raw K4/QK/softmax/V5/AV diagnostic.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// This checkpoint-independent diagnostic deliberately has two independent
// 64/128-bit HP read masters.  Scores cross an all-or-nothing tagged commit guard
// before they are copied into the softmax/AV pipeline; partial rows and stale
// normalized results are therefore never software-visible.
module axi_kvq_raw_full_diag #(
    parameter integer MAX_CONTEXT       = 128,
    parameter integer SCALE_WIDTH       = 12,
    parameter integer QK_MULT_STYLE     = 2,
    parameter integer AV_MULT_STYLE     = 2,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 16,
    parameter integer M_AXI_ADDR_WIDTH   = 32,
    parameter integer M_AXI_DATA_WIDTH   = 64,
    parameter integer M_AXI_ID_WIDTH     = 1,
    parameter integer TIMEOUT_CYCLES     = 65536
) (
    input  wire clk,
    input  wire rst_n,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output reg                           s_axi_bvalid,
    input  wire                          s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready,

    output wire [M_AXI_ID_WIDTH-1:0]     m_axi_k_arid,
    output wire [M_AXI_ADDR_WIDTH-1:0]   m_axi_k_araddr,
    output wire [7:0]                    m_axi_k_arlen,
    output wire [2:0]                    m_axi_k_arsize,
    output wire [1:0]                    m_axi_k_arburst,
    output wire                          m_axi_k_arlock,
    output wire [3:0]                    m_axi_k_arcache,
    output wire [2:0]                    m_axi_k_arprot,
    output wire [3:0]                    m_axi_k_arqos,
    output wire                          m_axi_k_arvalid,
    input  wire                          m_axi_k_arready,
    input  wire [M_AXI_ID_WIDTH-1:0]     m_axi_k_rid,
    input  wire [M_AXI_DATA_WIDTH-1:0]   m_axi_k_rdata,
    input  wire [1:0]                    m_axi_k_rresp,
    input  wire                          m_axi_k_rlast,
    input  wire                          m_axi_k_rvalid,
    output wire                          m_axi_k_rready,

    output wire [M_AXI_ID_WIDTH-1:0]     m_axi_v_arid,
    output wire [M_AXI_ADDR_WIDTH-1:0]   m_axi_v_araddr,
    output wire [7:0]                    m_axi_v_arlen,
    output wire [2:0]                    m_axi_v_arsize,
    output wire [1:0]                    m_axi_v_arburst,
    output wire                          m_axi_v_arlock,
    output wire [3:0]                    m_axi_v_arcache,
    output wire [2:0]                    m_axi_v_arprot,
    output wire [3:0]                    m_axi_v_arqos,
    output wire                          m_axi_v_arvalid,
    input  wire                          m_axi_v_arready,
    input  wire [M_AXI_ID_WIDTH-1:0]     m_axi_v_rid,
    input  wire [M_AXI_DATA_WIDTH-1:0]   m_axi_v_rdata,
    input  wire [1:0]                    m_axi_v_rresp,
    input  wire                          m_axi_v_rlast,
    input  wire                          m_axi_v_rvalid,
    output wire                          m_axi_v_rready
);
    localparam [15:0] REG_CTRL          = 16'h0000;
    localparam [15:0] REG_STATUS        = 16'h0004;
    localparam [15:0] REG_K_BASE_LO     = 16'h0008;
    localparam [15:0] REG_K_BASE_HI     = 16'h000c;
    localparam [15:0] REG_V_BASE_LO     = 16'h0010;
    localparam [15:0] REG_V_BASE_HI     = 16'h0014;
    localparam [15:0] REG_CONTEXT       = 16'h0018;
    localparam [15:0] REG_Q_COUNT       = 16'h001c;
    localparam [15:0] REG_K_SCALE_COUNT = 16'h0020;
    localparam [15:0] REG_V_SCALE_COUNT = 16'h0024;
    localparam [15:0] REG_ERROR         = 16'h0028;
    localparam [15:0] REG_ERROR_INFO    = 16'h002c;
    localparam [15:0] REG_ID            = 16'h0030;
    localparam [15:0] REG_GEOMETRY      = 16'h0034;
    localparam [15:0] REG_SCALE_FMT     = 16'h0038;
    localparam [15:0] REG_PROGRESS      = 16'h003c;
    localparam [15:0] REG_PERF          = 16'h0040;
    localparam [15:0] REG_QK_READ_BEATS = 16'h0044;
    localparam [15:0] REG_QK_BURSTS     = 16'h0048;
    localparam [15:0] REG_QK_AR_STALLS  = 16'h004c;
    localparam [15:0] REG_QK_R_STALLS   = 16'h0050;
    localparam [15:0] REG_QK_META_WAIT  = 16'h0054;
    localparam [15:0] REG_QK_DOT_CYCLES = 16'h0058;
    localparam [15:0] REG_QK_SCORE_COUNT = 16'h005c;
    localparam [15:0] REG_AV_READ_BEATS = 16'h0060;
    localparam [15:0] REG_AV_BURSTS     = 16'h0064;
    localparam [15:0] REG_AV_AR_STALLS  = 16'h0068;
    localparam [15:0] REG_AV_R_STALLS   = 16'h006c;
    localparam [15:0] REG_SAT_COUNT     = 16'h0070;
    localparam [15:0] REG_SINK_CTRL     = 16'h0074;
    localparam [15:0] REG_GENERATION    = 16'h0078;
    localparam [15:0] REG_MULT_STYLE    = 16'h007c;
    localparam [15:0] REG_DENOM0        = 16'h0080;
    localparam [15:0] REG_DENOM1        = 16'h0084;
    localparam [15:0] REG_DENOM2        = 16'h0088;
    localparam [15:0] REG_DENOM3        = 16'h008c;
    localparam [15:0] REG_RECIP0        = 16'h0090;
    localparam [15:0] REG_RECIP1        = 16'h0094;
    localparam [15:0] REG_RECIP2        = 16'h0098;
    localparam [15:0] REG_RECIP3        = 16'h009c;
    localparam [15:0] Q_BASE            = 16'h1000;
    localparam [15:0] K_SCALE_BASE      = 16'h2000;
    localparam [15:0] V_SCALE_BASE      = 16'h2400;
    localparam [15:0] SCORE_RESULT_BASE = 16'h3000;
    localparam [15:0] RESULT_BASE       = 16'h4000;
    localparam [31:0] CORE_ID           = 32'h4b56_0303;
    localparam integer M_AXI_BYTE_SHIFT =
        $clog2(M_AXI_DATA_WIDTH / 8);

    localparam [7:0] ERR_CONTEXT      = 8'h01;
    localparam [7:0] ERR_ADDRESS      = 8'h04;
    localparam [7:0] ERR_SCALE_FORMAT = 8'h22;
    localparam [7:0] ERR_COUNTS       = 8'h25;
    localparam [7:0] ERR_CTRL         = 8'h82;
    localparam [7:0] ERR_BUSY_WRITE   = 8'h83;
    localparam [7:0] ERR_BUSY_START   = 8'h80;
    localparam [7:0] ERR_INTERNAL     = 8'hff;

    localparam [3:0] ST_IDLE        = 4'd0,
                     ST_QK_RUN      = 4'd1,
                     ST_COPY        = 4'd2,
                     ST_PIPE_RUN    = 4'd3,
                     ST_ABORT_DRAIN = 4'd4,
                     ST_ERROR_DRAIN = 4'd5;

    localparam [2:0] ERR_SRC_NONE   = 3'd0,
                     ERR_SRC_CONFIG = 3'd1,
                     ERR_SRC_QK     = 3'd2,
                     ERR_SRC_GUARD  = 3'd3,
                     ERR_SRC_AV     = 3'd4;

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

    reg [3:0] state;
    reg [63:0] k_base_reg, v_base_reg;
    reg [31:0] context_reg, q_count_reg;
    reg [31:0] k_scale_count_reg, v_scale_count_reg;
    reg [4095:0] q_vectors_reg;
    reg [SCALE_WIDTH-1:0] k_scale_mem [0:MAX_CONTEXT-1];
    reg [31:0] generation_reg;
    reg [127:0] active_task_tag;
    reg done_sticky, error_sticky, aborted_sticky, result_valid_sticky;
    reg [7:0] error_code_reg;
    reg [2:0] error_source_reg;
    reg [15:0] error_tag_reg;
    reg sink_ready_reg;
    reg [31:0] total_perf_cycles;
    reg [31:0] av_burst_count;
    reg [15:0] qk_saturation_count;

    wire top_busy = state != ST_IDLE;
    wire top_draining = state == ST_ABORT_DRAIN ||
                        state == ST_ERROR_DRAIN;

    reg qk_start, qk_abort;
    wire qk_meta_req_valid, qk_meta_req_ready;
    wire [6:0] qk_meta_req_token;
    reg qk_meta_rsp_valid;
    wire qk_meta_rsp_ready;
    reg [SCALE_WIDTH-1:0] qk_meta_rsp_scale;
    wire qk_busy, qk_draining, qk_done, qk_aborted, qk_error_valid;
    wire [7:0] qk_error_code;
    wire [15:0] qk_error_tag;
    wire [31:0] qk_perf_cycles, qk_read_beats, qk_burst_count;
    wire [31:0] qk_ar_stalls, qk_r_stalls, qk_meta_wait;
    wire [31:0] qk_dot_cycles, qk_score_count;
    wire [6:0] qk_progress_token;
    wire [1:0] qk_progress_head;
    wire [2:0] qk_progress_slice;
    wire [3:0] qk_progress_state;
    wire qk_score_valid, qk_score_ready;
    wire [1:0] qk_score_row;
    wire [11:0] qk_score_index;
    wire signed [15:0] qk_score;
    wire qk_score_saturated;

    assign qk_meta_req_ready = !qk_meta_rsp_valid;

    kv_v03_raw_k4_qk_engine #(
        .MAX_CONTEXT(MAX_CONTEXT), .AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(M_AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(M_AXI_ID_WIDTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MULT_STYLE(QK_MULT_STYLE), .SCALE_WIDTH(SCALE_WIDTH)
    ) u_qk_engine (
        .clk(clk), .rst_n(rst_n), .start(qk_start), .abort(qk_abort),
        .context_len(context_reg[12:0]),
        .k_base_addr(k_base_reg[M_AXI_ADDR_WIDTH-1:0]),
        .q_vectors(q_vectors_reg),
        .meta_req_valid(qk_meta_req_valid),
        .meta_req_ready(qk_meta_req_ready),
        .meta_req_token(qk_meta_req_token),
        .meta_rsp_valid(qk_meta_rsp_valid),
        .meta_rsp_ready(qk_meta_rsp_ready),
        .meta_scale(qk_meta_rsp_scale),
        .busy(qk_busy), .draining(qk_draining), .done(qk_done),
        .aborted(qk_aborted), .error_valid(qk_error_valid),
        .error_code(qk_error_code), .error_tag(qk_error_tag),
        .perf_cycles(qk_perf_cycles), .read_beats(qk_read_beats),
        .burst_count(qk_burst_count), .ar_stall_cycles(qk_ar_stalls),
        .r_wait_cycles(qk_r_stalls),
        .metadata_wait_cycles(qk_meta_wait),
        .dot_active_cycles(qk_dot_cycles),
        .score_stall_cycles(), .score_count(qk_score_count),
        .progress_token(qk_progress_token),
        .progress_head(qk_progress_head),
        .progress_slice(qk_progress_slice),
        .progress_state(qk_progress_state),
        .score_valid(qk_score_valid), .score_ready(qk_score_ready),
        .score_row(qk_score_row), .score_index(qk_score_index),
        .score(qk_score), .score_saturated(qk_score_saturated),
        .m_axi_arid(m_axi_k_arid), .m_axi_araddr(m_axi_k_araddr),
        .m_axi_arlen(m_axi_k_arlen), .m_axi_arsize(m_axi_k_arsize),
        .m_axi_arburst(m_axi_k_arburst), .m_axi_arlock(m_axi_k_arlock),
        .m_axi_arcache(m_axi_k_arcache), .m_axi_arprot(m_axi_k_arprot),
        .m_axi_arqos(m_axi_k_arqos), .m_axi_arvalid(m_axi_k_arvalid),
        .m_axi_arready(m_axi_k_arready), .m_axi_rid(m_axi_k_rid),
        .m_axi_rdata(m_axi_k_rdata), .m_axi_rresp(m_axi_k_rresp),
        .m_axi_rlast(m_axi_k_rlast), .m_axi_rvalid(m_axi_k_rvalid),
        .m_axi_rready(m_axi_k_rready)
    );

    reg guard_cmd_valid, guard_abort, guard_bank_release;
    wire guard_cmd_ready, guard_score_ready;
    wire guard_commit_valid;
    wire [127:0] guard_commit_task_tag;
    wire [12:0] guard_commit_context_len;
    wire guard_active, guard_busy, guard_aborted, guard_error_valid;
    wire [7:0] guard_error_code;
    wire [127:0] guard_error_task_tag;
    wire [31:0] guard_accepted_count, guard_commit_count;
    wire guard_rd_en;
    wire [1:0] guard_rd_row;
    wire [11:0] guard_rd_index;
    wire guard_rd_valid;
    wire signed [15:0] guard_rd_data;
    reg [9:0] copy_issue_count, copy_write_count;
    reg [1:0] copy_return_row;
    reg [11:0] copy_return_index;
    wire [9:0] copy_total = context_reg[9:0] << 2;

    assign qk_score_ready = guard_score_ready && state == ST_QK_RUN;
    assign guard_rd_en = state == ST_COPY &&
                         copy_issue_count < copy_total;
    assign guard_rd_row = copy_issue_count[1:0];
    assign guard_rd_index = {2'b0, copy_issue_count[9:2]};

    kv_v03_score_row_commit_guard #(
        .MAX_CONTEXT(MAX_CONTEXT), .TAG_WIDTH(128)
    ) u_score_guard (
        .clk(clk), .rst_n(rst_n), .cmd_valid(guard_cmd_valid),
        .cmd_ready(guard_cmd_ready),
        .cmd_context_len(context_reg[12:0]),
        .cmd_task_tag(active_task_tag), .abort(guard_abort),
        .score_valid(qk_score_valid && state == ST_QK_RUN),
        .score_ready(guard_score_ready), .score_row(qk_score_row),
        .score_index(qk_score_index), .score_data(qk_score),
        .score_task_tag(active_task_tag),
        .commit_valid(guard_commit_valid),
        .commit_ready(state == ST_QK_RUN),
        .commit_task_tag(guard_commit_task_tag),
        .commit_context_len(guard_commit_context_len),
        .active(guard_active), .bank_release(guard_bank_release),
        .rd_en(guard_rd_en), .rd_row(guard_rd_row),
        .rd_index(guard_rd_index), .rd_valid(guard_rd_valid),
        .rd_data(guard_rd_data), .busy(guard_busy),
        .aborted(guard_aborted), .aborted_task_tag(),
        .error_valid(guard_error_valid), .error_code(guard_error_code),
        .error_task_tag(guard_error_task_tag),
        .accepted_score_count(guard_accepted_count),
        .commit_count(guard_commit_count)
    );

    reg pipeline_start, pipeline_abort, pipeline_scale_wr_en;
    reg [6:0] pipeline_scale_wr_addr;
    reg [SCALE_WIDTH-1:0] pipeline_scale_wr_data;
    wire pipeline_score_ready, pipeline_scale_ready;
    wire pipeline_result_valid, pipeline_result_ready;
    wire [1:0] pipeline_result_head;
    wire [6:0] pipeline_result_dimension;
    wire signed [47:0] pipeline_result_numerator;
    wire signed [17:0] pipeline_result_code;
    wire pipeline_result_saturated, pipeline_result_last;
    wire pipeline_busy, pipeline_done, pipeline_aborted;
    wire pipeline_error_valid;
    wire [7:0] pipeline_error_code;
    wire [31:0] pipeline_perf_cycles, pipeline_read_beats;
    wire [31:0] pipeline_ar_stalls, pipeline_r_stalls;
    wire [15:0] pipeline_saturation_count;
    wire [111:0] pipeline_denominators;
    wire [51:0] pipeline_reciprocals;
    wire [19:0] pipeline_reciprocal_exponents;
    wire pipeline_score_wr_en = state == ST_COPY && guard_rd_valid;

    assign pipeline_result_ready = sink_ready_reg && state == ST_PIPE_RUN;

    kv_v03_softmax_av_pipeline #(
        .MAX_CONTEXT(MAX_CONTEXT), .SCALE_WIDTH(SCALE_WIDTH),
        .MULT_STYLE(AV_MULT_STYLE), .AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(M_AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(M_AXI_ID_WIDTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_pipeline (
        .clk(clk), .rst_n(rst_n), .start(pipeline_start),
        .abort(pipeline_abort), .context_len(context_reg[12:0]),
        .v_base_addr(v_base_reg[M_AXI_ADDR_WIDTH-1:0]),
        .score_wr_en(pipeline_score_wr_en),
        .score_wr_row(copy_return_row),
        .score_wr_addr(copy_return_index),
        .score_wr_data(guard_rd_data),
        .score_wr_ready(pipeline_score_ready),
        .scale_wr_en(pipeline_scale_wr_en),
        .scale_wr_addr(pipeline_scale_wr_addr),
        .scale_wr_data(pipeline_scale_wr_data),
        .scale_wr_ready(pipeline_scale_ready),
        .result_valid(pipeline_result_valid),
        .result_ready(pipeline_result_ready),
        .result_head(pipeline_result_head),
        .result_dimension(pipeline_result_dimension),
        .result_numerator(pipeline_result_numerator),
        .result_code(pipeline_result_code),
        .result_saturated(pipeline_result_saturated),
        .result_last(pipeline_result_last), .busy(pipeline_busy),
        .done(pipeline_done), .aborted(pipeline_aborted),
        .error_valid(pipeline_error_valid),
        .error_code(pipeline_error_code),
        .perf_cycles(pipeline_perf_cycles),
        .read_beats(pipeline_read_beats),
        .ar_stall_cycles(pipeline_ar_stalls),
        .r_stall_cycles(pipeline_r_stalls),
        .saturation_count(pipeline_saturation_count),
        .denominators(pipeline_denominators),
        .reciprocal_codes(pipeline_reciprocals),
        .reciprocal_exponents(pipeline_reciprocal_exponents),
        .m_axi_arid(m_axi_v_arid), .m_axi_araddr(m_axi_v_araddr),
        .m_axi_arlen(m_axi_v_arlen), .m_axi_arsize(m_axi_v_arsize),
        .m_axi_arburst(m_axi_v_arburst), .m_axi_arlock(m_axi_v_arlock),
        .m_axi_arcache(m_axi_v_arcache), .m_axi_arprot(m_axi_v_arprot),
        .m_axi_arqos(m_axi_v_arqos), .m_axi_arvalid(m_axi_v_arvalid),
        .m_axi_arready(m_axi_v_arready), .m_axi_rid(m_axi_v_rid),
        .m_axi_rdata(m_axi_v_rdata), .m_axi_rresp(m_axi_v_rresp),
        .m_axi_rlast(m_axi_v_rlast), .m_axi_rvalid(m_axi_v_rvalid),
        .m_axi_rready(m_axi_v_rready)
    );

    (* ram_style = "block" *) reg [66:0] result_mem [0:511];
    (* ram_style = "block" *) reg signed [15:0]
        committed_score_mem [0:511];
    wire [8:0] pipeline_result_index =
        {pipeline_result_head, pipeline_result_dimension};
    wire pipeline_result_fire = pipeline_result_valid &&
                                pipeline_result_ready;

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobe;
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobe[byte_index])
                    merge_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    task set_config_error;
        input [7:0] code;
        begin
            error_sticky   <= 1'b1;
            error_code_reg <= code;
            error_source_reg <= ERR_SRC_CONFIG;
            error_tag_reg  <= 16'd0;
            result_valid_sticky <= 1'b0;
        end
    endtask

    integer write_index;
    integer read_index;
    reg [15:0] scale_slot;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold             <= 1'b0;
            w_hold              <= 1'b0;
            awaddr_hold         <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold          <= 32'd0;
            wstrb_hold          <= 4'd0;
            s_axi_bvalid        <= 1'b0;
            s_axi_rvalid        <= 1'b0;
            s_axi_rdata         <= 32'd0;
            state               <= ST_IDLE;
            k_base_reg          <= 64'd0;
            v_base_reg          <= 64'd0;
            context_reg         <= 32'd0;
            q_count_reg         <= 32'd0;
            k_scale_count_reg   <= 32'd0;
            v_scale_count_reg   <= 32'd0;
            q_vectors_reg       <= 4096'd0;
            generation_reg      <= 32'd0;
            active_task_tag     <= 128'd0;
            done_sticky         <= 1'b0;
            error_sticky        <= 1'b0;
            aborted_sticky      <= 1'b0;
            result_valid_sticky <= 1'b0;
            error_code_reg      <= 8'd0;
            error_source_reg    <= ERR_SRC_NONE;
            error_tag_reg       <= 16'd0;
            sink_ready_reg      <= 1'b1;
            total_perf_cycles   <= 32'd0;
            av_burst_count      <= 32'd0;
            qk_saturation_count <= 16'd0;
            qk_start            <= 1'b0;
            qk_abort            <= 1'b0;
            qk_meta_rsp_valid   <= 1'b0;
            qk_meta_rsp_scale   <= {SCALE_WIDTH{1'b0}};
            guard_cmd_valid     <= 1'b0;
            guard_abort         <= 1'b0;
            guard_bank_release  <= 1'b0;
            copy_issue_count    <= 10'd0;
            copy_write_count    <= 10'd0;
            copy_return_row     <= 2'd0;
            copy_return_index   <= 12'd0;
            pipeline_start      <= 1'b0;
            pipeline_abort      <= 1'b0;
            pipeline_scale_wr_en <= 1'b0;
            pipeline_scale_wr_addr <= 7'd0;
            pipeline_scale_wr_data <= {SCALE_WIDTH{1'b0}};
        end else begin
            qk_start             <= 1'b0;
            qk_abort             <= 1'b0;
            guard_cmd_valid      <= 1'b0;
            guard_abort          <= 1'b0;
            guard_bank_release   <= 1'b0;
            pipeline_start       <= 1'b0;
            pipeline_abort       <= 1'b0;
            pipeline_scale_wr_en <= 1'b0;

            if (top_busy)
                total_perf_cycles <= total_perf_cycles + 1'b1;
            if (top_busy && m_axi_v_arvalid && m_axi_v_arready)
                av_burst_count <= av_burst_count + 1'b1;
            if (state == ST_QK_RUN && qk_score_valid && qk_score_ready &&
                qk_score_saturated)
                qk_saturation_count <= qk_saturation_count + 1'b1;

            if (qk_meta_req_valid && qk_meta_req_ready) begin
                qk_meta_rsp_valid <= 1'b1;
                qk_meta_rsp_scale <= k_scale_mem[qk_meta_req_token];
            end
            if (qk_meta_rsp_valid && qk_meta_rsp_ready)
                qk_meta_rsp_valid <= 1'b0;

            if (pipeline_result_fire)
                result_mem[pipeline_result_index] <= {
                    pipeline_result_saturated, pipeline_result_code,
                    pipeline_result_numerator};
            if (pipeline_score_wr_en)
                committed_score_mem[
                    {copy_return_row,copy_return_index[6:0]}] <=
                    guard_rd_data;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (write_commit) begin
                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // A datapath fault has priority over a simultaneous software
            // transaction, and the first typed root cause remains sticky.
            if (!error_sticky && qk_error_valid) begin
                error_sticky        <= 1'b1;
                error_code_reg      <= qk_error_code;
                error_source_reg    <= ERR_SRC_QK;
                error_tag_reg       <= qk_error_tag;
                result_valid_sticky <= 1'b0;
                guard_abort         <= 1'b1;
                pipeline_abort      <= 1'b1;
                state               <= ST_ERROR_DRAIN;
            end else if (!error_sticky && guard_error_valid) begin
                error_sticky        <= 1'b1;
                error_code_reg      <= guard_error_code;
                error_source_reg    <= ERR_SRC_GUARD;
                error_tag_reg       <= guard_error_task_tag[15:0];
                result_valid_sticky <= 1'b0;
                qk_abort            <= 1'b1;
                pipeline_abort      <= 1'b1;
                state               <= ST_ERROR_DRAIN;
            end else if (!error_sticky && pipeline_error_valid) begin
                error_sticky        <= 1'b1;
                error_code_reg      <= pipeline_error_code;
                error_source_reg    <= ERR_SRC_AV;
                error_tag_reg       <= active_task_tag[15:0];
                result_valid_sticky <= 1'b0;
                qk_abort            <= 1'b1;
                guard_abort         <= 1'b1;
                state               <= ST_ERROR_DRAIN;
            end else if (write_commit) begin
                if (wstrb_hold != 4'hf) begin
                    set_config_error(ERR_CTRL);
                    if (top_busy) begin
                        qk_abort       <= 1'b1;
                        guard_abort    <= 1'b1;
                        pipeline_abort <= 1'b1;
                        state          <= ST_ERROR_DRAIN;
                    end
                end else if (top_busy && awaddr_hold != REG_CTRL &&
                             awaddr_hold != REG_SINK_CTRL) begin
                    set_config_error(ERR_BUSY_WRITE);
                    qk_abort       <= 1'b1;
                    guard_abort    <= 1'b1;
                    pipeline_abort <= 1'b1;
                    state          <= ST_ERROR_DRAIN;
                end else begin
                    case (awaddr_hold)
                        REG_CTRL: begin
                            if ((wdata_hold[0] && wdata_hold[1]) ||
                                (wdata_hold[0] && wdata_hold[2]) ||
                                (wdata_hold[1] && wdata_hold[2]) ||
                                |wdata_hold[31:3]) begin
                                set_config_error(ERR_CTRL);
                                if (top_busy) begin
                                    qk_abort       <= 1'b1;
                                    guard_abort    <= 1'b1;
                                    pipeline_abort <= 1'b1;
                                    state          <= ST_ERROR_DRAIN;
                                end
                            end else if (wdata_hold[2]) begin
                                result_valid_sticky <= 1'b0;
                                if (top_busy) begin
                                    qk_abort       <= 1'b1;
                                    guard_abort    <= 1'b1;
                                    pipeline_abort <= 1'b1;
                                    state          <= ST_ABORT_DRAIN;
                                end
                            end else if (wdata_hold[1]) begin
                                result_valid_sticky <= 1'b0;
                                done_sticky         <= 1'b0;
                                aborted_sticky      <= 1'b0;
                                error_sticky        <= 1'b0;
                                error_code_reg      <= 8'd0;
                                error_source_reg    <= ERR_SRC_NONE;
                                error_tag_reg       <= 16'd0;
                                if (top_busy) begin
                                    set_config_error(ERR_BUSY_WRITE);
                                    qk_abort       <= 1'b1;
                                    guard_abort    <= 1'b1;
                                    pipeline_abort <= 1'b1;
                                    state          <= ST_ERROR_DRAIN;
                                end
                            end else if (wdata_hold[0]) begin
                                result_valid_sticky <= 1'b0;
                                done_sticky         <= 1'b0;
                                aborted_sticky      <= 1'b0;
                                error_sticky        <= 1'b0;
                                error_code_reg      <= 8'd0;
                                error_source_reg    <= ERR_SRC_NONE;
                                error_tag_reg       <= 16'd0;
                                if (top_busy) begin
                                    set_config_error(ERR_BUSY_START);
                                    qk_abort       <= 1'b1;
                                    guard_abort    <= 1'b1;
                                    pipeline_abort <= 1'b1;
                                    state          <= ST_ERROR_DRAIN;
                                end else if (context_reg == 0 ||
                                             context_reg > MAX_CONTEXT) begin
                                    set_config_error(ERR_CONTEXT);
                                end else if (q_count_reg != 512 ||
                                    k_scale_count_reg != context_reg ||
                                    v_scale_count_reg != context_reg) begin
                                    set_config_error(ERR_COUNTS);
                                end else if (k_base_reg[63:32] != 0 ||
                                    v_base_reg[63:32] != 0 ||
                                    k_base_reg[M_AXI_BYTE_SHIFT-1:0] != 0 ||
                                    v_base_reg[3:0] != 0 ||
                                    qk_meta_rsp_valid || qk_busy ||
                                    guard_busy || pipeline_busy) begin
                                    set_config_error(ERR_ADDRESS);
                                end else begin
                                    generation_reg <= generation_reg + 1'b1;
                                    active_task_tag <= {
                                        96'd0, generation_reg + 1'b1};
                                    total_perf_cycles   <= 32'd0;
                                    av_burst_count      <= 32'd0;
                                    qk_saturation_count <= 16'd0;
                                    copy_issue_count    <= 10'd0;
                                    copy_write_count    <= 10'd0;
                                    qk_start            <= 1'b1;
                                    guard_cmd_valid     <= 1'b1;
                                    state               <= ST_QK_RUN;
                                end
                            end
                        end
                        REG_K_BASE_LO: begin
                            k_base_reg[31:0] <= merge_wstrb(
                                k_base_reg[31:0], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_K_BASE_HI: begin
                            k_base_reg[63:32] <= merge_wstrb(
                                k_base_reg[63:32], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_V_BASE_LO: begin
                            v_base_reg[31:0] <= merge_wstrb(
                                v_base_reg[31:0], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_V_BASE_HI: begin
                            v_base_reg[63:32] <= merge_wstrb(
                                v_base_reg[63:32], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_CONTEXT: begin
                            context_reg <= merge_wstrb(
                                context_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_Q_COUNT: begin
                            q_count_reg <= merge_wstrb(
                                q_count_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_K_SCALE_COUNT: begin
                            k_scale_count_reg <= merge_wstrb(
                                k_scale_count_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_V_SCALE_COUNT: begin
                            v_scale_count_reg <= merge_wstrb(
                                v_scale_count_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_SINK_CTRL: begin
                            if (|wdata_hold[31:1])
                                set_config_error(ERR_CTRL);
                            else
                                sink_ready_reg <= wdata_hold[0];
                            result_valid_sticky <= 1'b0;
                        end
                        default: begin
                            result_valid_sticky <= 1'b0;
                            if (awaddr_hold >= Q_BASE &&
                                awaddr_hold < Q_BASE + 16'h0800 &&
                                awaddr_hold[1:0] == 0) begin
                                write_index = (awaddr_hold-Q_BASE) >> 2;
                                q_vectors_reg[write_index*8 +: 8] <=
                                    wdata_hold[7:0];
                            end else if (awaddr_hold >= K_SCALE_BASE &&
                                awaddr_hold < K_SCALE_BASE + 16'h0200 &&
                                awaddr_hold[1:0] == 0) begin
                                write_index =
                                    (awaddr_hold-K_SCALE_BASE) >> 2;
                                scale_slot = wdata_hold[15:0];
                                if (SCALE_WIDTH == 12 &&
                                    scale_slot[15:12] != 0)
                                    set_config_error(ERR_SCALE_FORMAT);
                                else
                                    k_scale_mem[write_index] <=
                                        scale_slot[SCALE_WIDTH-1:0];
                            end else if (awaddr_hold >= V_SCALE_BASE &&
                                awaddr_hold < V_SCALE_BASE + 16'h0200 &&
                                awaddr_hold[1:0] == 0) begin
                                write_index =
                                    (awaddr_hold-V_SCALE_BASE) >> 2;
                                scale_slot = wdata_hold[15:0];
                                if (SCALE_WIDTH == 12 &&
                                    scale_slot[15:12] != 0)
                                    set_config_error(ERR_SCALE_FORMAT);
                                else begin
                                    pipeline_scale_wr_en   <= 1'b1;
                                    pipeline_scale_wr_addr <= write_index[6:0];
                                    pipeline_scale_wr_data <=
                                        scale_slot[SCALE_WIDTH-1:0];
                                end
                            end else begin
                                set_config_error(ERR_CTRL);
                            end
                        end
                    endcase
                end
            end else begin
                case (state)
                    ST_QK_RUN: begin
                        if (guard_commit_valid) begin
                            if (guard_commit_task_tag != active_task_tag ||
                                guard_commit_context_len !=
                                context_reg[12:0] || qk_busy) begin
                                error_sticky        <= 1'b1;
                                error_code_reg      <= ERR_INTERNAL;
                                error_source_reg    <= ERR_SRC_GUARD;
                                error_tag_reg       <= active_task_tag[15:0];
                                result_valid_sticky <= 1'b0;
                                qk_abort            <= 1'b1;
                                guard_abort         <= 1'b1;
                                state               <= ST_ERROR_DRAIN;
                            end else begin
                                copy_issue_count <= 10'd0;
                                copy_write_count <= 10'd0;
                                state            <= ST_COPY;
                            end
                        end
                    end

                    ST_COPY: begin
                        if (guard_rd_en) begin
                            copy_return_row   <= guard_rd_row;
                            copy_return_index <= guard_rd_index;
                            copy_issue_count  <= copy_issue_count + 1'b1;
                        end
                        if (guard_rd_valid) begin
                            if (!pipeline_score_ready) begin
                                error_sticky     <= 1'b1;
                                error_code_reg   <= ERR_INTERNAL;
                                error_source_reg <= ERR_SRC_AV;
                                error_tag_reg    <= active_task_tag[15:0];
                                guard_abort      <= 1'b1;
                                pipeline_abort   <= 1'b1;
                                state            <= ST_ERROR_DRAIN;
                            end else if (copy_write_count == copy_total-1) begin
                                copy_write_count   <= copy_write_count + 1'b1;
                                guard_bank_release <= 1'b1;
                                pipeline_start     <= 1'b1;
                                state              <= ST_PIPE_RUN;
                            end else begin
                                copy_write_count <= copy_write_count + 1'b1;
                            end
                        end
                    end

                    ST_PIPE_RUN: begin
                        if (pipeline_done) begin
                            done_sticky         <= 1'b1;
                            result_valid_sticky <= 1'b1;
                            state               <= ST_IDLE;
                        end
                    end

                    ST_ABORT_DRAIN: begin
                        if (!qk_busy && !pipeline_busy && !guard_busy &&
                            !qk_meta_rsp_valid) begin
                            aborted_sticky <= 1'b1;
                            state          <= ST_IDLE;
                        end
                    end

                    ST_ERROR_DRAIN: begin
                        if (!qk_busy && !pipeline_busy && !guard_busy &&
                            !qk_meta_rsp_valid)
                            state <= ST_IDLE;
                    end

                    default: begin
                    end
                endcase
            end

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr)
                    REG_CTRL:          s_axi_rdata <= 32'd0;
                    REG_STATUS:        s_axi_rdata <= {
                        20'd0, state, 2'd0, top_draining,
                        result_valid_sticky, aborted_sticky,
                        error_sticky, done_sticky, top_busy};
                    REG_K_BASE_LO:     s_axi_rdata <= k_base_reg[31:0];
                    REG_K_BASE_HI:     s_axi_rdata <= k_base_reg[63:32];
                    REG_V_BASE_LO:     s_axi_rdata <= v_base_reg[31:0];
                    REG_V_BASE_HI:     s_axi_rdata <= v_base_reg[63:32];
                    REG_CONTEXT:       s_axi_rdata <= context_reg;
                    REG_Q_COUNT:       s_axi_rdata <= q_count_reg;
                    REG_K_SCALE_COUNT: s_axi_rdata <= k_scale_count_reg;
                    REG_V_SCALE_COUNT: s_axi_rdata <= v_scale_count_reg;
                    REG_ERROR:         s_axi_rdata <= {24'd0, error_code_reg};
                    REG_ERROR_INFO:    s_axi_rdata <= {
                        13'd0, error_source_reg, error_tag_reg};
                    REG_ID:            s_axi_rdata <= CORE_ID;
                    REG_GEOMETRY:      s_axi_rdata <=
                        (32'd64 << 24) | (32'd128 << 16) |
                        (32'd18 << 8) | 32'd4;
                    REG_SCALE_FMT:     s_axi_rdata <=
                        SCALE_WIDTH == 12 ? 32'h0000_0c08 :
                                            32'h0000_100b;
                    REG_PROGRESS:      s_axi_rdata <= {
                        6'd0, state, qk_progress_state,
                        qk_progress_slice, qk_progress_head,
                        qk_progress_token, 6'd0};
                    REG_PERF:          s_axi_rdata <= total_perf_cycles;
                    REG_QK_READ_BEATS: s_axi_rdata <= qk_read_beats;
                    REG_QK_BURSTS:     s_axi_rdata <= qk_burst_count;
                    REG_QK_AR_STALLS:  s_axi_rdata <= qk_ar_stalls;
                    REG_QK_R_STALLS:   s_axi_rdata <= qk_r_stalls;
                    REG_QK_META_WAIT:  s_axi_rdata <= qk_meta_wait;
                    REG_QK_DOT_CYCLES: s_axi_rdata <= qk_dot_cycles;
                    REG_QK_SCORE_COUNT:s_axi_rdata <= qk_score_count;
                    REG_AV_READ_BEATS: s_axi_rdata <= pipeline_read_beats;
                    REG_AV_BURSTS:     s_axi_rdata <= av_burst_count;
                    REG_AV_AR_STALLS:  s_axi_rdata <= pipeline_ar_stalls;
                    REG_AV_R_STALLS:   s_axi_rdata <= pipeline_r_stalls;
                    REG_SAT_COUNT:     s_axi_rdata <= {
                        pipeline_saturation_count, qk_saturation_count};
                    REG_SINK_CTRL:     s_axi_rdata <= {31'd0,sink_ready_reg};
                    REG_GENERATION:    s_axi_rdata <= generation_reg;
                    REG_MULT_STYLE:    s_axi_rdata <= {
                        24'd0, AV_MULT_STYLE[3:0], QK_MULT_STYLE[3:0]};
                    REG_DENOM0:        s_axi_rdata <= {
                        4'd0, pipeline_denominators[27:0]};
                    REG_DENOM1:        s_axi_rdata <= {
                        4'd0, pipeline_denominators[55:28]};
                    REG_DENOM2:        s_axi_rdata <= {
                        4'd0, pipeline_denominators[83:56]};
                    REG_DENOM3:        s_axi_rdata <= {
                        4'd0, pipeline_denominators[111:84]};
                    REG_RECIP0:        s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[4:0],
                        pipeline_reciprocals[12:0]};
                    REG_RECIP1:        s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[9:5],
                        pipeline_reciprocals[25:13]};
                    REG_RECIP2:        s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[14:10],
                        pipeline_reciprocals[38:26]};
                    REG_RECIP3:        s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[19:15],
                        pipeline_reciprocals[51:39]};
                    default: begin
                        if (s_axi_araddr >= SCORE_RESULT_BASE &&
                            s_axi_araddr < SCORE_RESULT_BASE + 16'h0800 &&
                            s_axi_araddr[1:0] == 0) begin
                            read_index =
                                (s_axi_araddr-SCORE_RESULT_BASE) >> 2;
                            if (!result_valid_sticky ||
                                (read_index % MAX_CONTEXT) >= context_reg)
                                s_axi_rdata <= 32'd0;
                            else
                                s_axi_rdata <= {{16{
                                    committed_score_mem[read_index][15]}},
                                    committed_score_mem[read_index]};
                        end else if (s_axi_araddr >= RESULT_BASE &&
                            s_axi_araddr < RESULT_BASE + 16'h2000) begin
                            read_index = (s_axi_araddr-RESULT_BASE) >> 4;
                            if (!result_valid_sticky)
                                s_axi_rdata <= 32'd0;
                            else case (s_axi_araddr[3:2])
                                2'd0: s_axi_rdata <=
                                    result_mem[read_index][31:0];
                                2'd1: s_axi_rdata <=
                                    {{16{result_mem[read_index][47]}},
                                      result_mem[read_index][47:32]};
                                2'd2: s_axi_rdata <= {
                                    result_mem[read_index][66], 13'd0,
                                    result_mem[read_index][65:48]};
                                default: s_axi_rdata <= 32'd0;
                            endcase
                        end else begin
                            s_axi_rdata <= 32'd0;
                        end
                    end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    wire unused = ^s_axi_awprot ^ ^s_axi_arprot ^ qk_done ^ qk_aborted ^
        qk_draining ^ qk_perf_cycles ^ guard_cmd_ready ^ guard_active ^
        guard_aborted ^ guard_accepted_count ^ guard_commit_count ^
        pipeline_scale_ready ^ pipeline_result_last ^ pipeline_aborted;

`ifndef SYNTHESIS
    initial begin
        if (C_S_AXI_DATA_WIDTH != 32 || C_S_AXI_ADDR_WIDTH != 16)
            $error("axi_kvq_raw_full_diag requires AXI-Lite 32/16");
        if (M_AXI_ADDR_WIDTH != 32 ||
            (M_AXI_DATA_WIDTH != 64 && M_AXI_DATA_WIDTH != 128) ||
            M_AXI_ID_WIDTH != 1)
            $error("axi_kvq_raw_full_diag requires two AXI4 32/(64|128)/1 masters");
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("axi_kvq_raw_full_diag MAX_CONTEXT must be 1..128");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("axi_kvq_raw_full_diag SCALE_WIDTH must be 12 or 16");
        if (QK_MULT_STYLE < 0 || QK_MULT_STYLE > 2 ||
            AV_MULT_STYLE < 0 || AV_MULT_STYLE > 2)
            $error("axi_kvq_raw_full_diag multiply styles must be 0..2");
    end
`endif
endmodule

`default_nettype wire
