// kv_v03_scale12_reader.v -- contiguous LSB-first UQ4.8 scale unpacker.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_scale12_reader #(
    parameter integer MAX_SCALES = 128
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [8:0]  expected_scales,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] in_data,
    input  wire [3:0]  in_byte_valid,
    input  wire        in_last,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [11:0] out_scale,
    output wire        busy,
    output reg         done,
    output reg         error_valid,
    output reg  [7:0]  error_code
);
    localparam [7:0] ERR_UNDERFLOW = 8'h01;
    localparam [7:0] ERR_OVERFLOW  = 8'h02;
    localparam [7:0] ERR_PROTOCOL  = 8'h03;

    reg active;
    reg [63:0] reservoir;
    reg [6:0] bit_count;
    reg [8:0] emitted_scales;
    reg [8:0] expected_reg;
    reg saw_last;

    wire pop_scale = out_valid && out_ready;
    wire push_word = in_valid && in_ready;

    assign busy = active;
    assign out_valid = active && (emitted_scales < expected_reg) &&
                       (bit_count >= 12);
    assign out_scale = reservoir[11:0];
    // A 32-bit word can be appended safely at this occupancy. A simultaneous
    // output pop only increases the margin.
    assign in_ready = active && !saw_last && (bit_count <= 32);

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    function [2:0] byte_count;
        input [3:0] mask;
        begin
            case (mask)
                4'b0001: byte_count = 3'd1;
                4'b0011: byte_count = 3'd2;
                4'b0111: byte_count = 3'd3;
                4'b1111: byte_count = 3'd4;
                default: byte_count = 3'd0;
            endcase
        end
    endfunction

    function [31:0] valid_data;
        input [31:0] data;
        input [3:0] mask;
        begin
            case (mask)
                4'b0001: valid_data = data & 32'h000000ff;
                4'b0011: valid_data = data & 32'h0000ffff;
                4'b0111: valid_data = data & 32'h00ffffff;
                4'b1111: valid_data = data;
                default: valid_data = 32'b0;
            endcase
        end
    endfunction

    // A valid byte-packed scale plane leaves at most seven padding bits.  The
    // count>7 case is rejected separately, so only inspect the legal tail.
    function low_tail_nonzero;
        input [63:0] value;
        input [2:0] count;
        begin
            case (count)
                3'd0: low_tail_nonzero = 1'b0;
                3'd1: low_tail_nonzero = value[0];
                3'd2: low_tail_nonzero = |value[1:0];
                3'd3: low_tail_nonzero = |value[2:0];
                3'd4: low_tail_nonzero = |value[3:0];
                3'd5: low_tail_nonzero = |value[4:0];
                3'd6: low_tail_nonzero = |value[5:0];
                default: low_tail_nonzero = |value[6:0];
            endcase
        end
    endfunction

    reg [63:0] work_reservoir;
    reg [6:0] work_bit_count;
    reg [8:0] work_emitted;
    reg work_saw_last;
    integer pushed_bits;
    always @* begin
        work_reservoir = reservoir;
        work_bit_count = bit_count;
        work_emitted = emitted_scales;
        work_saw_last = saw_last;
        pushed_bits = 0;

        if (pop_scale) begin
            work_reservoir = work_reservoir >> 12;
            work_bit_count = work_bit_count - 12;
            work_emitted = work_emitted + 1'b1;
        end

        if (push_word && valid_mask(in_byte_valid)) begin
            pushed_bits = byte_count(in_byte_valid) * 8;
            work_reservoir = work_reservoir |
                ({32'b0, valid_data(in_data, in_byte_valid)} << work_bit_count);
            work_bit_count = work_bit_count + pushed_bits;
            if (in_last)
                work_saw_last = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            active         <= 1'b0;
            reservoir      <= 64'b0;
            bit_count      <= 7'b0;
            emitted_scales <= 9'b0;
            expected_reg   <= 9'b0;
            saw_last       <= 1'b0;
            done           <= 1'b0;
            error_valid    <= 1'b0;
            error_code     <= 8'b0;
        end else begin
            done        <= 1'b0;
            error_valid <= 1'b0;

            if (start) begin
                reservoir      <= 64'b0;
                bit_count      <= 7'b0;
                emitted_scales <= 9'b0;
                expected_reg   <= expected_scales;
                saw_last       <= 1'b0;
                if (expected_scales == 0 || expected_scales > MAX_SCALES) begin
                    active      <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_PROTOCOL;
                end else begin
                    active <= 1'b1;
                end
            end else if (active) begin
                if (push_word && !valid_mask(in_byte_valid)) begin
                    active      <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_PROTOCOL;
                end else begin
                    reservoir      <= work_reservoir;
                    bit_count      <= work_bit_count;
                    emitted_scales <= work_emitted;
                    saw_last       <= work_saw_last;

                    if (work_saw_last && work_emitted < expected_reg &&
                        work_bit_count < 12) begin
                        active      <= 1'b0;
                        error_valid <= 1'b1;
                        error_code  <= ERR_UNDERFLOW;
                    end else if (work_saw_last && work_emitted == expected_reg) begin
                        active <= 1'b0;
                        if (work_bit_count > 7 ||
                            low_tail_nonzero(work_reservoir,
                                             work_bit_count[2:0])) begin
                            error_valid <= 1'b1;
                            error_code  <= ERR_OVERFLOW;
                        end else begin
                            done <= 1'b1;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial if (MAX_SCALES < 1 || MAX_SCALES > 511)
        $error("kv_v03_scale12_reader: MAX_SCALES must be 1..511");
`endif
endmodule

`default_nettype wire
