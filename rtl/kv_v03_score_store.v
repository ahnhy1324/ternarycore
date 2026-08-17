// kv_v03_score_store.v -- four synchronous 4096x16 signed score rows.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

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
    output reg signed [15:0]  rd_data
);
    (* ram_style = "block" *) reg signed [15:0] score_row0 [0:4095];
    (* ram_style = "block" *) reg signed [15:0] score_row1 [0:4095];
    (* ram_style = "block" *) reg signed [15:0] score_row2 [0:4095];
    (* ram_style = "block" *) reg signed [15:0] score_row3 [0:4095];

    always @(posedge clk) begin
        rd_valid <= rd_en;
        if (wr_en) begin
            case (wr_row)
                2'd0: score_row0[wr_addr] <= wr_data;
                2'd1: score_row1[wr_addr] <= wr_data;
                2'd2: score_row2[wr_addr] <= wr_data;
                2'd3: score_row3[wr_addr] <= wr_data;
            endcase
        end
        if (rd_en) begin
            case (rd_row)
                2'd0: rd_data <= score_row0[rd_addr];
                2'd1: rd_data <= score_row1[rd_addr];
                2'd2: rd_data <= score_row2[rd_addr];
                default: rd_data <= score_row3[rd_addr];
            endcase
        end
    end
endmodule

`default_nettype wire
