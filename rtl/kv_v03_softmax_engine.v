// kv_v03_softmax_engine.v -- score rows plus bit-exact softmax controller.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_softmax_engine #(
    parameter integer MAX_CONTEXT = 4096,
    parameter integer READ_TIMEOUT_CYCLES = 65536
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               score_wr_en,
    input  wire [1:0]         score_wr_row,
    input  wire [11:0]        score_wr_addr,
    input  wire signed [15:0] score_wr_data,
    input  wire               start,
    input  wire [1:0]         score_row,
    input  wire [12:0]        context_len,
    output wire               exp_valid,
    input  wire               exp_ready,
    output wire [11:0]        exp_index,
    output wire [15:0]        exp_code,
    output wire               exp_last,
    output wire               busy,
    output wire               quiescent,
    output wire               done,
    output wire signed [15:0] maximum_score,
    output wire [27:0]        denominator,
    output wire [12:0]        reciprocal_code,
    output wire [4:0]         reciprocal_exponent,
    output wire [12:0]        underflow_count,
    output wire               error_valid,
    output wire [7:0]         error_code
);
    wire score_rd_en, score_rd_valid;
    wire [1:0] score_rd_row;
    wire [11:0] score_rd_addr;
    wire signed [15:0] score_rd_data;

    kv_v03_score_store u_score_store (
        .clk(clk), .wr_en(score_wr_en), .wr_row(score_wr_row),
        .wr_addr(score_wr_addr), .wr_data(score_wr_data),
        .rd_en(score_rd_en), .rd_row(score_rd_row),
        .rd_addr(score_rd_addr), .rd_valid(score_rd_valid),
        .rd_data(score_rd_data)
    );

    kv_v03_softmax #(
        .MAX_CONTEXT(MAX_CONTEXT),
        .READ_TIMEOUT_CYCLES(READ_TIMEOUT_CYCLES)
    ) u_softmax (
        .clk(clk), .rst_n(rst_n), .start(start), .score_row(score_row),
        .context_len(context_len), .score_rd_en(score_rd_en),
        .score_rd_row(score_rd_row), .score_rd_addr(score_rd_addr),
        .score_rd_valid(score_rd_valid), .score_rd_data(score_rd_data),
        .exp_valid(exp_valid), .exp_ready(exp_ready),
        .exp_index(exp_index), .exp_code(exp_code), .exp_last(exp_last),
        .busy(busy), .quiescent(quiescent), .done(done),
        .maximum_score(maximum_score),
        .denominator(denominator), .reciprocal_code(reciprocal_code),
        .reciprocal_exponent(reciprocal_exponent),
        .underflow_count(underflow_count), .error_valid(error_valid),
        .error_code(error_code)
    );
endmodule

`default_nettype wire
