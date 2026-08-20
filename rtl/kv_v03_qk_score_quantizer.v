// kv_v03_qk_score_quantizer.v -- scaled QK accumulator to signed Q8.8.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_qk_score_quantizer #(
    parameter integer INPUT_WIDTH = 32,
    parameter integer SCALE_FRACTION_BITS = 8,
    parameter integer OUTPUT_FRACTION_BITS = 8
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          abort,
    input  wire                          in_valid,
    output wire                          in_ready,
    input  wire [1:0]                    in_row,
    input  wire [11:0]                   in_index,
    input  wire signed [INPUT_WIDTH-1:0] in_score,
    output wire                          out_valid,
    input  wire                          out_ready,
    output wire [1:0]                    out_row,
    output wire [11:0]                   out_index,
    output wire signed [15:0]            out_score,
    output wire                          out_saturated
);
    localparam integer SHIFT_BITS = SCALE_FRACTION_BITS -
                                    OUTPUT_FRACTION_BITS;

    reg valid_reg;
    reg [1:0] row_reg;
    reg [11:0] index_reg;
    reg signed [15:0] score_reg;
    reg saturated_reg;

    assign out_valid = valid_reg && !abort;
    assign out_row = row_reg;
    assign out_index = index_reg;
    assign out_score = score_reg;
    assign out_saturated = saturated_reg;
    assign in_ready = (!valid_reg || out_ready) && !abort;
    wire input_fire = in_valid && in_ready;
    wire output_fire = out_valid && out_ready;

    wire score_negative = in_score[INPUT_WIDTH-1];
    wire [INPUT_WIDTH:0] magnitude = score_negative ?
        ({1'b0, ~in_score} + 1'b1) : {1'b0, in_score};
    // The retained formats need only a no-shift UQ4.8 path and a three-bit
    // UQ5.11 path.  Keeping the cases explicit avoids an invalid negative
    // shift in elaborators when SHIFT_BITS is zero.
    wire [INPUT_WIDTH:0] quotient = (SCALE_FRACTION_BITS == 11) ?
                                    (magnitude >> 3) : magnitude;
    wire [2:0] remainder = (SCALE_FRACTION_BITS == 11) ?
                           magnitude[2:0] : 3'b000;
    wire round_up = (SCALE_FRACTION_BITS == 11) &&
                    ((remainder > 3'd4) ||
                     ((remainder == 3'd4) && quotient[0]));
    wire [INPUT_WIDTH:0] rounded_magnitude = quotient + round_up;
    wire positive_overflow = !score_negative &&
                             (rounded_magnitude > 32767);
    wire negative_overflow = score_negative &&
                             (rounded_magnitude > 32768);
    wire saturated_comb = positive_overflow || negative_overflow;
    wire signed [INPUT_WIDTH:0] signed_rounded = score_negative ?
        -$signed(rounded_magnitude) : $signed(rounded_magnitude);
    wire signed [15:0] quantized_comb = positive_overflow ? 16'sh7fff :
        negative_overflow ? -16'sd32768 : signed_rounded[15:0];

    always @(posedge clk) begin
        if (!rst_n || abort) begin
            valid_reg <= 1'b0;
            row_reg <= 2'd0;
            index_reg <= 12'd0;
            score_reg <= 16'sd0;
            saturated_reg <= 1'b0;
        end else begin
            if (output_fire)
                valid_reg <= 1'b0;
            if (input_fire) begin
                valid_reg <= 1'b1;
                row_reg <= in_row;
                index_reg <= in_index;
                score_reg <= quantized_comb;
                saturated_reg <= saturated_comb;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (INPUT_WIDTH < 17)
            $error("kv_v03_qk_score_quantizer INPUT_WIDTH must be >=17");
        if (OUTPUT_FRACTION_BITS != 8)
            $error("kv_v03_qk_score_quantizer output ABI is Q8.8");
        if (SCALE_FRACTION_BITS != 8 && SCALE_FRACTION_BITS != 11)
            $error("kv_v03_qk_score_quantizer scale must be UQ4.8/UQ5.11");
    end
`endif
endmodule

`default_nettype wire
