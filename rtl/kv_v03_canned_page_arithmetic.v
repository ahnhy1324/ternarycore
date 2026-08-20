// kv_v03_canned_page_arithmetic.v -- checkpoint-independent canned GQA4 arithmetic.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// This block deliberately starts at the published-page boundary.  K and V
// storage remain owned by the two typed decode lane banks; only their
// synchronous P16 and token-scale ports are consumed here.
module kv_v03_canned_page_arithmetic #(
    parameter integer SCALE_BITS = 12,
    parameter integer MAX_CONTEXT = 128,
    parameter integer MULT_STYLE = 2,
    parameter integer QK_MULT_STYLE = MULT_STYLE,
    parameter integer AV_MULT_STYLE = MULT_STYLE
) (
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       start_valid,
    output wire                       start_ready,
    input  wire [12:0]                context_len,
    input  wire                       abort,
    input  wire                       clear_fault,
    output wire                       clear_ready,
    input  wire                       clear_counters,

    // Stable, row-major 4x128 signed-INT8 canned queries are written while
    // idle and retained across transactions and fault clears.
    input  wire                       q_wr_en,
    input  wire [1:0]                 q_wr_row,
    input  wire [6:0]                 q_wr_addr,
    input  wire signed [7:0]          q_wr_data,
    output wire                       queries_ready,

    // Published K page descriptor from one typed decode lane bank.
    input  wire                       k_page_active,
    input  wire [63:0]                k_task_tag,
    input  wire [15:0]                k_epoch,
    input  wire [4:0]                 k_page_index,
    input  wire                       k_stream_is_v,
    input  wire                       k_raw_mode,
    input  wire [14:0]                k_expected_symbols,
    input  wire [7:0]                 k_token_count,
    input  wire [8:0]                 k_scale_slice_bytes,
    output wire                       k_p16_rd_en,
    output wire [9:0]                 k_p16_rd_addr,
    input  wire                       k_p16_rd_valid,
    input  wire [79:0]                k_p16_rd_codes,
    output wire                       k_scale_rd_en,
    output wire [6:0]                 k_scale_rd_addr,
    input  wire                       k_scale_rd_valid,
    input  wire [SCALE_BITS-1:0]      k_scale_rd_data,
    output reg                        k_page_release,

    // Published V page descriptor from the independent V lane bank.
    input  wire                       v_page_active,
    input  wire [63:0]                v_task_tag,
    input  wire [15:0]                v_epoch,
    input  wire [4:0]                 v_page_index,
    input  wire                       v_stream_is_v,
    input  wire                       v_raw_mode,
    input  wire [14:0]                v_expected_symbols,
    input  wire [7:0]                 v_token_count,
    input  wire [8:0]                 v_scale_slice_bytes,
    output wire                       v_p16_rd_en,
    output wire [9:0]                 v_p16_rd_addr,
    input  wire                       v_p16_rd_valid,
    input  wire [79:0]                v_p16_rd_codes,
    output wire                       v_scale_rd_en,
    output wire [6:0]                 v_scale_rd_addr,
    input  wire                       v_scale_rd_valid,
    input  wire [SCALE_BITS-1:0]      v_scale_rd_data,
    output reg                        v_page_release,

    // Tentative Q8.8 scores are externally visible only on the same atomic
    // handshake that enters the all-or-nothing score-row commit guard.
    output wire                       score_valid,
    input  wire                       score_ready,
    output wire [1:0]                 score_row,
    output wire [11:0]                score_index,
    output wire signed [15:0]         score_data,
    output wire                       score_saturated,

    // One normalized result per head/dimension, paired with the exact signed
    // 48-bit numerator that produced it.
    output wire                       result_valid,
    input  wire                       result_ready,
    output wire [1:0]                 result_head,
    output wire [6:0]                 result_dimension,
    output wire signed [47:0]         result_numerator,
    output wire signed [17:0]         result_normalized,
    output wire                       result_saturated,
    output wire                       result_last,
    output wire [63:0]                result_k_task_tag,
    output wire [63:0]                result_v_task_tag,
    output wire [15:0]                result_epoch,
    output wire [4:0]                 result_page_index,
    output wire                       result_k_raw_mode,
    output wire                       result_v_raw_mode,

    // Four row summaries, packed low-row first.
    output wire [111:0]               denominators,
    output wire [51:0]                reciprocal_codes,
    output wire [19:0]                reciprocal_exponents,

    output wire                       busy,
    output wire                       draining,
    output reg                        done,
    output reg                        aborted,
    output reg                        sticky_error,
    output reg  [7:0]                 sticky_error_code,
    output reg  [7:0]                 sticky_error_subcode,
    output reg  [63:0]                sticky_k_task_tag,
    output reg  [63:0]                sticky_v_task_tag,
    output reg  [15:0]                sticky_epoch,
    output reg  [4:0]                 sticky_page_index,
    output reg                        row_abort,

    output wire [4:0]                 progress_state,
    output wire [6:0]                 progress_token,
    output wire [1:0]                 progress_head,
    output wire [2:0]                 progress_group,
    output reg  [31:0]                perf_cycles,
    output reg  [31:0]                k_p16_read_requests,
    output reg  [31:0]                k_scale_read_requests,
    output reg  [31:0]                v_p16_read_requests,
    output reg  [31:0]                v_scale_read_requests,
    output reg  [31:0]                k_read_starvation_cycles,
    output reg  [31:0]                v_read_starvation_cycles,
    output reg  [31:0]                k_starvation_high_water,
    output reg  [31:0]                v_starvation_high_water,
    output reg  [1:0]                 read_outstanding_high_water,
    output reg  [31:0]                arithmetic_active_cycles,
    output reg  [31:0]                score_stall_cycles,
    output reg  [31:0]                result_stall_cycles,
    output reg  [31:0]                score_count,
    output reg  [31:0]                result_count
);
    localparam integer SCALE_FRACTION_BITS =
        (SCALE_BITS == 16) ? 11 : 8;

    localparam [4:0] ST_IDLE          = 5'd0,
                     ST_GUARD_CMD     = 5'd1,
                     ST_K_SCALE_REQ   = 5'd2,
                     ST_K_SCALE_WAIT  = 5'd3,
                     ST_K_P16_REQ     = 5'd4,
                     ST_K_P16_WAIT    = 5'd5,
                     ST_QK_FEED       = 5'd6,
                     ST_QK_WAIT       = 5'd7,
                     ST_SCORE_WAIT    = 5'd8,
                     ST_GUARD_COMMIT  = 5'd9,
                     ST_COPY_REQ      = 5'd10,
                     ST_COPY_WAIT     = 5'd11,
                     ST_SOFT_START    = 5'd12,
                     ST_SOFT_RUN      = 5'd13,
                     ST_AV_START      = 5'd14,
                     ST_V_SCALE_REQ   = 5'd15,
                     ST_V_SCALE_WAIT  = 5'd16,
                     ST_V_P16_REQ     = 5'd17,
                     ST_V_P16_WAIT    = 5'd18,
                     ST_AV_FEED       = 5'd19,
                     ST_NORM_START    = 5'd20,
                     ST_AV_OUTPUT     = 5'd21,
                     ST_FAULT_DRAIN   = 5'd22,
                     ST_FAULT         = 5'd23;

    localparam [7:0] ERR_DESCRIPTOR = 8'h01,
                     ERR_TAG        = 8'h02,
                     ERR_EPOCH      = 8'h03,
                     ERR_SCALE      = 8'h04,
                     ERR_READ_PORT  = 8'h05,
                     ERR_SCORE      = 8'h06,
                     ERR_SOFTMAX    = 8'h07,
                     ERR_AV         = 8'h08,
                     ERR_NORMALIZE  = 8'h09,
                     ERR_ABORT      = 8'h0a,
                     ERR_OWNERSHIP  = 8'h0b,
                     ERR_INTERNAL   = 8'h0c;

    reg [4:0] state;
    reg [12:0] context_reg;
    reg [63:0] k_tag_reg, v_tag_reg;
    reg [15:0] epoch_reg;
    reg [4:0] page_reg;
    reg k_raw_reg, v_raw_reg;
    reg k_owned, v_owned;

    reg signed [7:0] q_mem [0:3][0:127];
    reg [127:0] q_valid_bits [0:3];
    reg [9:0] q_loaded_count;
    wire q_write_allowed = q_wr_en && state == ST_IDLE && !sticky_error;
    assign queries_ready = q_loaded_count == 10'd512;

    reg [6:0] token_reg;
    reg [1:0] head_reg;
    reg [2:0] group_reg;
    reg [SCALE_BITS-1:0] k_scale_hold, v_scale_hold;
    reg [79:0] k_codes_hold, v_codes_hold;
    reg k_outstanding, v_outstanding;
    reg k_outstanding_scale, v_outstanding_scale;

    reg [1:0] copy_row;
    reg [6:0] copy_index;
    reg [1:0] soft_row_reg;
    reg [6:0] soft_expected_index;
    reg [15:0] exp_mem [0:3][0:127];
    reg [27:0] denominator_mem [0:3];
    reg [12:0] reciprocal_mem [0:3];
    reg [4:0] reciprocal_exponent_mem [0:3];

    reg [1:0] norm_head_reg;
    reg [2:0] expected_av_group;
    reg norm_inputs_complete;
    reg beat_active;
    reg [2:0] beat_group;
    reg [3:0] beat_lane;
    reg [767:0] beat_numerators;
    reg signed [47:0] pending_numerator;

    reg [31:0] k_wait_streak, v_wait_streak;

    wire [20:0] requested_scale_bits = context_len * SCALE_BITS;
    wire [8:0] requested_scale_bytes = (requested_scale_bits + 7) >> 3;
    wire [14:0] requested_symbols = {2'b0, context_len} << 7;
    wire tag_relation_ok =
        k_task_tag[63:16] == v_task_tag[63:16] &&
        k_task_tag[7:0] == v_task_tag[7:0];
    wire descriptor_ok = k_page_active && v_page_active &&
        !k_stream_is_v && v_stream_is_v && tag_relation_ok &&
        k_epoch == v_epoch && k_page_index == v_page_index &&
        context_len != 0 && context_len <= MAX_CONTEXT &&
        k_token_count == context_len[7:0] &&
        v_token_count == context_len[7:0] &&
        k_expected_symbols == requested_symbols &&
        v_expected_symbols == requested_symbols &&
        k_scale_slice_bytes == requested_scale_bytes &&
        v_scale_slice_bytes == requested_scale_bytes;

    assign start_ready = state == ST_IDLE && !sticky_error && queries_ready;
    wire start_fire = start_valid && start_ready;
    wire descriptor_fault = start_fire && !descriptor_ok;
    wire abort_fault = abort && state != ST_IDLE &&
                       state != ST_FAULT_DRAIN && state != ST_FAULT;

    // Published descriptors must remain stable until release.  This detects
    // tag/epoch/ownership corruption even after scores have become visible.
    wire ownership_checked = state != ST_IDLE && state != ST_FAULT_DRAIN &&
                             state != ST_FAULT;
    wire ownership_fault = ownership_checked &&
        (!k_page_active || !v_page_active ||
         k_task_tag != k_tag_reg || v_task_tag != v_tag_reg ||
         k_epoch != epoch_reg || v_epoch != epoch_reg ||
         k_page_index != page_reg || v_page_index != page_reg ||
         k_stream_is_v || !v_stream_is_v ||
         k_raw_mode != k_raw_reg || v_raw_mode != v_raw_reg ||
         k_token_count != context_reg[7:0] ||
         v_token_count != context_reg[7:0]);

    assign k_scale_rd_en = state == ST_K_SCALE_REQ && !abort && !fault_event;
    assign k_scale_rd_addr = token_reg;
    assign k_p16_rd_en = state == ST_K_P16_REQ && !abort && !fault_event;
    assign k_p16_rd_addr = {token_reg, group_reg};
    assign v_scale_rd_en = state == ST_V_SCALE_REQ && !abort && !fault_event;
    assign v_scale_rd_addr = token_reg;
    assign v_p16_rd_en = state == ST_V_P16_REQ && !abort && !fault_event;
    assign v_p16_rd_addr = {token_reg, group_reg};

    wire unexpected_k_response = ownership_checked &&
        ((k_scale_rd_valid && state != ST_K_SCALE_WAIT) ||
         (k_p16_rd_valid && state != ST_K_P16_WAIT));
    wire unexpected_v_response = ownership_checked &&
        ((v_scale_rd_valid && state != ST_V_SCALE_WAIT) ||
         (v_p16_rd_valid && state != ST_V_P16_WAIT));
    wire zero_scale_fault =
        (state == ST_K_SCALE_WAIT && k_scale_rd_valid &&
         k_scale_rd_data == {SCALE_BITS{1'b0}}) ||
        (state == ST_V_SCALE_WAIT && v_scale_rd_valid &&
         v_scale_rd_data == {SCALE_BITS{1'b0}});

    // QK datapath.  The lane-bank K values are signed-extended P16 codes;
    // their low four bits are the exact K4 representation expected here.
    reg [127:0] qk_q_lanes;
    reg [63:0] qk_k_lanes;
    integer lane_i;
    always @* begin
        qk_q_lanes = 128'b0;
        qk_k_lanes = 64'b0;
        for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1) begin
            qk_q_lanes[(lane_i*8) +: 8] =
                q_mem[head_reg][(group_reg*16)+lane_i];
            qk_k_lanes[(lane_i*4) +: 4] =
                k_codes_hold[(lane_i*5) +: 4];
        end
    end

    wire qk_in_valid = state == ST_QK_FEED;
    wire qk_out_valid;
    wire signed [31:0] qk_result;
    wire qk_invalid;
    wire core_abort;
    qk_group_dot #(
        .GROUP_SIZE(128), .Q_WIDTH(8), .K_WIDTH(4),
        .SCALE_WIDTH(SCALE_BITS), .ACC_WIDTH(32),
        .MULT_STYLE(QK_MULT_STYLE)
    ) u_qk (
        .clk(clk), .rst_n(rst_n), .abort(core_abort),
        .in_valid(qk_in_valid), .vector_start(group_reg == 0),
        .vector_last(group_reg == 7), .q_lanes(qk_q_lanes),
        .k_lanes(qk_k_lanes), .group_scale(k_scale_hold),
        .out_valid(qk_out_valid), .result(qk_result),
        .invalid_code(qk_invalid)
    );

    wire quant_in_ready, quant_out_valid, quant_out_ready;
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
        .in_valid(state == ST_QK_WAIT && qk_out_valid && !qk_invalid),
        .in_ready(quant_in_ready), .in_row(head_reg),
        .in_index({5'b0, token_reg}), .in_score(qk_result),
        .out_valid(quant_out_valid), .out_ready(quant_out_ready),
        .out_row(quant_out_row), .out_index(quant_out_index),
        .out_score(quant_out_score),
        .out_saturated(quant_out_saturated)
    );

    wire guard_cmd_ready, guard_score_ready, guard_commit_valid;
    wire [127:0] guard_commit_tag;
    wire [12:0] guard_commit_context;
    wire guard_active, guard_busy, guard_aborted, guard_error_valid;
    wire [7:0] guard_error_code;
    wire guard_rd_valid;
    wire signed [15:0] guard_rd_data;
    reg guard_release;
    wire [127:0] transaction_tag = {k_tag_reg, v_tag_reg};
    wire guard_abort = core_abort;
    wire guard_score_valid = state == ST_SCORE_WAIT && quant_out_valid &&
                             score_ready && !core_abort;
    assign score_valid = state == ST_SCORE_WAIT && quant_out_valid &&
                         guard_score_ready && !core_abort;
    assign score_row = quant_out_row;
    assign score_index = quant_out_index;
    assign score_data = quant_out_score;
    assign score_saturated = quant_out_saturated;
    assign quant_out_ready = state == ST_SCORE_WAIT && guard_score_ready &&
                             score_ready && !core_abort;

    wire guard_rd_en = state == ST_COPY_REQ;
    kv_v03_score_row_commit_guard #(
        .MAX_CONTEXT(MAX_CONTEXT), .TAG_WIDTH(128)
    ) u_score_guard (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(state == ST_GUARD_CMD), .cmd_ready(guard_cmd_ready),
        .cmd_context_len(context_reg), .cmd_task_tag(transaction_tag),
        .abort(guard_abort),
        .score_valid(guard_score_valid), .score_ready(guard_score_ready),
        .score_row(quant_out_row), .score_index(quant_out_index),
        .score_data(quant_out_score), .score_task_tag(transaction_tag),
        .commit_valid(guard_commit_valid),
        .commit_ready(state == ST_GUARD_COMMIT),
        .commit_task_tag(guard_commit_tag),
        .commit_context_len(guard_commit_context),
        .active(guard_active), .bank_release(guard_release),
        .rd_en(guard_rd_en), .rd_row(copy_row),
        .rd_index({5'b0, copy_index}), .rd_valid(guard_rd_valid),
        .rd_data(guard_rd_data), .busy(guard_busy),
        .aborted(guard_aborted), .aborted_task_tag(),
        .error_valid(guard_error_valid), .error_code(guard_error_code),
        .error_task_tag(), .accepted_score_count(), .commit_count()
    );

    wire soft_start_normal = state == ST_SOFT_START;
    wire soft_start;
    wire soft_exp_valid, soft_exp_ready, soft_exp_last;
    wire [11:0] soft_exp_index;
    wire [15:0] soft_exp_code;
    wire soft_busy, soft_quiescent, soft_done, soft_error_valid;
    wire [7:0] soft_error_code;
    wire [27:0] soft_denominator;
    wire [12:0] soft_reciprocal;
    wire [4:0] soft_reciprocal_exponent;
    wire soft_score_wr_en = state == ST_COPY_WAIT && guard_rd_valid;
    assign soft_exp_ready = state == ST_SOFT_RUN && !core_abort;
    kv_v03_softmax_engine u_softmax (
        .clk(clk), .rst_n(rst_n),
        .score_wr_en(soft_score_wr_en), .score_wr_row(copy_row),
        .score_wr_addr({5'b0, copy_index}), .score_wr_data(guard_rd_data),
        .start(soft_start), .score_row(soft_row_reg),
        .context_len(context_reg), .exp_valid(soft_exp_valid),
        .exp_ready(soft_exp_ready), .exp_index(soft_exp_index),
        .exp_code(soft_exp_code), .exp_last(soft_exp_last),
        .busy(soft_busy), .quiescent(soft_quiescent), .done(soft_done),
        .maximum_score(), .denominator(soft_denominator),
        .reciprocal_code(soft_reciprocal),
        .reciprocal_exponent(soft_reciprocal_exponent),
        .underflow_count(), .error_valid(soft_error_valid),
        .error_code(soft_error_code)
    );

    wire av_start_normal = state == ST_AV_START;
    wire av_start;
    wire av_in_valid = state == ST_AV_FEED;
    wire av_in_ready;
    wire av_out_valid, av_out_ready, av_out_last;
    wire [1:0] av_out_head;
    wire [2:0] av_out_group;
    wire [767:0] av_out_numerators;
    wire av_busy, av_done, av_error_valid;
    wire [7:0] av_error_code;
    kv_v03_av_accumulator #(
        .MULT_STYLE(AV_MULT_STYLE), .SCALE_WIDTH(SCALE_BITS)
    ) u_av (
        .clk(clk), .rst_n(rst_n), .start(av_start),
        .context_len(context_reg), .in_valid(av_in_valid),
        .in_ready(av_in_ready), .in_head(head_reg),
        .in_group(group_reg), .in_exp_code(exp_mem[head_reg][token_reg]),
        .in_v_scale(v_scale_hold), .in_v_codes(v_codes_hold),
        .out_valid(av_out_valid), .out_ready(av_out_ready),
        .out_head(av_out_head), .out_group(av_out_group),
        .out_numerators(av_out_numerators), .out_last(av_out_last),
        .busy(av_busy), .done(av_done), .error_valid(av_error_valid),
        .error_code(av_error_code)
    );

    wire norm_start_normal = state == ST_NORM_START;
    wire norm_abort;
    wire norm_num_valid, norm_num_ready, norm_num_last;
    wire [6:0] norm_num_index;
    wire signed [47:0] norm_num_data;
    wire norm_output_valid, norm_output_ready, norm_output_last;
    wire [6:0] norm_output_index;
    wire signed [17:0] norm_output_code;
    wire norm_output_saturated;
    wire norm_busy, norm_done, norm_aborted, norm_error_valid;
    wire [7:0] norm_error_code;
    kv_v03_av_normalizer #(
        .HEAD_DIM(128), .INDEX_WIDTH(7), .OUT_WIDTH(18),
        .OUT_FRACTION_BITS(8),
        .SCALE_FRACTION_BITS(SCALE_FRACTION_BITS)
    ) u_normalizer (
        .clk(clk), .rst_n(rst_n), .start(norm_start_normal),
        .abort(norm_abort), .reciprocal_code(reciprocal_mem[norm_head_reg]),
        .reciprocal_exponent(reciprocal_exponent_mem[norm_head_reg]),
        .numerator_valid(norm_num_valid), .numerator_ready(norm_num_ready),
        .numerator_index(norm_num_index), .numerator(norm_num_data),
        .numerator_last(norm_num_last), .output_valid(norm_output_valid),
        .output_ready(norm_output_ready), .output_index(norm_output_index),
        .output_code(norm_output_code),
        .output_saturated(norm_output_saturated),
        .output_last(norm_output_last), .busy(norm_busy), .done(norm_done),
        .aborted(norm_aborted), .saturation_count(),
        .error_valid(norm_error_valid), .error_code(norm_error_code)
    );

    wire av_schedule_fault = state == ST_AV_OUTPUT && av_out_valid &&
        !beat_active && !norm_inputs_complete &&
        (av_out_head != norm_head_reg || av_out_group != expected_av_group);
    assign av_out_ready = state == ST_AV_OUTPUT && !beat_active &&
        !norm_inputs_complete &&
        av_out_head == norm_head_reg && av_out_group == expected_av_group &&
        !core_abort;
    assign norm_num_valid = state == ST_AV_OUTPUT && beat_active &&
                            !core_abort;
    assign norm_num_index = {beat_group, beat_lane};
    assign norm_num_data =
        beat_numerators[(beat_lane*48) +: 48];
    assign norm_num_last = beat_group == 7 && beat_lane == 15;
    assign norm_output_ready = result_ready && state == ST_AV_OUTPUT &&
                               !core_abort;

    assign result_valid = state == ST_AV_OUTPUT && norm_output_valid &&
                          !core_abort;
    assign result_head = norm_head_reg;
    assign result_dimension = norm_output_index;
    assign result_numerator = pending_numerator;
    assign result_normalized = norm_output_code;
    assign result_saturated = norm_output_saturated;
    assign result_last = norm_head_reg == 3 && norm_output_last;
    assign result_k_task_tag = k_tag_reg;
    assign result_v_task_tag = v_tag_reg;
    assign result_epoch = epoch_reg;
    assign result_page_index = page_reg;
    assign result_k_raw_mode = k_raw_reg;
    assign result_v_raw_mode = v_raw_reg;

    genvar summary_head;
    generate
        for (summary_head = 0; summary_head < 4;
             summary_head = summary_head + 1) begin : g_summary
            assign denominators[(summary_head*28) +: 28] =
                denominator_mem[summary_head];
            assign reciprocal_codes[(summary_head*13) +: 13] =
                reciprocal_mem[summary_head];
            assign reciprocal_exponents[(summary_head*5) +: 5] =
                reciprocal_exponent_mem[summary_head];
        end
    endgenerate

    // Fault selection is kept combinational so every child sees abort/cancel
    // on the exact edge on which the controller hides its public outputs.
    reg runtime_fault;
    reg [7:0] runtime_fault_code, runtime_fault_subcode;
    always @* begin
        runtime_fault = 1'b0;
        runtime_fault_code = 8'b0;
        runtime_fault_subcode = 8'b0;
        if (ownership_fault) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_OWNERSHIP;
            runtime_fault_subcode = 8'h01;
        end else if (unexpected_k_response || unexpected_v_response) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_READ_PORT;
            runtime_fault_subcode = unexpected_v_response ? 8'h02 : 8'h01;
        end else if (zero_scale_fault) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_SCALE;
            runtime_fault_subcode = (state == ST_V_SCALE_WAIT) ? 8'h02 : 8'h01;
        end else if (state == ST_QK_WAIT && qk_out_valid && qk_invalid) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_SCORE;
            runtime_fault_subcode = 8'h01;
        end else if (state == ST_QK_WAIT && qk_out_valid && !quant_in_ready) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_INTERNAL;
            runtime_fault_subcode = 8'h11;
        end else if (guard_error_valid) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_SCORE;
            runtime_fault_subcode = guard_error_code;
        end else if (soft_error_valid) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_SOFTMAX;
            runtime_fault_subcode = soft_error_code;
        end else if (av_error_valid) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_AV;
            runtime_fault_subcode = av_error_code;
        end else if (norm_error_valid) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_NORMALIZE;
            runtime_fault_subcode = norm_error_code;
        end else if (state == ST_SOFT_RUN && soft_exp_valid &&
                     (soft_exp_index[6:0] != soft_expected_index ||
                      soft_exp_index >= context_reg ||
                      soft_exp_last !=
                        (soft_exp_index == context_reg-1'b1))) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_SOFTMAX;
            runtime_fault_subcode = 8'h20;
        end else if (av_schedule_fault) begin
            runtime_fault = 1'b1;
            runtime_fault_code = ERR_AV;
            runtime_fault_subcode = 8'h20;
        end
    end

    wire fault_event = descriptor_fault || abort_fault ||
                       (runtime_fault && ownership_checked);
    assign core_abort = fault_event;
    assign norm_abort = fault_event;
    assign soft_start = soft_start_normal || (fault_event && soft_busy);
    assign av_start = av_start_normal || (fault_event && av_busy);

    assign busy = state != ST_IDLE && state != ST_FAULT;
    assign draining = state == ST_FAULT_DRAIN;
    assign clear_ready = state == ST_FAULT && !guard_busy && !soft_busy &&
                         soft_quiescent && !av_busy && !norm_busy &&
                         !k_outstanding && !v_outstanding;
    assign progress_state = state;
    assign progress_token = token_reg;
    assign progress_head = (state == ST_AV_OUTPUT || state == ST_NORM_START) ?
                           norm_head_reg : head_reg;
    assign progress_group = group_reg;

    wire score_fire = score_valid && score_ready;
    wire result_fire = result_valid && result_ready;
    wire norm_num_fire = norm_num_valid && norm_num_ready;
    wire av_in_fire = av_in_valid && av_in_ready;
    wire soft_exp_fire = soft_exp_valid && soft_exp_ready;

    integer reset_row;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            context_reg <= 13'd0;
            k_tag_reg <= 64'd0;
            v_tag_reg <= 64'd0;
            epoch_reg <= 16'd0;
            page_reg <= 5'd0;
            k_raw_reg <= 1'b0;
            v_raw_reg <= 1'b0;
            k_owned <= 1'b0;
            v_owned <= 1'b0;
            q_loaded_count <= 10'd0;
            for (reset_row = 0; reset_row < 4; reset_row = reset_row + 1)
                q_valid_bits[reset_row] <= 128'd0;
            token_reg <= 7'd0;
            head_reg <= 2'd0;
            group_reg <= 3'd0;
            k_scale_hold <= {SCALE_BITS{1'b0}};
            v_scale_hold <= {SCALE_BITS{1'b0}};
            k_codes_hold <= 80'd0;
            v_codes_hold <= 80'd0;
            k_outstanding <= 1'b0;
            v_outstanding <= 1'b0;
            k_outstanding_scale <= 1'b0;
            v_outstanding_scale <= 1'b0;
            copy_row <= 2'd0;
            copy_index <= 7'd0;
            soft_row_reg <= 2'd0;
            soft_expected_index <= 7'd0;
            norm_head_reg <= 2'd0;
            expected_av_group <= 3'd0;
            norm_inputs_complete <= 1'b0;
            beat_active <= 1'b0;
            beat_group <= 3'd0;
            beat_lane <= 4'd0;
            beat_numerators <= 768'd0;
            pending_numerator <= 48'sd0;
            guard_release <= 1'b0;
            k_page_release <= 1'b0;
            v_page_release <= 1'b0;
            done <= 1'b0;
            aborted <= 1'b0;
            sticky_error <= 1'b0;
            sticky_error_code <= 8'd0;
            sticky_error_subcode <= 8'd0;
            sticky_k_task_tag <= 64'd0;
            sticky_v_task_tag <= 64'd0;
            sticky_epoch <= 16'd0;
            sticky_page_index <= 5'd0;
            row_abort <= 1'b0;
            perf_cycles <= 32'd0;
            k_p16_read_requests <= 32'd0;
            k_scale_read_requests <= 32'd0;
            v_p16_read_requests <= 32'd0;
            v_scale_read_requests <= 32'd0;
            k_read_starvation_cycles <= 32'd0;
            v_read_starvation_cycles <= 32'd0;
            k_starvation_high_water <= 32'd0;
            v_starvation_high_water <= 32'd0;
            read_outstanding_high_water <= 2'd0;
            arithmetic_active_cycles <= 32'd0;
            score_stall_cycles <= 32'd0;
            result_stall_cycles <= 32'd0;
            score_count <= 32'd0;
            result_count <= 32'd0;
            k_wait_streak <= 32'd0;
            v_wait_streak <= 32'd0;
        end else begin
            done <= 1'b0;
            aborted <= 1'b0;
            row_abort <= 1'b0;
            guard_release <= 1'b0;
            k_page_release <= 1'b0;
            v_page_release <= 1'b0;

            if (q_write_allowed) begin
                q_mem[q_wr_row][q_wr_addr] <= q_wr_data;
                if (!q_valid_bits[q_wr_row][q_wr_addr]) begin
                    q_valid_bits[q_wr_row][q_wr_addr] <= 1'b1;
                    q_loaded_count <= q_loaded_count + 1'b1;
                end
            end

            if (clear_counters) begin
                perf_cycles <= 32'd0;
                k_p16_read_requests <= 32'd0;
                k_scale_read_requests <= 32'd0;
                v_p16_read_requests <= 32'd0;
                v_scale_read_requests <= 32'd0;
                k_read_starvation_cycles <= 32'd0;
                v_read_starvation_cycles <= 32'd0;
                k_starvation_high_water <= 32'd0;
                v_starvation_high_water <= 32'd0;
                read_outstanding_high_water <= 2'd0;
                arithmetic_active_cycles <= 32'd0;
                score_stall_cycles <= 32'd0;
                result_stall_cycles <= 32'd0;
                score_count <= 32'd0;
                result_count <= 32'd0;
                k_wait_streak <= 32'd0;
                v_wait_streak <= 32'd0;
            end else begin
                if (busy)
                    perf_cycles <= perf_cycles + 1'b1;
                if (state >= ST_K_SCALE_REQ && state <= ST_AV_OUTPUT)
                    arithmetic_active_cycles <= arithmetic_active_cycles + 1'b1;
                if (score_valid && !score_ready)
                    score_stall_cycles <= score_stall_cycles + 1'b1;
                if (result_valid && !result_ready)
                    result_stall_cycles <= result_stall_cycles + 1'b1;
                if (score_fire)
                    score_count <= score_count + 1'b1;
                if (result_fire)
                    result_count <= result_count + 1'b1;

                if ((state == ST_K_SCALE_WAIT && !k_scale_rd_valid) ||
                    (state == ST_K_P16_WAIT && !k_p16_rd_valid)) begin
                    k_wait_streak <= k_wait_streak + 1'b1;
                    k_read_starvation_cycles <=
                        k_read_starvation_cycles + 1'b1;
                    if (k_wait_streak + 1'b1 > k_starvation_high_water)
                        k_starvation_high_water <= k_wait_streak + 1'b1;
                end else begin
                    k_wait_streak <= 32'd0;
                end
                if ((state == ST_V_SCALE_WAIT && !v_scale_rd_valid) ||
                    (state == ST_V_P16_WAIT && !v_p16_rd_valid)) begin
                    v_wait_streak <= v_wait_streak + 1'b1;
                    v_read_starvation_cycles <=
                        v_read_starvation_cycles + 1'b1;
                    if (v_wait_streak + 1'b1 > v_starvation_high_water)
                        v_starvation_high_water <= v_wait_streak + 1'b1;
                end else begin
                    v_wait_streak <= 32'd0;
                end
            end

            // Responses accepted during drain retire the final synchronous
            // obligations without making their data visible.
            if (state == ST_FAULT_DRAIN) begin
                if (k_outstanding &&
                    ((k_outstanding_scale && k_scale_rd_valid) ||
                     (!k_outstanding_scale && k_p16_rd_valid)))
                    k_outstanding <= 1'b0;
                if (v_outstanding &&
                    ((v_outstanding_scale && v_scale_rd_valid) ||
                     (!v_outstanding_scale && v_p16_rd_valid)))
                    v_outstanding <= 1'b0;
            end

            if (fault_event) begin
                state <= ST_FAULT_DRAIN;
                sticky_error <= 1'b1;
                row_abort <= 1'b1;
                aborted <= abort_fault;
                if (abort_fault) begin
                    sticky_error_code <= ERR_ABORT;
                    sticky_error_subcode <= state;
                end else if (descriptor_fault) begin
                    if (!tag_relation_ok) begin
                        sticky_error_code <= ERR_TAG;
                        sticky_error_subcode <= 8'h01;
                    end else if (k_epoch != v_epoch ||
                                 k_page_index != v_page_index) begin
                        sticky_error_code <= ERR_EPOCH;
                        sticky_error_subcode <= 8'h01;
                    end else begin
                        sticky_error_code <= ERR_DESCRIPTOR;
                        sticky_error_subcode <= 8'h01;
                    end
                end else begin
                    sticky_error_code <= runtime_fault_code;
                    sticky_error_subcode <= runtime_fault_subcode;
                end
                sticky_k_task_tag <= (state == ST_IDLE) ? k_task_tag : k_tag_reg;
                sticky_v_task_tag <= (state == ST_IDLE) ? v_task_tag : v_tag_reg;
                sticky_epoch <= (state == ST_IDLE) ? k_epoch : epoch_reg;
                sticky_page_index <= (state == ST_IDLE) ?
                                     k_page_index : page_reg;
                beat_active <= 1'b0;
                if (state == ST_IDLE) begin
                    k_tag_reg <= k_task_tag;
                    v_tag_reg <= v_task_tag;
                    epoch_reg <= k_epoch;
                    page_reg <= k_page_index;
                    k_owned <= k_page_active;
                    v_owned <= v_page_active;
                end
                // A response coincident with the fault edge is already
                // drained; do not wait for an obligation that no longer exists.
                if (k_outstanding &&
                    ((k_outstanding_scale && k_scale_rd_valid) ||
                     (!k_outstanding_scale && k_p16_rd_valid)))
                    k_outstanding <= 1'b0;
                if (v_outstanding &&
                    ((v_outstanding_scale && v_scale_rd_valid) ||
                     (!v_outstanding_scale && v_p16_rd_valid)))
                    v_outstanding <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (start_fire) begin
                            context_reg <= context_len;
                            k_tag_reg <= k_task_tag;
                            v_tag_reg <= v_task_tag;
                            epoch_reg <= k_epoch;
                            page_reg <= k_page_index;
                            k_raw_reg <= k_raw_mode;
                            v_raw_reg <= v_raw_mode;
                            k_owned <= 1'b1;
                            v_owned <= 1'b1;
                            token_reg <= 7'd0;
                            head_reg <= 2'd0;
                            group_reg <= 3'd0;
                            state <= ST_GUARD_CMD;
                        end
                    end

                    ST_GUARD_CMD: begin
                        if (guard_cmd_ready)
                            state <= ST_K_SCALE_REQ;
                    end

                    ST_K_SCALE_REQ: begin
                        k_outstanding <= 1'b1;
                        k_outstanding_scale <= 1'b1;
                        k_scale_read_requests <= k_scale_read_requests + 1'b1;
                        if (read_outstanding_high_water < 1)
                            read_outstanding_high_water <= 1;
                        state <= ST_K_SCALE_WAIT;
                    end

                    ST_K_SCALE_WAIT: begin
                        if (k_scale_rd_valid) begin
                            k_outstanding <= 1'b0;
                            k_scale_hold <= k_scale_rd_data;
                            head_reg <= 2'd0;
                            group_reg <= 3'd0;
                            state <= ST_K_P16_REQ;
                        end
                    end

                    ST_K_P16_REQ: begin
                        k_outstanding <= 1'b1;
                        k_outstanding_scale <= 1'b0;
                        k_p16_read_requests <= k_p16_read_requests + 1'b1;
                        if (read_outstanding_high_water < 1)
                            read_outstanding_high_water <= 1;
                        state <= ST_K_P16_WAIT;
                    end

                    ST_K_P16_WAIT: begin
                        if (k_p16_rd_valid) begin
                            k_outstanding <= 1'b0;
                            k_codes_hold <= k_p16_rd_codes;
                            state <= ST_QK_FEED;
                        end
                    end

                    ST_QK_FEED: begin
                        if (group_reg == 7)
                            state <= ST_QK_WAIT;
                        else begin
                            group_reg <= group_reg + 1'b1;
                            state <= ST_K_P16_REQ;
                        end
                    end

                    ST_QK_WAIT: begin
                        if (qk_out_valid && !qk_invalid && quant_in_ready)
                            state <= ST_SCORE_WAIT;
                    end

                    ST_SCORE_WAIT: begin
                        if (score_fire) begin
                            group_reg <= 3'd0;
                            if (head_reg == 3) begin
                                head_reg <= 2'd0;
                                if (token_reg == context_reg-1'b1) begin
                                    state <= ST_GUARD_COMMIT;
                                end else begin
                                    token_reg <= token_reg + 1'b1;
                                    state <= ST_K_SCALE_REQ;
                                end
                            end else begin
                                head_reg <= head_reg + 1'b1;
                                state <= ST_K_P16_REQ;
                            end
                        end
                    end

                    ST_GUARD_COMMIT: begin
                        if (guard_commit_valid) begin
                            copy_row <= 2'd0;
                            copy_index <= 7'd0;
                            state <= ST_COPY_REQ;
                        end
                    end

                    ST_COPY_REQ: state <= ST_COPY_WAIT;

                    ST_COPY_WAIT: begin
                        if (guard_rd_valid) begin
                            if (copy_index == context_reg-1'b1) begin
                                copy_index <= 7'd0;
                                if (copy_row == 3) begin
                                    soft_row_reg <= 2'd0;
                                    soft_expected_index <= 7'd0;
                                    state <= ST_SOFT_START;
                                end else begin
                                    copy_row <= copy_row + 1'b1;
                                    state <= ST_COPY_REQ;
                                end
                            end else begin
                                copy_index <= copy_index + 1'b1;
                                state <= ST_COPY_REQ;
                            end
                        end
                    end

                    ST_SOFT_START: begin
                        soft_expected_index <= 7'd0;
                        state <= ST_SOFT_RUN;
                    end

                    ST_SOFT_RUN: begin
                        if (soft_exp_fire) begin
                            exp_mem[soft_row_reg][soft_exp_index[6:0]] <=
                                soft_exp_code;
                            if (!soft_exp_last)
                                soft_expected_index <=
                                    soft_expected_index + 1'b1;
                        end
                        if (soft_done) begin
                            denominator_mem[soft_row_reg] <= soft_denominator;
                            reciprocal_mem[soft_row_reg] <= soft_reciprocal;
                            reciprocal_exponent_mem[soft_row_reg] <=
                                soft_reciprocal_exponent;
                            if (soft_row_reg == 3) begin
                                token_reg <= 7'd0;
                                head_reg <= 2'd0;
                                group_reg <= 3'd0;
                                state <= ST_AV_START;
                            end else begin
                                soft_row_reg <= soft_row_reg + 1'b1;
                                state <= ST_SOFT_START;
                            end
                        end
                    end

                    ST_AV_START: state <= ST_V_SCALE_REQ;

                    ST_V_SCALE_REQ: begin
                        v_outstanding <= 1'b1;
                        v_outstanding_scale <= 1'b1;
                        v_scale_read_requests <= v_scale_read_requests + 1'b1;
                        if (read_outstanding_high_water < 1)
                            read_outstanding_high_water <= 1;
                        state <= ST_V_SCALE_WAIT;
                    end

                    ST_V_SCALE_WAIT: begin
                        if (v_scale_rd_valid) begin
                            v_outstanding <= 1'b0;
                            v_scale_hold <= v_scale_rd_data;
                            head_reg <= 2'd0;
                            group_reg <= 3'd0;
                            state <= ST_V_P16_REQ;
                        end
                    end

                    ST_V_P16_REQ: begin
                        v_outstanding <= 1'b1;
                        v_outstanding_scale <= 1'b0;
                        v_p16_read_requests <= v_p16_read_requests + 1'b1;
                        if (read_outstanding_high_water < 1)
                            read_outstanding_high_water <= 1;
                        state <= ST_V_P16_WAIT;
                    end

                    ST_V_P16_WAIT: begin
                        if (v_p16_rd_valid) begin
                            v_outstanding <= 1'b0;
                            v_codes_hold <= v_p16_rd_codes;
                            state <= ST_AV_FEED;
                        end
                    end

                    ST_AV_FEED: begin
                        if (av_in_fire) begin
                            if (group_reg == 7) begin
                                group_reg <= 3'd0;
                                if (head_reg == 3) begin
                                    head_reg <= 2'd0;
                                    if (token_reg == context_reg-1'b1) begin
                                        norm_head_reg <= 2'd0;
                                        expected_av_group <= 3'd0;
                                        norm_inputs_complete <= 1'b0;
                                        beat_active <= 1'b0;
                                        state <= ST_NORM_START;
                                    end else begin
                                        token_reg <= token_reg + 1'b1;
                                        state <= ST_V_SCALE_REQ;
                                    end
                                end else begin
                                    head_reg <= head_reg + 1'b1;
                                    state <= ST_V_P16_REQ;
                                end
                            end else begin
                                group_reg <= group_reg + 1'b1;
                                state <= ST_V_P16_REQ;
                            end
                        end
                    end

                    ST_NORM_START: begin
                        expected_av_group <= 3'd0;
                        norm_inputs_complete <= 1'b0;
                        state <= ST_AV_OUTPUT;
                    end

                    ST_AV_OUTPUT: begin
                        if (av_out_valid && av_out_ready) begin
                            beat_active <= 1'b1;
                            beat_group <= av_out_group;
                            beat_lane <= 4'd0;
                            beat_numerators <= av_out_numerators;
                        end
                        if (norm_num_fire) begin
                            pending_numerator <= norm_num_data;
                            if (beat_lane == 15) begin
                                beat_active <= 1'b0;
                                if (beat_group == 7)
                                    norm_inputs_complete <= 1'b1;
                                else
                                    expected_av_group <=
                                        expected_av_group + 1'b1;
                            end else begin
                                beat_lane <= beat_lane + 1'b1;
                            end
                        end
                        if (norm_done) begin
                            beat_active <= 1'b0;
                            norm_inputs_complete <= 1'b0;
                            if (norm_head_reg == 3) begin
                                guard_release <= 1'b1;
                                if (k_owned)
                                    k_page_release <= 1'b1;
                                if (v_owned)
                                    v_page_release <= 1'b1;
                                k_owned <= 1'b0;
                                v_owned <= 1'b0;
                                done <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                norm_head_reg <= norm_head_reg + 1'b1;
                                state <= ST_NORM_START;
                            end
                        end
                    end

                    ST_FAULT_DRAIN: begin
                        if (!k_outstanding && !v_outstanding &&
                            !guard_busy && !soft_busy && soft_quiescent &&
                            !av_busy && !norm_busy) begin
                            guard_release <= 1'b1;
                            if (k_owned)
                                k_page_release <= 1'b1;
                            if (v_owned)
                                v_page_release <= 1'b1;
                            k_owned <= 1'b0;
                            v_owned <= 1'b0;
                            state <= ST_FAULT;
                        end
                    end

                    ST_FAULT: begin
                        if (clear_fault && clear_ready) begin
                            sticky_error <= 1'b0;
                            sticky_error_code <= 8'd0;
                            sticky_error_subcode <= 8'd0;
                            state <= ST_IDLE;
                        end
                    end

                    default: begin
                        sticky_error <= 1'b1;
                        sticky_error_code <= ERR_INTERNAL;
                        sticky_error_subcode <= state;
                        row_abort <= 1'b1;
                        state <= ST_FAULT_DRAIN;
                    end
                endcase
            end
        end
    end

    wire unused_child_status = ^guard_commit_tag ^ ^guard_commit_context ^
        guard_active ^ guard_aborted ^ av_done ^ av_out_last ^ norm_aborted;

`ifndef SYNTHESIS
    initial begin
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_canned_page_arithmetic SCALE_BITS must be 12 or 16");
        if (MAX_CONTEXT != 128)
            $error("kv_v03_canned_page_arithmetic canned ABI fixes context 128");
        if (MULT_STYLE < 0 || MULT_STYLE > 2)
            $error("kv_v03_canned_page_arithmetic MULT_STYLE must be 0..2");
        if (QK_MULT_STYLE < 0 || QK_MULT_STYLE > 2)
            $error("kv_v03_canned_page_arithmetic QK_MULT_STYLE must be 0..2");
        if (AV_MULT_STYLE < 0 || AV_MULT_STYLE > 2)
            $error("kv_v03_canned_page_arithmetic AV_MULT_STYLE must be 0..2");
    end
`endif
endmodule

`default_nettype wire
