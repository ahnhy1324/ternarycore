// kv_v03_v5_decoder.v -- V5 specialization of the PACKED5 page decoder.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_v5_decoder (
    input  wire clk, input wire rst_n, input wire start,
    input  wire integrity_passed, input wire raw_mode,
    input  wire [14:0] expected_symbols,
    input  wire in_valid, output wire in_ready,
    input  wire [31:0] in_data, input wire [3:0] in_byte_valid,
    input  wire in_last,
    output wire out_valid, input wire out_ready,
    output wire [1:0] out_count,
    output wire signed [4:0] out_symbol0,
    output wire signed [4:0] out_symbol1,
    output wire out_last, output wire busy, output wire done,
    output wire error_valid, output wire [7:0] error_code
);
    kv_v03_symbol_decoder #(
        .SYMBOL_WIDTH(5), .STREAM_IS_V(1), .MAX_SYMBOLS(16384)
    ) u_decoder (
        .clk(clk), .rst_n(rst_n), .start(start),
        .integrity_passed(integrity_passed), .stream_is_v(1'b1),
        .raw_mode(raw_mode),
        .expected_symbols(expected_symbols), .in_valid(in_valid),
        .in_ready(in_ready), .in_data(in_data),
        .in_byte_valid(in_byte_valid), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready), .out_count(out_count),
        .out_symbol0(out_symbol0), .out_symbol1(out_symbol1),
        .out_last(out_last), .busy(busy), .done(done),
        .error_valid(error_valid), .error_code(error_code)
    );
endmodule

`default_nettype wire
