// kv_v03_v5_weight_mul.v -- unsigned weight times signed legal V5 code.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_v5_weight_mul #(
    parameter integer WEIGHT_WIDTH = 28,
    // 0: explicit CSD/shift-add, 1: force DSP, 2: Vivado auto.
    parameter integer MULT_STYLE = 2
) (
    input  wire [WEIGHT_WIDTH-1:0] weight,
    input  wire signed [4:0]       v_code,
    output wire signed [WEIGHT_WIDTH+4:0] product
);
    function signed [WEIGHT_WIDTH+4:0] csd_product;
        input [WEIGHT_WIDTH-1:0] unsigned_weight;
        input signed [4:0] code;
        reg negative;
        reg [4:0] magnitude;
        reg signed [WEIGHT_WIDTH+4:0] extended_weight;
        reg signed [WEIGHT_WIDTH+4:0] magnitude_product;
        begin
            negative = code[4];
            magnitude = negative ? (~code + 1'b1) : code;
            extended_weight = $signed({5'b0, unsigned_weight});
            case (magnitude)
                5'd0:  magnitude_product = 0;
                5'd1:  magnitude_product = extended_weight;
                5'd2:  magnitude_product = extended_weight <<< 1;
                5'd3:  magnitude_product = (extended_weight <<< 1) +
                                                   extended_weight;
                5'd4:  magnitude_product = extended_weight <<< 2;
                5'd5:  magnitude_product = (extended_weight <<< 2) +
                                                   extended_weight;
                5'd6:  magnitude_product = (extended_weight <<< 3) -
                                          (extended_weight <<< 1);
                5'd7:  magnitude_product = (extended_weight <<< 3) -
                                                   extended_weight;
                5'd8:  magnitude_product = extended_weight <<< 3;
                5'd9:  magnitude_product = (extended_weight <<< 3) +
                                                   extended_weight;
                5'd10: magnitude_product = (extended_weight <<< 3) +
                                          (extended_weight <<< 1);
                5'd11: magnitude_product = (extended_weight <<< 4) -
                                          (extended_weight <<< 2) -
                                                   extended_weight;
                5'd12: magnitude_product = (extended_weight <<< 4) -
                                          (extended_weight <<< 2);
                5'd13: magnitude_product = (extended_weight <<< 4) -
                                          (extended_weight <<< 1) -
                                                   extended_weight;
                5'd14: magnitude_product = (extended_weight <<< 4) -
                                          (extended_weight <<< 1);
                5'd15: magnitude_product = (extended_weight <<< 4) -
                                                   extended_weight;
                default: magnitude_product = 0;
            endcase
            csd_product = (negative && magnitude != 0) ?
                          -magnitude_product : magnitude_product;
        end
    endfunction

    generate
        if (MULT_STYLE == 0) begin : g_csd
            assign product = csd_product(weight, v_code);
        end else if (MULT_STYLE == 1) begin : g_dsp
            (* use_dsp = "yes" *) wire signed [WEIGHT_WIDTH+4:0]
                dsp_product = $signed({1'b0, weight}) * v_code;
            assign product = dsp_product;
        end else begin : g_auto
            wire signed [WEIGHT_WIDTH+4:0] auto_product =
                $signed({1'b0, weight}) * v_code;
            assign product = auto_product;
        end
    endgenerate

`ifndef SYNTHESIS
    initial begin
        if (WEIGHT_WIDTH != 28)
            $error("kv_v03_v5_weight_mul: v0.3 weight width must be 28");
        if (MULT_STYLE < 0 || MULT_STYLE > 2)
            $error("kv_v03_v5_weight_mul: MULT_STYLE must be 0..2");
    end
`endif
endmodule

`default_nettype wire
