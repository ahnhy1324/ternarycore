// kv_v03_reciprocal.v -- normalized unsigned reciprocal by restoring divide.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_reciprocal #(
    parameter integer DENOMINATOR_WIDTH = 28,
    parameter integer FRACTION_BITS = 12
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire [DENOMINATOR_WIDTH-1:0] denominator,
    output reg                          busy,
    output reg                          done,
    output reg  [FRACTION_BITS:0]       reciprocal_code,
    output reg  [4:0]                   reciprocal_exponent,
    output reg                          error_valid,
    output reg  [7:0]                   error_code
);
    localparam integer DIVIDEND_WIDTH =
        DENOMINATOR_WIDTH + FRACTION_BITS + 1;
    localparam [7:0] ERR_ZERO = 8'h01;
    localparam [7:0] ERR_BUSY = 8'h02;

    function [4:0] floor_log2;
        input [DENOMINATOR_WIDTH-1:0] value;
        integer bit_index;
        begin
            floor_log2 = 0;
            for (bit_index = 0; bit_index < DENOMINATOR_WIDTH;
                 bit_index = bit_index + 1)
                if (value[bit_index])
                    floor_log2 = bit_index[4:0];
        end
    endfunction

    wire [4:0] start_exponent = floor_log2(denominator);
    reg [DIVIDEND_WIDTH-1:0] dividend;
    reg [DENOMINATOR_WIDTH-1:0] divisor;
    reg [DIVIDEND_WIDTH-1:0] quotient;
    reg [DENOMINATOR_WIDTH:0] remainder;
    reg [$clog2(DIVIDEND_WIDTH)-1:0] bit_index;

    wire [DENOMINATOR_WIDTH:0] shifted_remainder =
        {remainder[DENOMINATOR_WIDTH-1:0], dividend[bit_index]};
    wire quotient_bit = shifted_remainder >= {1'b0, divisor};
    wire [DENOMINATOR_WIDTH:0] next_remainder = quotient_bit ?
        shifted_remainder - {1'b0, divisor} : shifted_remainder;
    wire [DIVIDEND_WIDTH-1:0] next_quotient = quotient |
        (quotient_bit ? ({{(DIVIDEND_WIDTH-1){1'b0}}, 1'b1} << bit_index) :
                        {DIVIDEND_WIDTH{1'b0}});
    wire [DENOMINATOR_WIDTH+1:0] doubled_remainder =
        {next_remainder, 1'b0};
    wire [DENOMINATOR_WIDTH+1:0] extended_divisor = {2'b0, divisor};
    wire round_up = (doubled_remainder > extended_divisor) ||
                    ((doubled_remainder == extended_divisor) &&
                     next_quotient[0]);

    always @(posedge clk) begin
        if (!rst_n) begin
            busy                <= 1'b0;
            done                <= 1'b0;
            reciprocal_code     <= {(FRACTION_BITS+1){1'b0}};
            reciprocal_exponent <= 5'b0;
            error_valid         <= 1'b0;
            error_code          <= 8'b0;
            dividend            <= {DIVIDEND_WIDTH{1'b0}};
            divisor             <= {DENOMINATOR_WIDTH{1'b0}};
            quotient            <= {DIVIDEND_WIDTH{1'b0}};
            remainder           <= {(DENOMINATOR_WIDTH+1){1'b0}};
            bit_index           <= {$clog2(DIVIDEND_WIDTH){1'b0}};
        end else begin
            done        <= 1'b0;
            error_valid <= 1'b0;
            if (start) begin
                if (busy) begin
                    error_valid <= 1'b1;
                    error_code  <= ERR_BUSY;
                end else if (denominator == 0) begin
                    error_valid <= 1'b1;
                    error_code  <= ERR_ZERO;
                end else begin
                    busy                <= 1'b1;
                    reciprocal_exponent <= start_exponent;
                    dividend <= {{(DIVIDEND_WIDTH-1){1'b0}}, 1'b1} <<
                                (start_exponent + FRACTION_BITS);
                    divisor   <= denominator;
                    quotient  <= {DIVIDEND_WIDTH{1'b0}};
                    remainder <= {(DENOMINATOR_WIDTH+1){1'b0}};
                    bit_index <= DIVIDEND_WIDTH - 1;
                end
            end else if (busy) begin
                quotient  <= next_quotient;
                remainder <= next_remainder;
                if (bit_index == 0) begin
                    reciprocal_code <= next_quotient[FRACTION_BITS:0] +
                                       round_up;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index - 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DENOMINATOR_WIDTH != 28 || FRACTION_BITS != 12)
            $error("kv_v03_reciprocal: v0.3 ABI requires D28/F12");
        if (DIVIDEND_WIDTH > (1 << $clog2(DIVIDEND_WIDTH)))
            $error("kv_v03_reciprocal: invalid bit-index sizing");
    end
`endif
endmodule

`default_nettype wire
