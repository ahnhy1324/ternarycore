// kv_v03_softmax_av_pipeline.v -- raw score/softmax/V5/AV board pipeline.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// Scores are written before START.  The controller runs the four GQA4 score
// rows through the frozen softmax engine, stores the resulting exponent codes,
// streams dense raw V5 rows from DDR through the existing AV accumulator, and
// applies the per-head F12 reciprocal to produce signed18 Q*.8 results.  The
// signed-48 numerator remains visible beside every normalized result.
module kv_v03_softmax_av_pipeline #(
    parameter integer MAX_CONTEXT = 128,
    parameter integer SCALE_WIDTH = 12,
    parameter integer MULT_STYLE = 2,
    parameter integer AXI_ADDR_WIDTH = 32,
    parameter integer AXI_DATA_WIDTH = 64,
    parameter integer AXI_ID_WIDTH = 1,
    parameter integer TIMEOUT_CYCLES = 65536
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire                         abort,
    input  wire [12:0]                  context_len,
    input  wire [AXI_ADDR_WIDTH-1:0]    v_base_addr,

    input  wire                         score_wr_en,
    input  wire [1:0]                   score_wr_row,
    input  wire [11:0]                  score_wr_addr,
    input  wire signed [15:0]           score_wr_data,
    output wire                         score_wr_ready,
    input  wire                         scale_wr_en,
    input  wire [6:0]                   scale_wr_addr,
    input  wire [SCALE_WIDTH-1:0]       scale_wr_data,
    output wire                         scale_wr_ready,

    output wire                         result_valid,
    input  wire                         result_ready,
    output wire [1:0]                   result_head,
    output wire [6:0]                   result_dimension,
    output wire signed [47:0]           result_numerator,
    output wire signed [17:0]           result_code,
    output wire                         result_saturated,
    output wire                         result_last,

    output wire                         busy,
    output reg                          done,
    output reg                          aborted,
    output reg                          error_valid,
    output reg  [7:0]                   error_code,
    output reg  [31:0]                  perf_cycles,
    output wire [31:0]                  read_beats,
    output wire [31:0]                  ar_stall_cycles,
    output wire [31:0]                  r_stall_cycles,
    output reg  [15:0]                  saturation_count,
    output wire [111:0]                 denominators,
    output wire [51:0]                  reciprocal_codes,
    output wire [19:0]                  reciprocal_exponents,

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
                     ST_SOFT_START  = 4'd1,
                     ST_SOFT_RUN    = 4'd2,
                     ST_AV_START    = 4'd3,
                     ST_AV_RUN      = 4'd4,
                     ST_ABORT_DRAIN = 4'd5,
                     ST_ERROR_DRAIN = 4'd6;
    localparam [7:0] ERR_CONTEXT    = 8'h01;
    localparam [7:0] ERR_BUSY_START = 8'h80;
    localparam [7:0] ERR_SEQUENCE   = 8'h81;

    reg [3:0] state;
    reg [12:0] context_reg;
    reg [AXI_ADDR_WIDTH-1:0] v_base_reg;
    reg [1:0] softmax_head;
    reg softmax_start;
    reg av_start;
    reg av_abort;
    reg normalizer_start;
    reg normalizer_abort;

    reg [15:0] exp_mem [0:3][0:MAX_CONTEXT-1];
    reg [SCALE_WIDTH-1:0] scale_mem [0:MAX_CONTEXT-1];
    reg [27:0] denominator_mem [0:3];
    reg [12:0] reciprocal_mem [0:3];
    reg [4:0] reciprocal_exponent_mem [0:3];

    assign denominators = {denominator_mem[3], denominator_mem[2],
                           denominator_mem[1], denominator_mem[0]};
    assign reciprocal_codes = {reciprocal_mem[3], reciprocal_mem[2],
                               reciprocal_mem[1], reciprocal_mem[0]};
    assign reciprocal_exponents = {reciprocal_exponent_mem[3],
                                   reciprocal_exponent_mem[2],
                                   reciprocal_exponent_mem[1],
                                   reciprocal_exponent_mem[0]};
    assign busy = state != ST_IDLE;
    assign score_wr_ready = state == ST_IDLE;
    assign scale_wr_ready = state == ST_IDLE;

    wire soft_exp_valid;
    wire soft_exp_ready = state == ST_SOFT_RUN && !abort && !start;
    wire [11:0] soft_exp_index;
    wire [15:0] soft_exp_code;
    wire soft_exp_last;
    wire soft_busy, soft_quiescent, soft_done;
    wire signed [15:0] soft_maximum;
    wire [27:0] soft_denominator;
    wire [12:0] soft_reciprocal;
    wire [4:0] soft_reciprocal_exponent;
    wire [12:0] soft_underflows;
    wire soft_error_valid;
    wire [7:0] soft_error_code;

    kv_v03_softmax_engine #(
        // The frozen score-store/softmax ABI is physically 4096 deep.  This
        // diagnostic controller applies the smaller MAX_CONTEXT preflight.
        .MAX_CONTEXT(4096),
        .READ_TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_softmax (
        .clk(clk), .rst_n(rst_n),
        .score_wr_en(score_wr_en && score_wr_ready),
        .score_wr_row(score_wr_row), .score_wr_addr(score_wr_addr),
        .score_wr_data(score_wr_data), .start(softmax_start),
        .score_row(softmax_head), .context_len(context_reg),
        .exp_valid(soft_exp_valid), .exp_ready(soft_exp_ready),
        .exp_index(soft_exp_index), .exp_code(soft_exp_code),
        .exp_last(soft_exp_last), .busy(soft_busy),
        .quiescent(soft_quiescent), .done(soft_done),
        .maximum_score(soft_maximum), .denominator(soft_denominator),
        .reciprocal_code(soft_reciprocal),
        .reciprocal_exponent(soft_reciprocal_exponent),
        .underflow_count(soft_underflows),
        .error_valid(soft_error_valid), .error_code(soft_error_code)
    );

    reg meta_rsp_valid;
    reg [SCALE_WIDTH-1:0] meta_rsp_scale;
    reg [63:0] meta_rsp_exp_codes;
    wire meta_req_valid, meta_req_ready;
    wire [6:0] meta_req_token;
    wire meta_rsp_ready;
    assign meta_req_ready = !meta_rsp_valid;

    wire av_busy, av_draining, av_done, av_aborted, av_error;
    wire [7:0] av_error_code;
    wire [31:0] av_perf_cycles;
    wire [6:0] av_progress_token;
    wire [1:0] av_progress_head;
    wire [2:0] av_progress_group;
    wire [3:0] av_progress_state;
    wire av_result_valid, av_result_ready, av_result_last;
    wire [1:0] av_result_head;
    wire [2:0] av_result_group;
    wire [767:0] av_result_numerators;

    kv_v03_raw_v5_av_engine #(
        .MAX_CONTEXT(MAX_CONTEXT), .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH), .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES), .MULT_STYLE(MULT_STYLE),
        .SCALE_WIDTH(SCALE_WIDTH)
    ) u_av_engine (
        .clk(clk), .rst_n(rst_n), .start(av_start),
        .abort(av_abort || abort), .context_len(context_reg),
        .v_base_addr(v_base_reg), .meta_req_valid(meta_req_valid),
        .meta_req_ready(meta_req_ready), .meta_req_token(meta_req_token),
        .meta_rsp_valid(meta_rsp_valid), .meta_rsp_ready(meta_rsp_ready),
        .meta_scale(meta_rsp_scale),
        .meta_exp_codes(meta_rsp_exp_codes), .busy(av_busy),
        .draining(av_draining), .done(av_done), .aborted(av_aborted),
        .error(av_error), .error_code(av_error_code),
        .perf_cycles(av_perf_cycles), .read_beats(read_beats),
        .ar_stall_cycles(ar_stall_cycles),
        .r_stall_cycles(r_stall_cycles),
        .progress_token(av_progress_token),
        .progress_head(av_progress_head),
        .progress_group(av_progress_group),
        .progress_state(av_progress_state),
        .result_valid(av_result_valid), .result_ready(av_result_ready),
        .result_head(av_result_head), .result_group(av_result_group),
        .result_numerators(av_result_numerators),
        .result_last(av_result_last), .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock), .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    reg beat_active;
    reg [1:0] beat_head;
    reg [2:0] beat_group;
    reg [3:0] beat_lane;
    reg [767:0] beat_numerators;
    reg [1:0] normalize_head;
    reg await_normalizer_done;
    reg av_done_seen;
    reg [1:0] expected_av_head;
    reg [2:0] expected_av_group;

    wire normalizer_busy, normalizer_done, normalizer_aborted;
    wire normalizer_error_valid;
    wire [7:0] normalizer_error_code;
    wire normalizer_input_ready;
    wire normalizer_output_valid;
    wire [6:0] normalizer_output_index;
    wire signed [17:0] normalizer_output_code;
    wire normalizer_output_saturated, normalizer_output_last;
    wire [15:0] head_saturation_count;
    wire signed [47:0] current_numerator =
        beat_numerators[(beat_lane*48) +: 48];
    wire normalizer_input_valid = state == ST_AV_RUN && beat_active &&
                                  !abort && !start;
    wire normalizer_input_handshake = normalizer_input_valid &&
                                      normalizer_input_ready;
    wire normalizer_output_ready = result_ready && state == ST_AV_RUN &&
                                   !abort && !start;
    wire normalizer_output_handshake = normalizer_output_valid &&
                                       normalizer_output_ready;
    reg signed [47:0] result_numerator_hold;

    kv_v03_av_normalizer #(
        .SCALE_FRACTION_BITS((SCALE_WIDTH == 12) ? 8 : 11)
    ) u_normalizer (
        .clk(clk), .rst_n(rst_n), .start(normalizer_start),
        .abort(normalizer_abort || abort),
        .reciprocal_code(reciprocal_mem[normalize_head]),
        .reciprocal_exponent(reciprocal_exponent_mem[normalize_head]),
        .numerator_valid(normalizer_input_valid),
        .numerator_ready(normalizer_input_ready),
        .numerator_index({beat_group, beat_lane}),
        .numerator(current_numerator),
        .numerator_last(beat_group == 7 && beat_lane == 15),
        .output_valid(normalizer_output_valid),
        .output_ready(normalizer_output_ready),
        .output_index(normalizer_output_index),
        .output_code(normalizer_output_code),
        .output_saturated(normalizer_output_saturated),
        .output_last(normalizer_output_last), .busy(normalizer_busy),
        .done(normalizer_done), .aborted(normalizer_aborted),
        .saturation_count(head_saturation_count),
        .error_valid(normalizer_error_valid),
        .error_code(normalizer_error_code)
    );

    assign av_result_ready = state == ST_AV_RUN && !beat_active &&
                             !await_normalizer_done && !abort && !start;
    assign result_valid = normalizer_output_valid && state == ST_AV_RUN &&
                          !abort && !start;
    assign result_head = normalize_head;
    assign result_dimension = normalizer_output_index;
    assign result_numerator = result_numerator_hold;
    assign result_code = normalizer_output_code;
    assign result_saturated = normalizer_output_saturated;
    assign result_last = normalize_head == 3 && normalizer_output_last;

    integer memory_index;
    always @(posedge clk) begin
        if (!rst_n) begin
            state                      <= ST_IDLE;
            context_reg                <= 13'd0;
            v_base_reg                 <= {AXI_ADDR_WIDTH{1'b0}};
            softmax_head               <= 2'd0;
            softmax_start              <= 1'b0;
            av_start                   <= 1'b0;
            av_abort                   <= 1'b0;
            normalizer_start           <= 1'b0;
            normalizer_abort           <= 1'b0;
            meta_rsp_valid             <= 1'b0;
            meta_rsp_scale             <= {SCALE_WIDTH{1'b0}};
            meta_rsp_exp_codes         <= 64'd0;
            beat_active                <= 1'b0;
            beat_head                  <= 2'd0;
            beat_group                 <= 3'd0;
            beat_lane                  <= 4'd0;
            beat_numerators            <= 768'd0;
            normalize_head             <= 2'd0;
            await_normalizer_done      <= 1'b0;
            av_done_seen               <= 1'b0;
            expected_av_head           <= 2'd0;
            expected_av_group          <= 3'd0;
            result_numerator_hold      <= 48'sd0;
            done                       <= 1'b0;
            aborted                    <= 1'b0;
            error_valid                <= 1'b0;
            error_code                 <= 8'd0;
            perf_cycles                <= 32'd0;
            saturation_count           <= 16'd0;
            for (memory_index = 0; memory_index < 4;
                 memory_index = memory_index + 1) begin
                denominator_mem[memory_index] <= 28'd0;
                reciprocal_mem[memory_index] <= 13'd0;
                reciprocal_exponent_mem[memory_index] <= 5'd0;
            end
        end else begin
            softmax_start    <= 1'b0;
            av_start         <= 1'b0;
            av_abort         <= 1'b0;
            normalizer_start <= 1'b0;
            normalizer_abort <= 1'b0;
            done             <= 1'b0;
            aborted          <= 1'b0;
            error_valid      <= 1'b0;

            if (state != ST_IDLE)
                perf_cycles <= perf_cycles + 1'b1;

            if (scale_wr_en && scale_wr_ready)
                scale_mem[scale_wr_addr] <= scale_wr_data;

            if (meta_rsp_valid && meta_rsp_ready)
                meta_rsp_valid <= 1'b0;
            if (meta_req_valid && meta_req_ready) begin
                meta_rsp_valid <= 1'b1;
                meta_rsp_scale <= scale_mem[meta_req_token];
                meta_rsp_exp_codes <= {
                    exp_mem[3][meta_req_token], exp_mem[2][meta_req_token],
                    exp_mem[1][meta_req_token], exp_mem[0][meta_req_token]};
            end

            if (state == ST_IDLE) begin
                if (start) begin
                    if (context_len == 0 || context_len > MAX_CONTEXT) begin
                        error_valid <= 1'b1;
                        error_code  <= ERR_CONTEXT;
                    end else begin
                        context_reg           <= context_len;
                        v_base_reg            <= v_base_addr;
                        softmax_head          <= 2'd0;
                        beat_active           <= 1'b0;
                        await_normalizer_done <= 1'b0;
                        av_done_seen          <= 1'b0;
                        expected_av_head      <= 2'd0;
                        expected_av_group     <= 3'd0;
                        meta_rsp_valid        <= 1'b0;
                        perf_cycles           <= 32'd0;
                        saturation_count      <= 16'd0;
                        error_code            <= 8'd0;
                        state                 <= ST_SOFT_START;
                    end
                end
            end else if (abort || start) begin
                if (start) begin
                    error_valid <= 1'b1;
                    error_code  <= ERR_BUSY_START;
                    state       <= ST_ERROR_DRAIN;
                end else begin
                    state <= ST_ABORT_DRAIN;
                end
                if (soft_busy)
                    softmax_start <= 1'b1;
                av_abort           <= 1'b1;
                normalizer_abort   <= 1'b1;
                beat_active        <= 1'b0;
            end else if (state == ST_ABORT_DRAIN ||
                         state == ST_ERROR_DRAIN) begin
                if (soft_quiescent && !av_busy && !av_draining &&
                    !normalizer_busy) begin
                    if (state == ST_ABORT_DRAIN)
                        aborted <= 1'b1;
                    state <= ST_IDLE;
                end
            end else if (soft_error_valid || av_error ||
                         normalizer_error_valid) begin
                error_valid <= 1'b1;
                if (soft_error_valid)
                    error_code <= 8'h20 | soft_error_code;
                else if (av_error)
                    error_code <= 8'h40 | av_error_code;
                else
                    error_code <= 8'h60 | normalizer_error_code;
                if (soft_busy)
                    softmax_start <= 1'b1;
                av_abort           <= 1'b1;
                normalizer_abort   <= 1'b1;
                beat_active        <= 1'b0;
                state              <= ST_ERROR_DRAIN;
            end else begin
                case (state)
                    ST_SOFT_START: begin
                        softmax_start <= 1'b1;
                        state <= ST_SOFT_RUN;
                    end
                    ST_SOFT_RUN: begin
                        if (soft_exp_valid && soft_exp_ready)
                            exp_mem[softmax_head][soft_exp_index] <=
                                soft_exp_code;
                        if (soft_done) begin
                            denominator_mem[softmax_head] <=
                                soft_denominator;
                            reciprocal_mem[softmax_head] <=
                                soft_reciprocal;
                            reciprocal_exponent_mem[softmax_head] <=
                                soft_reciprocal_exponent;
                            if (softmax_head == 3)
                                state <= ST_AV_START;
                            else begin
                                softmax_head <= softmax_head + 1'b1;
                                state <= ST_SOFT_START;
                            end
                        end
                    end
                    ST_AV_START: begin
                        av_start <= 1'b1;
                        state <= ST_AV_RUN;
                    end
                    ST_AV_RUN: begin
                        if (av_done)
                            av_done_seen <= 1'b1;
                        if (av_result_valid && av_result_ready) begin
                            if (av_result_head != expected_av_head ||
                                av_result_group != expected_av_group) begin
                                error_valid      <= 1'b1;
                                error_code       <= ERR_SEQUENCE;
                                av_abort         <= 1'b1;
                                normalizer_abort <= 1'b1;
                                state            <= ST_ERROR_DRAIN;
                            end else begin
                                beat_active     <= 1'b1;
                                beat_head       <= av_result_head;
                                beat_group      <= av_result_group;
                                beat_lane       <= 4'd0;
                                beat_numerators <= av_result_numerators;
                                if (av_result_group == 0) begin
                                    normalize_head   <= av_result_head;
                                    normalizer_start <= 1'b1;
                                end
                                if (expected_av_group == 7) begin
                                    expected_av_group <= 3'd0;
                                    if (expected_av_head != 3)
                                        expected_av_head <=
                                            expected_av_head + 1'b1;
                                end else begin
                                    expected_av_group <=
                                        expected_av_group + 1'b1;
                                end
                            end
                        end
                        if (normalizer_input_handshake) begin
                            result_numerator_hold <= current_numerator;
                            if (beat_lane == 15) begin
                                beat_active <= 1'b0;
                                if (beat_group == 7)
                                    await_normalizer_done <= 1'b1;
                            end else begin
                                beat_lane <= beat_lane + 1'b1;
                            end
                        end
                        if (normalizer_done) begin
                            saturation_count <= saturation_count +
                                                head_saturation_count;
                            await_normalizer_done <= 1'b0;
                            if (normalize_head == 3 &&
                                (av_done_seen || av_done)) begin
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end
                    default: begin
                        error_valid <= 1'b1;
                        error_code  <= ERR_SEQUENCE;
                        state       <= ST_ERROR_DRAIN;
                    end
                endcase
            end
        end
    end

    wire unused_status = soft_exp_last ^ ^soft_maximum ^
        ^soft_underflows ^ av_aborted ^ av_result_last ^
        ^av_perf_cycles ^ ^av_progress_token ^ ^av_progress_head ^
        ^av_progress_group ^ ^av_progress_state ^ beat_head ^
        normalizer_aborted ^ normalizer_output_handshake;

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("kv_v03_softmax_av_pipeline: diagnostic context is 1..128");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("kv_v03_softmax_av_pipeline: SCALE_WIDTH must be 12 or 16");
        if (AXI_DATA_WIDTH != 64 && AXI_DATA_WIDTH != 128)
            $error("kv_v03_softmax_av_pipeline: AXI width must be 64 or 128");
    end
`endif
endmodule

`default_nettype wire
