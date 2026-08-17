// kv_v03_softmax.v -- two-pass Q8.8 score to UQ1.15 exponent stream.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_softmax #(
    parameter integer MAX_CONTEXT = 4096,
    parameter integer READ_TIMEOUT_CYCLES = 65536
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,
    input  wire [1:0]         score_row,
    input  wire [12:0]        context_len,
    output reg                score_rd_en,
    output wire [1:0]         score_rd_row,
    output reg  [11:0]        score_rd_addr,
    input  wire               score_rd_valid,
    input  wire signed [15:0] score_rd_data,
    output reg                exp_valid,
    input  wire               exp_ready,
    output reg  [11:0]        exp_index,
    output reg  [15:0]        exp_code,
    output reg                exp_last,
    output reg                busy,
    output reg                done,
    output reg signed [15:0]  maximum_score,
    output reg  [27:0]        denominator,
    output reg  [12:0]        reciprocal_code,
    output reg  [4:0]         reciprocal_exponent,
    output reg  [12:0]        underflow_count,
    output reg                error_valid,
    output reg  [7:0]         error_code
);
    localparam [2:0] ST_IDLE = 3'd0, ST_MAX = 3'd1,
                     ST_EXP = 3'd2, ST_RECIP = 3'd3,
                     ST_EXP_LUT = 3'd4, ST_EXP_COMMIT = 3'd5,
                     ST_EXP_ADDR = 3'd6;
    localparam [7:0] ERR_CONTEXT = 8'h01;
    localparam [7:0] ERR_READ_PROTOCOL = 8'h02;
    localparam [7:0] ERR_READ_TIMEOUT = 8'h03;
    localparam [7:0] ERR_RECIPROCAL = 8'h04;
    localparam [7:0] ERR_DENOMINATOR = 8'h05;
    localparam [7:0] ERR_BUSY = 8'h06;

    reg [2:0] state;
    reg [1:0] row_reg;
    reg [12:0] context_reg;
    reg [12:0] issue_index;
    reg [12:0] response_count;
    reg read_pending;
    reg [31:0] read_wait_cycles;
    reg reciprocal_complete;
    reg signed [16:0] exp_delta;
    reg [12:0] rounded_distance_reg;
    reg [6:0] exp_lut_address;
    reg exp_below_underflow;

    wire signed [16:0] score_extended =
        {score_rd_data[15], score_rd_data};
    wire signed [16:0] maximum_extended =
        {maximum_score[15], maximum_score};
    wire [16:0] distance = exp_delta[16] ? -exp_delta : 17'b0;
    wire computed_below_underflow = exp_delta < -17'sd3072;
    // Only distances through 3072 can produce a non-zero table result.  Clamp
    // larger distances before the address arithmetic so synthesis does not
    // build a full-width divider for values that are discarded anyway.
    wire [12:0] rounded_distance_limited = computed_below_underflow ?
                                           13'd3084 :
                                           {1'b0, distance[11:0]} + 13'd12;
    // For every integer n in [0, 3084], floor(n/24) is exactly equal to
    // floor(n*2731/65536).  The registered range limit and constant multiply
    // preserve the frozen rounding rule while shortening the timing path.
    wire [24:0] scaled_distance = rounded_distance_reg * 12'd2731;
    wire [8:0] lut_index_unclamped = scaled_distance[24:16];
    wire [6:0] computed_lut_address = (lut_index_unclamped > 127) ?
                                      7'd127 : lut_index_unclamped[6:0];
    wire [15:0] lut_value;
    wire [15:0] selected_exp_code = exp_below_underflow ?
                                     16'b0 : lut_value;
    wire [28:0] denominator_sum =
        {1'b0, denominator} + {13'b0, selected_exp_code};

    kv_v03_exp_lut u_exp_lut (
        .address(exp_lut_address), .value(lut_value)
    );

    reg reciprocal_start;
    reg [27:0] reciprocal_denominator;
    wire reciprocal_busy, reciprocal_done, reciprocal_error;
    wire [12:0] reciprocal_result;
    wire [4:0] reciprocal_result_exponent;
    wire [7:0] reciprocal_error_code;
    kv_v03_reciprocal u_reciprocal (
        .clk(clk), .rst_n(rst_n), .start(reciprocal_start),
        .denominator(reciprocal_denominator),
        .busy(reciprocal_busy), .done(reciprocal_done),
        .reciprocal_code(reciprocal_result),
        .reciprocal_exponent(reciprocal_result_exponent),
        .error_valid(reciprocal_error),
        .error_code(reciprocal_error_code)
    );

    assign score_rd_row = row_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            row_reg             <= 2'b0;
            context_reg         <= 13'b0;
            issue_index         <= 13'b0;
            response_count      <= 13'b0;
            read_pending        <= 1'b0;
            read_wait_cycles    <= 32'b0;
            score_rd_en         <= 1'b0;
            score_rd_addr       <= 12'b0;
            exp_valid           <= 1'b0;
            exp_index           <= 12'b0;
            exp_code            <= 16'b0;
            exp_last            <= 1'b0;
            busy                <= 1'b0;
            done                <= 1'b0;
            maximum_score       <= -16'sd32768;
            denominator         <= 28'b0;
            reciprocal_code     <= 13'b0;
            reciprocal_exponent <= 5'b0;
            underflow_count     <= 13'b0;
            reciprocal_start    <= 1'b0;
            reciprocal_denominator <= 28'b0;
            reciprocal_complete <= 1'b0;
            exp_delta           <= 17'sb0;
            rounded_distance_reg <= 13'b0;
            exp_lut_address     <= 7'b0;
            exp_below_underflow <= 1'b0;
            error_valid         <= 1'b0;
            error_code          <= 8'b0;
        end else begin
            score_rd_en      <= 1'b0;
            reciprocal_start <= 1'b0;
            done             <= 1'b0;
            error_valid      <= 1'b0;
            if (exp_valid && exp_ready)
                exp_valid <= 1'b0;

            if (start) begin
                if (busy || reciprocal_busy) begin
                    // A restart could coincide with an outstanding score
                    // response or an orphaned reciprocal. Abort explicitly
                    // instead of silently losing state. A new request is also
                    // held off until the non-cancellable reciprocal is idle.
                    busy         <= 1'b0;
                    read_pending <= 1'b0;
                    exp_valid    <= 1'b0;
                    state        <= ST_IDLE;
                    error_valid  <= 1'b1;
                    error_code   <= ERR_BUSY;
                end else if (context_len == 0 ||
                             context_len > MAX_CONTEXT) begin
                    busy        <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_CONTEXT;
                    state       <= ST_IDLE;
                end else begin
                    state               <= ST_MAX;
                    row_reg             <= score_row;
                    context_reg         <= context_len;
                    issue_index         <= 13'b0;
                    response_count      <= 13'b0;
                    read_pending        <= 1'b0;
                    read_wait_cycles    <= 32'b0;
                    exp_valid           <= 1'b0;
                    busy                <= 1'b1;
                    maximum_score       <= -16'sd32768;
                    denominator         <= 28'b0;
                    reciprocal_code     <= 13'b0;
                    reciprocal_exponent <= 5'b0;
                    underflow_count     <= 13'b0;
                    reciprocal_complete <= 1'b0;
                    exp_delta           <= 17'sb0;
                    rounded_distance_reg <= 13'b0;
                    exp_lut_address     <= 7'b0;
                    exp_below_underflow <= 1'b0;
                    error_code          <= 8'b0;
                end
            end else if (busy) begin
                if (read_pending && !score_rd_valid) begin
                    if (read_wait_cycles >= READ_TIMEOUT_CYCLES-1) begin
                        busy         <= 1'b0;
                        read_pending <= 1'b0;
                        exp_valid    <= 1'b0;
                        error_valid  <= 1'b1;
                        error_code   <= ERR_READ_TIMEOUT;
                        state        <= ST_IDLE;
                    end else begin
                        read_wait_cycles <= read_wait_cycles + 1'b1;
                    end
                end

                case (state)
                    ST_MAX: begin
                        if (!read_pending && issue_index < context_reg) begin
                            score_rd_en   <= 1'b1;
                            score_rd_addr <= issue_index[11:0];
                            issue_index   <= issue_index + 1'b1;
                            read_pending  <= 1'b1;
                        end
                        if (score_rd_valid) begin
                            if (!read_pending) begin
                                busy        <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_READ_PROTOCOL;
                                state       <= ST_IDLE;
                            end else begin
                                read_pending     <= 1'b0;
                                read_wait_cycles <= 32'b0;
                                if ($signed(score_rd_data) >
                                    $signed(maximum_score))
                                    maximum_score <= score_rd_data;
                                if (response_count == context_reg-1'b1) begin
                                    issue_index    <= 13'b0;
                                    response_count <= 13'b0;
                                    state          <= ST_EXP;
                                end else begin
                                    response_count <= response_count + 1'b1;
                                end
                            end
                        end
                    end

                    ST_EXP: begin
                        if (!read_pending && issue_index < context_reg &&
                            (!exp_valid || exp_ready)) begin
                            score_rd_en   <= 1'b1;
                            score_rd_addr <= issue_index[11:0];
                            issue_index   <= issue_index + 1'b1;
                            read_pending  <= 1'b1;
                        end
                        if (score_rd_valid) begin
                            if (!read_pending) begin
                                busy        <= 1'b0;
                                exp_valid   <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_READ_PROTOCOL;
                                state       <= ST_IDLE;
                            end else begin
                                read_pending     <= 1'b0;
                                read_wait_cycles <= 32'b0;
                                // Register score subtraction before the
                                // distance/divide/LUT and denominator paths.
                                exp_delta <= score_extended - maximum_extended;
                                state <= ST_EXP_LUT;
                            end
                        end
                    end

                    ST_EXP_LUT: begin
                        // Register the range-limited, rounded distance before
                        // the exact reciprocal multiply.
                        rounded_distance_reg <= rounded_distance_limited;
                        exp_below_underflow <= computed_below_underflow;
                        state               <= ST_EXP_ADDR;
                    end

                    ST_EXP_ADDR: begin
                        // The exact /24 address equation is isolated from the
                        // BRAM response and denominator accumulator paths.
                        exp_lut_address <= computed_lut_address;
                        state               <= ST_EXP_COMMIT;
                    end

                    ST_EXP_COMMIT: begin
                        if (!exp_valid || exp_ready) begin
                            if (denominator_sum[28]) begin
                                busy        <= 1'b0;
                                exp_valid   <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_DENOMINATOR;
                                state       <= ST_IDLE;
                            end else begin
                                exp_valid   <= 1'b1;
                                exp_index   <= response_count[11:0];
                                exp_code    <= selected_exp_code;
                                exp_last    <= (response_count ==
                                                context_reg-1'b1);
                                denominator <= denominator_sum[27:0];
                                if (exp_below_underflow)
                                    underflow_count <=
                                        underflow_count + 1'b1;
                                if (response_count == context_reg-1'b1) begin
                                    reciprocal_denominator <=
                                        denominator_sum[27:0];
                                    reciprocal_start <= 1'b1;
                                    state <= ST_RECIP;
                                end else begin
                                    response_count <= response_count + 1'b1;
                                    state <= ST_EXP;
                                end
                            end
                        end
                    end

                    ST_RECIP: begin
                        if (reciprocal_error) begin
                            busy        <= 1'b0;
                            exp_valid   <= 1'b0;
                            error_valid <= 1'b1;
                            error_code  <= ERR_RECIPROCAL;
                            state       <= ST_IDLE;
                        end else begin
                            if (reciprocal_done) begin
                                reciprocal_code <= reciprocal_result;
                                reciprocal_exponent <=
                                    reciprocal_result_exponent;
                                reciprocal_complete <= 1'b1;
                            end
                            if (reciprocal_complete && !exp_valid) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end

                    default: begin
                        busy        <= 1'b0;
                        error_valid <= 1'b1;
                        error_code  <= ERR_READ_PROTOCOL;
                        state       <= ST_IDLE;
                    end
                endcase
            end
        end
    end

    wire unused_reciprocal_status = reciprocal_busy ^ ^reciprocal_error_code;

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT != 4096)
            $error("kv_v03_softmax: v0.3 ABI fixes MAX_CONTEXT=4096");
        if (READ_TIMEOUT_CYCLES < 1)
            $error("kv_v03_softmax: READ_TIMEOUT_CYCLES must be positive");
    end
`endif
endmodule

`default_nettype wire
