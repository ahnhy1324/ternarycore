// kv_v03_score_store.v -- four synchronous 4096x16 signed score rows.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_score_row (
    input  wire               clk,
    input  wire               wr_en,
    input  wire [11:0]        wr_addr,
    input  wire signed [15:0] wr_data,
    input  wire               rd_en,
    input  wire [11:0]        rd_addr,
    output reg signed [15:0]  rd_data
);
    // Isolating each row gives Vivado one unambiguous simple-dual-port RAM.
    // One 4096x16 row maps to two RAMB36E1 blocks on 7-series devices.
    (* ram_style = "block" *) reg signed [15:0] memory [0:4095];

    always @(posedge clk) begin
        if (wr_en)
            memory[wr_addr] <= wr_data;
        if (rd_en)
            rd_data <= memory[rd_addr];
    end
endmodule

module kv_v03_score_store (
    input  wire               clk,
    input  wire               wr_en,
    input  wire [1:0]         wr_row,
    input  wire [11:0]        wr_addr,
    input  wire signed [15:0] wr_data,
    input  wire               rd_en,
    input  wire [1:0]         rd_row,
    input  wire [11:0]        rd_addr,
    output reg                rd_valid,
    output wire signed [15:0] rd_data
);
    reg [1:0] response_row;
    wire signed [15:0] row0_data, row1_data, row2_data, row3_data;

    kv_v03_score_row u_row0 (
        .clk(clk), .wr_en(wr_en && wr_row == 0), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(rd_en && rd_row == 0),
        .rd_addr(rd_addr), .rd_data(row0_data));
    kv_v03_score_row u_row1 (
        .clk(clk), .wr_en(wr_en && wr_row == 1), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(rd_en && rd_row == 1),
        .rd_addr(rd_addr), .rd_data(row1_data));
    kv_v03_score_row u_row2 (
        .clk(clk), .wr_en(wr_en && wr_row == 2), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(rd_en && rd_row == 2),
        .rd_addr(rd_addr), .rd_data(row2_data));
    kv_v03_score_row u_row3 (
        .clk(clk), .wr_en(wr_en && wr_row == 3), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(rd_en && rd_row == 3),
        .rd_addr(rd_addr), .rd_data(row3_data));

    assign rd_data = (response_row == 0) ? row0_data :
                     (response_row == 1) ? row1_data :
                     (response_row == 2) ? row2_data : row3_data;

    always @(posedge clk) begin
        rd_valid <= rd_en;
        if (rd_en)
            response_row <= rd_row;
    end
endmodule

`default_nettype wire
