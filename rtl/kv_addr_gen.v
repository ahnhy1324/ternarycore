// kv_addr_gen.v -- byte address for a row-major KV vector.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_addr_gen #(
    parameter integer ADDR_WIDTH   = 32,
    parameter integer TOKEN_WIDTH  = 12,
    parameter integer VECTOR_BYTES = 32
) (
    input  wire [ADDR_WIDTH-1:0]  base_addr,
    input  wire [TOKEN_WIDTH-1:0] token_index,
    output wire [ADDR_WIDTH-1:0]  vector_addr
);
    localparam integer VECTOR_SHIFT = $clog2(VECTOR_BYTES);
    wire [ADDR_WIDTH-1:0] token_ext =
        {{(ADDR_WIDTH-TOKEN_WIDTH){1'b0}}, token_index};

    // VECTOR_BYTES is a power of two for all supported INT4 geometries.
    assign vector_addr = base_addr + (token_ext << VECTOR_SHIFT);

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH < TOKEN_WIDTH)
            $error("kv_addr_gen: ADDR_WIDTH must be >= TOKEN_WIDTH");
        if ((1 << VECTOR_SHIFT) != VECTOR_BYTES)
            $error("kv_addr_gen: VECTOR_BYTES must be a power of two");
    end
`endif
endmodule

`default_nettype wire
