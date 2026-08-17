// kv_v03_crc32.v -- streaming reflected CRC-32/ISO-HDLC.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_crc32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] in_data,
    input  wire [3:0]  in_byte_valid,
    input  wire        in_last,
    output reg         crc_valid,
    output reg  [31:0] crc,
    output reg         protocol_error
);
    localparam [31:0] CRC_INIT = 32'hffff_ffff;
    localparam [31:0] CRC_XOROUT = 32'hffff_ffff;
    localparam [31:0] CRC_POLY_REFLECTED = 32'hedb8_8320;

    reg [31:0] crc_state;
    reg active;
    reg [31:0] next_crc;

    function [31:0] crc_byte;
        input [31:0] state;
        input [7:0] data;
        reg [31:0] work;
        integer bit_index;
        begin
            work = state;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (work[0] ^ data[bit_index])
                    work = (work >> 1) ^ CRC_POLY_REFLECTED;
                else
                    work = work >> 1;
            end
            crc_byte = work;
        end
    endfunction

    function [31:0] crc_word;
        input [31:0] state;
        input [31:0] data;
        input [3:0] valid_bytes;
        reg [31:0] work;
        integer byte_index;
        begin
            work = state;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (valid_bytes[byte_index])
                    work = crc_byte(work, data[(byte_index*8) +: 8]);
            crc_word = work;
        end
    endfunction

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    assign in_ready = active || start;

    always @(posedge clk) begin
        if (!rst_n) begin
            crc_state      <= CRC_INIT;
            active         <= 1'b0;
            crc_valid      <= 1'b0;
            crc            <= 32'b0;
            protocol_error <= 1'b0;
        end else begin
            crc_valid      <= 1'b0;
            protocol_error <= 1'b0;

            if (start) begin
                crc_state <= CRC_INIT;
                active    <= 1'b1;
            end

            if (in_valid) begin
                if (!(active || start) || !valid_mask(in_byte_valid)) begin
                    active         <= 1'b0;
                    protocol_error <= 1'b1;
                end else begin
                    next_crc = crc_word(start ? CRC_INIT : crc_state,
                                        in_data, in_byte_valid);
                    crc_state <= next_crc;
                    if (in_last) begin
                        crc       <= next_crc ^ CRC_XOROUT;
                        crc_valid <= 1'b1;
                        active    <= 1'b0;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
