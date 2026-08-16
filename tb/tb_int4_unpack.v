// tb_int4_unpack.v -- signed nibble order and sign-extension regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_int4_unpack;
    localparam LANES = 16;
    reg  [(LANES*4)-1:0] packed_in;
    wire [(LANES*4)-1:0] unpacked_out;
    integer i, got, want, errors = 0;

    int4_unpack #(.LANES(LANES), .OUT_WIDTH(4)) dut (
        .packed_in(packed_in), .unpacked_out(unpacked_out)
    );

    initial begin
        packed_in = 0;
        for (i = 0; i < LANES; i = i + 1)
            packed_in[(i*4) +: 4] = i[3:0];
        #1;
        for (i = 0; i < LANES; i = i + 1) begin
            got  = $signed(unpacked_out[(i*4) +: 4]);
            want = (i < 8) ? i : i - 16;
            if (got != want) begin
                $display("FAIL lane %0d: got %0d want %0d", i, got, want);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("TB PASS: signed INT4 unpack");
        else $display("TB FAIL: %0d INT4 unpack errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
