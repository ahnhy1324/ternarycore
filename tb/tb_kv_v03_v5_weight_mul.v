// tb_kv_v03_v5_weight_mul.v -- exhaustive legal V5 CSD/DSP/AUTO equivalence.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_v5_weight_mul;
    reg [27:0] weight = 0;
    reg signed [4:0] v_code = 0;
    wire signed [32:0] product_csd, product_dsp, product_auto;
    reg [27:0] weights [0:8];
    reg signed [63:0] expected;
    integer weight_index, code_integer, errors = 0;

    kv_v03_v5_weight_mul #(.MULT_STYLE(0)) u_csd (
        .weight(weight), .v_code(v_code), .product(product_csd));
    kv_v03_v5_weight_mul #(.MULT_STYLE(1)) u_dsp (
        .weight(weight), .v_code(v_code), .product(product_dsp));
    kv_v03_v5_weight_mul #(.MULT_STYLE(2)) u_auto (
        .weight(weight), .v_code(v_code), .product(product_auto));

    initial begin
        weights[0] = 0;
        weights[1] = 1;
        weights[2] = 17;
        weights[3] = 32768;
        weights[4] = 28'h001ffff;
        weights[5] = 28'h07fffff;
        weights[6] = 28'd134184960; // max exp(0) x UQ4.8 scale
        weights[7] = 28'h0fffffe;
        weights[8] = 28'hfffffff;
        for (weight_index = 0; weight_index < 9;
             weight_index = weight_index + 1) begin
            for (code_integer = -15; code_integer <= 15;
                 code_integer = code_integer + 1) begin
                weight = weights[weight_index];
                v_code = code_integer;
                expected = $signed({1'b0, weights[weight_index]}) *
                           code_integer;
                #1;
                if ($signed(product_csd) !== expected ||
                    $signed(product_dsp) !== expected ||
                    $signed(product_auto) !== expected) begin
                    $display("FAIL V5 multiply w=%0d code=%0d csd=%0d dsp=%0d auto=%0d want=%0d",
                             weight, code_integer, product_csd, product_dsp,
                             product_auto, expected);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0) begin
            $display("TB PASS: v0.3 V5 multiply 279 legal/boundary cases");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 V5 multiply errors=%0d", errors);
    end
endmodule

`default_nettype wire
