// kv_dequant.v -- apply one signed fixed-point scale to parallel INT4 lanes.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_dequant #(
    parameter integer LANES       = 16,
    parameter integer IN_WIDTH    = 4,
    parameter integer SCALE_WIDTH = 16,
    parameter integer OUT_WIDTH   = IN_WIDTH + SCALE_WIDTH
) (
    input  wire [(LANES*IN_WIDTH)-1:0]  quant_in,
    input  wire signed [SCALE_WIDTH-1:0] scale,
    output wire [(LANES*OUT_WIDTH)-1:0] dequant_out
);
    localparam integer PRODUCT_WIDTH = IN_WIDTH + SCALE_WIDTH;
    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_dequant
            wire signed [IN_WIDTH-1:0] q =
                quant_in[(lane*IN_WIDTH) +: IN_WIDTH];
            wire signed [PRODUCT_WIDTH-1:0] product = q * scale;
            assign dequant_out[(lane*OUT_WIDTH) +: OUT_WIDTH] =
                {{(OUT_WIDTH-PRODUCT_WIDTH){product[PRODUCT_WIDTH-1]}}, product};
        end
    endgenerate

`ifndef SYNTHESIS
    initial if (OUT_WIDTH < PRODUCT_WIDTH)
        $error("kv_dequant: OUT_WIDTH must hold IN_WIDTH+SCALE_WIDTH");
`endif
endmodule

`default_nettype wire
