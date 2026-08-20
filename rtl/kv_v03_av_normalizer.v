// kv_v03_av_normalizer.v -- F12 reciprocal application for AV numerators.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// The architectural output is a signed fixed-point code with eight fractional
// bits.  OUT_WIDTH=18 covers the complete legal V5 x UQ4.8/UQ5.11 value range
// without saturation; saturation remains explicit and observable for malformed
// or out-of-contract inputs.  Rounding is round-to-nearest, ties-to-even.
module kv_v03_av_normalizer #(
    parameter integer HEAD_DIM = 128,
    parameter integer INDEX_WIDTH = $clog2(HEAD_DIM),
    parameter integer OUT_WIDTH = 18,
    parameter integer OUT_FRACTION_BITS = 8,
    parameter integer SCALE_FRACTION_BITS = 8
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    input  wire                          abort,
    input  wire [12:0]                   reciprocal_code,
    input  wire [4:0]                    reciprocal_exponent,
    input  wire                          numerator_valid,
    output wire                          numerator_ready,
    input  wire [INDEX_WIDTH-1:0]        numerator_index,
    input  wire signed [47:0]            numerator,
    input  wire                          numerator_last,
    output wire                          output_valid,
    input  wire                          output_ready,
    output reg  [INDEX_WIDTH-1:0]        output_index,
    output reg  signed [OUT_WIDTH-1:0]   output_code,
    output reg                           output_saturated,
    output wire                          output_last,
    output wire                          busy,
    output reg                           done,
    output reg                           aborted,
    output reg  [15:0]                   saturation_count,
    output reg                           error_valid,
    output reg  [7:0]                    error_code
);
    localparam [7:0] ERR_RECIPROCAL = 8'h01;
    localparam [7:0] ERR_BUSY       = 8'h02;
    localparam [7:0] ERR_FRAMING    = 8'h03;
    localparam integer PRODUCT_WIDTH = 62;

    reg active;
    reg accepting;
    reg output_valid_reg;
    reg output_last_reg;
    reg [INDEX_WIDTH-1:0] expected_index;
    reg [12:0] reciprocal_reg;
    reg [4:0] exponent_reg;

    wire output_handshake = output_valid && output_ready;
    assign output_valid = output_valid_reg && !abort;
    assign output_last = output_last_reg;
    assign numerator_ready = active && accepting &&
                             (!output_valid_reg || output_ready) && !abort;
    wire numerator_handshake = numerator_valid && numerator_ready;
    assign busy = active;

    // Return {saturated, signed_code}.  The reciprocal code represents
    // round_even((2^exponent / denominator) * 2^12), so shifting the signed
    // product by exponent+12 plus the input/output fractional-bit delta
    // produces the common signed Q*.8 output code.
    function [OUT_WIDTH:0] normalize_value;
        input signed [47:0] value;
        input [12:0] reciprocal;
        input [4:0] exponent;
        reg signed [PRODUCT_WIDTH-1:0] product;
        reg [PRODUCT_WIDTH-1:0] magnitude;
        reg [PRODUCT_WIDTH-1:0] quotient;
        reg [PRODUCT_WIDTH-1:0] remainder;
        reg [PRODUCT_WIDTH-1:0] remainder_mask;
        reg [PRODUCT_WIDTH-1:0] half;
        reg [PRODUCT_WIDTH:0] rounded_magnitude;
        reg round_up;
        reg saturated_value;
        reg signed [OUT_WIDTH-1:0] result;
        integer shift_bits;
        begin
            product = value * $signed({1'b0, reciprocal});
            magnitude = product[PRODUCT_WIDTH-1] ?
                        (~product + {{(PRODUCT_WIDTH-1){1'b0}}, 1'b1}) :
                        product;
            shift_bits = exponent + 12 + SCALE_FRACTION_BITS -
                         OUT_FRACTION_BITS;
            quotient = magnitude >> shift_bits;
            if (shift_bits == 0) begin
                remainder = {PRODUCT_WIDTH{1'b0}};
                half = {PRODUCT_WIDTH{1'b0}};
                round_up = 1'b0;
            end else begin
                remainder_mask =
                    ({{(PRODUCT_WIDTH-1){1'b0}}, 1'b1} << shift_bits) - 1'b1;
                remainder = magnitude & remainder_mask;
                half = {{(PRODUCT_WIDTH-1){1'b0}}, 1'b1} <<
                       (shift_bits - 1);
                round_up = (remainder > half) ||
                           ((remainder == half) && quotient[0]);
            end
            rounded_magnitude = {1'b0, quotient} + round_up;
            saturated_value = 1'b0;
            if (!product[PRODUCT_WIDTH-1]) begin
                if (rounded_magnitude >
                    (({{PRODUCT_WIDTH{1'b0}}, 1'b1} <<
                      (OUT_WIDTH-1)) - 1'b1)) begin
                    result = {1'b0, {(OUT_WIDTH-1){1'b1}}};
                    saturated_value = 1'b1;
                end else begin
                    result = rounded_magnitude[OUT_WIDTH-1:0];
                end
            end else begin
                if (rounded_magnitude >
                    ({{PRODUCT_WIDTH{1'b0}}, 1'b1} << (OUT_WIDTH-1))) begin
                    result = {1'b1, {(OUT_WIDTH-1){1'b0}}};
                    saturated_value = 1'b1;
                end else begin
                    result = -$signed(rounded_magnitude[OUT_WIDTH-1:0]);
                end
            end
            normalize_value = {saturated_value, result};
        end
    endfunction

    wire [OUT_WIDTH:0] normalized =
        normalize_value(numerator, reciprocal_reg, exponent_reg);
    wire expected_last = numerator_index == HEAD_DIM-1;

    always @(posedge clk) begin
        if (!rst_n) begin
            active               <= 1'b0;
            accepting            <= 1'b0;
            output_valid_reg     <= 1'b0;
            output_last_reg      <= 1'b0;
            expected_index       <= {INDEX_WIDTH{1'b0}};
            reciprocal_reg       <= 13'd0;
            exponent_reg         <= 5'd0;
            output_index         <= {INDEX_WIDTH{1'b0}};
            output_code          <= {OUT_WIDTH{1'b0}};
            output_saturated     <= 1'b0;
            done                 <= 1'b0;
            aborted              <= 1'b0;
            saturation_count     <= 16'd0;
            error_valid          <= 1'b0;
            error_code           <= 8'd0;
        end else begin
            done        <= 1'b0;
            aborted     <= 1'b0;
            error_valid <= 1'b0;

            if (abort) begin
                if (active)
                    aborted <= 1'b1;
                active           <= 1'b0;
                accepting        <= 1'b0;
                output_valid_reg <= 1'b0;
                output_last_reg  <= 1'b0;
            end else if (start) begin
                if (active) begin
                    active           <= 1'b0;
                    accepting        <= 1'b0;
                    output_valid_reg <= 1'b0;
                    output_last_reg  <= 1'b0;
                    error_valid      <= 1'b1;
                    error_code       <= ERR_BUSY;
                end else if (reciprocal_code == 0 ||
                             reciprocal_exponent > 27) begin
                    error_valid <= 1'b1;
                    error_code  <= ERR_RECIPROCAL;
                end else begin
                    active           <= 1'b1;
                    accepting        <= 1'b1;
                    output_valid_reg <= 1'b0;
                    output_last_reg  <= 1'b0;
                    expected_index   <= {INDEX_WIDTH{1'b0}};
                    reciprocal_reg   <= reciprocal_code;
                    exponent_reg     <= reciprocal_exponent;
                    saturation_count <= 16'd0;
                    error_code       <= 8'd0;
                end
            end else if (active) begin
                if (output_handshake) begin
                    output_valid_reg <= 1'b0;
                    if (output_last_reg) begin
                        active  <= 1'b0;
                        done    <= 1'b1;
                    end
                end

                if (numerator_handshake) begin
                    if (numerator_index != expected_index ||
                        numerator_last != expected_last) begin
                        active           <= 1'b0;
                        accepting        <= 1'b0;
                        output_valid_reg <= 1'b0;
                        output_last_reg  <= 1'b0;
                        error_valid      <= 1'b1;
                        error_code       <= ERR_FRAMING;
                    end else begin
                        output_valid_reg <= 1'b1;
                        output_last_reg  <= expected_last;
                        output_index     <= numerator_index;
                        output_code      <= normalized[OUT_WIDTH-1:0];
                        output_saturated <= normalized[OUT_WIDTH];
                        if (normalized[OUT_WIDTH])
                            saturation_count <= saturation_count + 1'b1;
                        if (expected_last)
                            accepting <= 1'b0;
                        else
                            expected_index <= expected_index + 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (HEAD_DIM < 1 || INDEX_WIDTH < 1)
            $error("kv_v03_av_normalizer: invalid HEAD_DIM/INDEX_WIDTH");
        if (OUT_WIDTH != 18 || OUT_FRACTION_BITS != 8)
            $error("kv_v03_av_normalizer: frozen ABI is signed18 Q*.8");
        if (SCALE_FRACTION_BITS != 8 && SCALE_FRACTION_BITS != 11)
            $error("kv_v03_av_normalizer: input scale fraction must be 8 or 11");
    end
`endif
endmodule

`default_nettype wire
