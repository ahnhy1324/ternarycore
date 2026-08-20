// tb_kv_v03_v5_weight_mul.v -- exhaustive legal V5 CSD/DSP/AUTO equivalence.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_v5_weight_mul;
    reg [27:0] weight_uq48 = 0;
    reg [31:0] weight_uq511 = 0;
    reg signed [4:0] v_code = 0;
    wire signed [32:0] product12_csd, product12_dsp, product12_auto;
    wire signed [36:0] product16_csd, product16_dsp, product16_auto;
    reg [27:0] weights_uq48 [0:8];
    reg [31:0] weights_uq511 [0:8];
    reg signed [63:0] expected;
    integer weight_index, code_integer, errors = 0;

    kv_v03_v5_weight_mul #(.MULT_STYLE(0)) u_csd (
        .weight(weight_uq48), .v_code(v_code), .product(product12_csd));
    kv_v03_v5_weight_mul #(.MULT_STYLE(1)) u_dsp (
        .weight(weight_uq48), .v_code(v_code), .product(product12_dsp));
    kv_v03_v5_weight_mul #(.MULT_STYLE(2)) u_auto (
        .weight(weight_uq48), .v_code(v_code), .product(product12_auto));
    kv_v03_v5_weight_mul #(.WEIGHT_WIDTH(32), .MULT_STYLE(0)) u16_csd (
        .weight(weight_uq511), .v_code(v_code), .product(product16_csd));
    kv_v03_v5_weight_mul #(.WEIGHT_WIDTH(32), .MULT_STYLE(1)) u16_dsp (
        .weight(weight_uq511), .v_code(v_code), .product(product16_dsp));
    kv_v03_v5_weight_mul #(.WEIGHT_WIDTH(32), .MULT_STYLE(2)) u16_auto (
        .weight(weight_uq511), .v_code(v_code), .product(product16_auto));

    initial begin
        weights_uq48[0] = 0;
        weights_uq48[1] = 1;
        weights_uq48[2] = 17;
        weights_uq48[3] = 32768;
        weights_uq48[4] = 28'h001ffff;
        weights_uq48[5] = 28'h07fffff;
        weights_uq48[6] = 28'd134184960; // max exp(0) x UQ4.8 scale
        weights_uq48[7] = 28'h0fffffe;
        weights_uq48[8] = 28'hfffffff;
        for (weight_index = 0; weight_index < 9;
             weight_index = weight_index + 1) begin
            for (code_integer = -15; code_integer <= 15;
                 code_integer = code_integer + 1) begin
                weight_uq48 = weights_uq48[weight_index];
                v_code = code_integer;
                expected = $signed({1'b0, weights_uq48[weight_index]}) *
                           code_integer;
                #1;
                if ($signed(product12_csd) !== expected ||
                    $signed(product12_dsp) !== expected ||
                    $signed(product12_auto) !== expected) begin
                    $display("FAIL V5 multiply w=%0d code=%0d csd=%0d dsp=%0d auto=%0d want=%0d",
                             weight_uq48, code_integer, product12_csd,
                             product12_dsp, product12_auto, expected);
                    errors = errors + 1;
                end
            end
        end

        // UQ5.11 makes exp_code*scale_code 32 bits.  Include the legal
        // 0x8000*0xffff boundary as well as the full unsigned multiplier
        // boundary so no upper product bits can be silently discarded.
        weights_uq511[0] = 0;
        weights_uq511[1] = 1;
        weights_uq511[2] = 17;
        weights_uq511[3] = 65535;
        weights_uq511[4] = 32'h0001_0000;
        weights_uq511[5] = 32'h07ff_ffff;
        weights_uq511[6] = 32'd2147450880; // 16'h8000 * 16'hffff
        weights_uq511[7] = 32'hffff_fffe;
        weights_uq511[8] = 32'hffff_ffff;
        for (weight_index = 0; weight_index < 9;
             weight_index = weight_index + 1) begin
            for (code_integer = -15; code_integer <= 15;
                 code_integer = code_integer + 1) begin
                weight_uq511 = weights_uq511[weight_index];
                v_code = code_integer;
                expected = $signed({1'b0, weights_uq511[weight_index]}) *
                           code_integer;
                #1;
                if ($signed(product16_csd) !== expected ||
                    $signed(product16_dsp) !== expected ||
                    $signed(product16_auto) !== expected) begin
                    $display("FAIL V5 UQ5.11 multiply w=%0d code=%0d csd=%0d dsp=%0d auto=%0d want=%0d",
                             weight_uq511, code_integer, product16_csd,
                             product16_dsp, product16_auto, expected);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0) begin
            $display("TB PASS: v0.3 V5 multiply 558 UQ4.8/UQ5.11 cases");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 V5 multiply errors=%0d", errors);
    end
endmodule

`default_nettype wire
