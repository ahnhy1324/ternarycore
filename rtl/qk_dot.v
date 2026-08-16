// qk_dot.v -- P-lane signed fixed-point Q.K accumulator.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module qk_dot #(
    parameter integer LANES     = 16,
    parameter integer Q_WIDTH   = 8,
    parameter integer K_WIDTH   = 20,
    parameter integer ACC_WIDTH = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire in_valid,
    input  wire vector_start,
    input  wire vector_last,
    input  wire [(LANES*Q_WIDTH)-1:0] q_lanes,
    input  wire [(LANES*K_WIDTH)-1:0] k_lanes,
    output reg  out_valid,
    output reg signed [ACC_WIDTH-1:0] result
);
    localparam integer PRODUCT_WIDTH = Q_WIDTH + K_WIDTH;

    wire [(LANES*PRODUCT_WIDTH)-1:0] products;
    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_product
            wire signed [Q_WIDTH-1:0] q =
                q_lanes[(lane*Q_WIDTH) +: Q_WIDTH];
            wire signed [K_WIDTH-1:0] k =
                k_lanes[(lane*K_WIDTH) +: K_WIDTH];
            assign products[(lane*PRODUCT_WIDTH) +: PRODUCT_WIDTH] = q * k;
        end
    endgenerate

    integer i;
    reg signed [ACC_WIDTH-1:0] lane_sum;
    reg signed [ACC_WIDTH-1:0] accumulator;
    always @* begin
        lane_sum = {ACC_WIDTH{1'b0}};
        for (i = 0; i < LANES; i = i + 1)
            lane_sum = lane_sum +
                $signed(products[(i*PRODUCT_WIDTH) +: PRODUCT_WIDTH]);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            accumulator <= {ACC_WIDTH{1'b0}};
            result      <= {ACC_WIDTH{1'b0}};
            out_valid   <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            if (in_valid) begin
                if (vector_start) begin
                    if (vector_last) begin
                        result    <= lane_sum;
                        out_valid <= 1'b1;
                    end else begin
                        accumulator <= lane_sum;
                    end
                end else if (vector_last) begin
                    result    <= accumulator + lane_sum;
                    out_valid <= 1'b1;
                end else begin
                    accumulator <= accumulator + lane_sum;
                end
            end
        end
    end
endmodule

`default_nettype wire
