// tb_kv_dequant.v -- exact signed INT4 times Q8.8 scale regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_dequant;
    localparam LANES = 16, OUT_WIDTH = 20;
    reg  [(LANES*4)-1:0] quant_in;
    reg signed [15:0] scale;
    wire [(LANES*OUT_WIDTH)-1:0] dequant_out;
    integer i, got, want, q, errors = 0;

    kv_dequant #(
        .LANES(LANES), .IN_WIDTH(4), .SCALE_WIDTH(16),
        .OUT_WIDTH(OUT_WIDTH)
    ) dut (
        .quant_in(quant_in), .scale(scale), .dequant_out(dequant_out)
    );

    initial begin
        quant_in = 0;
        scale = 16'sh0100;
        for (i = 0; i < LANES; i = i + 1)
            quant_in[(i*4) +: 4] = i[3:0];
        #1;
        for (i = 0; i < LANES; i = i + 1) begin
            q = (i < 8) ? i : i - 16;
            got = $signed(dequant_out[(i*OUT_WIDTH) +: OUT_WIDTH]);
            want = q * 256;
            if (got != want) begin
                $display("FAIL q=%0d: got %0d want %0d", q, got, want);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("TB PASS: INT4 Q8.8 dequant");
        else $display("TB FAIL: %0d dequant errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
