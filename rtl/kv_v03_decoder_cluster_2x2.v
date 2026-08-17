// kv_v03_decoder_cluster_2x2.v -- two independent two-symbol page tasks.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_decoder_cluster_2x2 #(
    parameter integer MAX_SYMBOLS = 16384
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [1:0]   start,
    input  wire [1:0]   integrity_passed,
    input  wire [1:0]   stream_is_v,
    input  wire [1:0]   raw_mode,
    input  wire [29:0]  expected_symbols,
    input  wire [1:0]   in_valid,
    output wire [1:0]   in_ready,
    input  wire [63:0]  in_data,
    input  wire [7:0]   in_byte_valid,
    input  wire [1:0]   in_last,
    output wire [1:0]   out_valid,
    input  wire [1:0]   out_ready,
    output wire [3:0]   out_count,
    output wire [9:0]   out_symbol0,
    output wire [9:0]   out_symbol1,
    output wire [1:0]   out_last,
    output wire [1:0]   busy,
    output wire [1:0]   done,
    output wire [1:0]   error_valid,
    output wire [15:0]  error_code
);
    // Each lane owns an entire compressed page task. The cluster never splits
    // one prefix stream at an arbitrary byte boundary, preserving the v0.3
    // compression contract while producing four aggregate symbols per cycle.
    genvar engine;
    generate
        for (engine = 0; engine < 2; engine = engine + 1) begin : g_engine
            kv_v03_symbol_decoder #(
                .SYMBOL_WIDTH(4),
                .STREAM_IS_V(0),
                .RUNTIME_STREAM_SELECT(1),
                .MAX_SYMBOLS(MAX_SYMBOLS)
            ) u_decoder (
                .clk(clk), .rst_n(rst_n), .start(start[engine]),
                .integrity_passed(integrity_passed[engine]),
                .stream_is_v(stream_is_v[engine]),
                .raw_mode(raw_mode[engine]),
                .expected_symbols(
                    expected_symbols[(engine*15) +: 15]),
                .in_valid(in_valid[engine]),
                .in_ready(in_ready[engine]),
                .in_data(in_data[(engine*32) +: 32]),
                .in_byte_valid(
                    in_byte_valid[(engine*4) +: 4]),
                .in_last(in_last[engine]),
                .out_valid(out_valid[engine]),
                .out_ready(out_ready[engine]),
                .out_count(out_count[(engine*2) +: 2]),
                .out_symbol0(out_symbol0[(engine*5) +: 5]),
                .out_symbol1(out_symbol1[(engine*5) +: 5]),
                .out_last(out_last[engine]), .busy(busy[engine]),
                .done(done[engine]), .error_valid(error_valid[engine]),
                .error_code(error_code[(engine*8) +: 8])
            );
        end
    endgenerate
endmodule

`default_nettype wire
