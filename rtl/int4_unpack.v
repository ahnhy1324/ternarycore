// int4_unpack.v -- unpack LSB-first signed two's-complement nibbles.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module int4_unpack #(
    parameter integer LANES     = 16,
    parameter integer OUT_WIDTH = 4
) (
    input  wire [(LANES*4)-1:0]         packed_in,
    output wire [(LANES*OUT_WIDTH)-1:0] unpacked_out
);
    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_unpack
            wire [3:0] nibble = packed_in[(lane*4) +: 4];
            if (OUT_WIDTH == 4) begin : g_native_width
                assign unpacked_out[(lane*OUT_WIDTH) +: OUT_WIDTH] = nibble;
            end else begin : g_sign_extend
                assign unpacked_out[(lane*OUT_WIDTH) +: OUT_WIDTH] =
                    {{(OUT_WIDTH-4){nibble[3]}}, nibble};
            end
        end
    endgenerate

`ifndef SYNTHESIS
    initial if (OUT_WIDTH < 4)
        $error("int4_unpack: OUT_WIDTH must be at least 4");
`endif
endmodule

`default_nettype wire
