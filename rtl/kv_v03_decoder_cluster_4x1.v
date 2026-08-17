// kv_v03_decoder_cluster_4x1.v -- four independent one-symbol page tasks.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_decoder_cluster_4x1 #(
    parameter integer MAX_SYMBOLS = 16384
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [3:0]    start,
    input  wire [3:0]    integrity_passed,
    input  wire [3:0]    stream_is_v,
    input  wire [3:0]    raw_mode,
    input  wire [59:0]   expected_symbols,
    input  wire [3:0]    in_valid,
    output wire [3:0]    in_ready,
    input  wire [127:0]  in_data,
    input  wire [15:0]   in_byte_valid,
    input  wire [3:0]    in_last,
    output wire [3:0]    out_valid,
    input  wire [3:0]    out_ready,
    output wire [19:0]   out_symbol,
    output wire [3:0]    out_last,
    output wire [3:0]    busy,
    output wire [3:0]    done,
    output wire [3:0]    error_valid,
    output wire [31:0]   error_code
);
    // Each lane consumes and validates one complete page.  Four lanes retain
    // the 2x2 cluster's aggregate four-symbol/cycle rate without placing two
    // dependent variable-length prefix lookups in one timing path.
    wire [7:0] unused_count;
    wire [19:0] unused_symbol1;
    genvar engine;
    generate
        for (engine = 0; engine < 4; engine = engine + 1) begin : g_engine
            kv_v03_symbol_decoder #(
                .SYMBOL_WIDTH(4),
                .STREAM_IS_V(0),
                .RUNTIME_STREAM_SELECT(1),
                .SYMBOLS_PER_CYCLE(1),
                .MAX_SYMBOLS(MAX_SYMBOLS)
            ) u_decoder (
                .clk(clk), .rst_n(rst_n), .start(start[engine]),
                .integrity_passed(integrity_passed[engine]),
                .stream_is_v(stream_is_v[engine]),
                .raw_mode(raw_mode[engine]),
                .expected_symbols(expected_symbols[(engine*15) +: 15]),
                .in_valid(in_valid[engine]),
                .in_ready(in_ready[engine]),
                .in_data(in_data[(engine*32) +: 32]),
                .in_byte_valid(in_byte_valid[(engine*4) +: 4]),
                .in_last(in_last[engine]),
                .out_valid(out_valid[engine]),
                .out_ready(out_ready[engine]),
                .out_count(unused_count[(engine*2) +: 2]),
                .out_symbol0(out_symbol[(engine*5) +: 5]),
                .out_symbol1(unused_symbol1[(engine*5) +: 5]),
                .out_last(out_last[engine]), .busy(busy[engine]),
                .done(done[engine]), .error_valid(error_valid[engine]),
                .error_code(error_code[(engine*8) +: 8])
            );
        end
    endgenerate

`ifndef SYNTHESIS
    // The wrapper relies on every one-symbol lane advertising exactly one
    // item whenever it is valid.
    always @(posedge clk)
        if (rst_n && |(out_valid & out_ready)) begin : p_count_contract
            integer lane;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (out_valid[lane] && out_ready[lane] &&
                    unused_count[(lane*2) +: 2] != 1)
                    $fatal(1, "kv_v03_decoder_cluster_4x1: bad lane count");
        end
`endif
endmodule

`default_nettype wire
