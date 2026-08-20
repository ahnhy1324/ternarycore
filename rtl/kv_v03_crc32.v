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
    reg [31:0] crc_state;
    reg active;
    reg [31:0] next_crc;

    // Parallel linear transforms for one through four little-endian bytes.
    // The reduction-XOR equations are algebraically equivalent to the
    // reflected bit-serial recurrence but synthesize as shallow XOR trees.
    function [31:0] crc_1byte;
        input [31:0] state;
        input [31:0] data;
        begin
            crc_1byte[0] = ^{state[2], state[8], data[2]};
            crc_1byte[1] = ^{state[0], state[3], state[9], data[0], data[3]};
            crc_1byte[2] = ^{state[0], state[1], state[4], state[10], data[0], data[1], data[4]};
            crc_1byte[3] = ^{state[1], state[2], state[5], state[11], data[1], data[2], data[5]};
            crc_1byte[4] = ^{state[0], state[2], state[3], state[6], state[12], data[0], data[2], data[3], data[6]};
            crc_1byte[5] = ^{state[1], state[3], state[4], state[7], state[13], data[1], data[3], data[4], data[7]};
            crc_1byte[6] = ^{state[4], state[5], state[14], data[4], data[5]};
            crc_1byte[7] = ^{state[0], state[5], state[6], state[15], data[0], data[5], data[6]};
            crc_1byte[8] = ^{state[1], state[6], state[7], state[16], data[1], data[6], data[7]};
            crc_1byte[9] = ^{state[7], state[17], data[7]};
            crc_1byte[10] = ^{state[2], state[18], data[2]};
            crc_1byte[11] = ^{state[3], state[19], data[3]};
            crc_1byte[12] = ^{state[0], state[4], state[20], data[0], data[4]};
            crc_1byte[13] = ^{state[0], state[1], state[5], state[21], data[0], data[1], data[5]};
            crc_1byte[14] = ^{state[1], state[2], state[6], state[22], data[1], data[2], data[6]};
            crc_1byte[15] = ^{state[2], state[3], state[7], state[23], data[2], data[3], data[7]};
            crc_1byte[16] = ^{state[0], state[2], state[3], state[4], state[24], data[0], data[2], data[3], data[4]};
            crc_1byte[17] = ^{state[0], state[1], state[3], state[4], state[5], state[25], data[0], data[1], data[3], data[4], data[5]};
            crc_1byte[18] = ^{state[0], state[1], state[2], state[4], state[5], state[6], state[26], data[0], data[1], data[2], data[4], data[5], data[6]};
            crc_1byte[19] = ^{state[1], state[2], state[3], state[5], state[6], state[7], state[27], data[1], data[2], data[3], data[5], data[6], data[7]};
            crc_1byte[20] = ^{state[3], state[4], state[6], state[7], state[28], data[3], data[4], data[6], data[7]};
            crc_1byte[21] = ^{state[2], state[4], state[5], state[7], state[29], data[2], data[4], data[5], data[7]};
            crc_1byte[22] = ^{state[2], state[3], state[5], state[6], state[30], data[2], data[3], data[5], data[6]};
            crc_1byte[23] = ^{state[3], state[4], state[6], state[7], state[31], data[3], data[4], data[6], data[7]};
            crc_1byte[24] = ^{state[0], state[2], state[4], state[5], state[7], data[0], data[2], data[4], data[5], data[7]};
            crc_1byte[25] = ^{state[0], state[1], state[2], state[3], state[5], state[6], data[0], data[1], data[2], data[3], data[5], data[6]};
            crc_1byte[26] = ^{state[0], state[1], state[2], state[3], state[4], state[6], state[7], data[0], data[1], data[2], data[3], data[4], data[6], data[7]};
            crc_1byte[27] = ^{state[1], state[3], state[4], state[5], state[7], data[1], data[3], data[4], data[5], data[7]};
            crc_1byte[28] = ^{state[0], state[4], state[5], state[6], data[0], data[4], data[5], data[6]};
            crc_1byte[29] = ^{state[0], state[1], state[5], state[6], state[7], data[0], data[1], data[5], data[6], data[7]};
            crc_1byte[30] = ^{state[0], state[1], state[6], state[7], data[0], data[1], data[6], data[7]};
            crc_1byte[31] = ^{state[1], state[7], data[1], data[7]};
        end
    endfunction

    function [31:0] crc_2byte;
        input [31:0] state;
        input [31:0] data;
        begin
            crc_2byte[0] = ^{state[0], state[4], state[6], state[7], state[10], state[16], data[0], data[4], data[6], data[7], data[10]};
            crc_2byte[1] = ^{state[1], state[5], state[7], state[8], state[11], state[17], data[1], data[5], data[7], data[8], data[11]};
            crc_2byte[2] = ^{state[2], state[6], state[8], state[9], state[12], state[18], data[2], data[6], data[8], data[9], data[12]};
            crc_2byte[3] = ^{state[3], state[7], state[9], state[10], state[13], state[19], data[3], data[7], data[9], data[10], data[13]};
            crc_2byte[4] = ^{state[4], state[8], state[10], state[11], state[14], state[20], data[4], data[8], data[10], data[11], data[14]};
            crc_2byte[5] = ^{state[5], state[9], state[11], state[12], state[15], state[21], data[5], data[9], data[11], data[12], data[15]};
            crc_2byte[6] = ^{state[0], state[4], state[7], state[12], state[13], state[22], data[0], data[4], data[7], data[12], data[13]};
            crc_2byte[7] = ^{state[1], state[5], state[8], state[13], state[14], state[23], data[1], data[5], data[8], data[13], data[14]};
            crc_2byte[8] = ^{state[0], state[2], state[6], state[9], state[14], state[15], state[24], data[0], data[2], data[6], data[9], data[14], data[15]};
            crc_2byte[9] = ^{state[1], state[3], state[4], state[6], state[15], state[25], data[1], data[3], data[4], data[6], data[15]};
            crc_2byte[10] = ^{state[2], state[5], state[6], state[10], state[26], data[2], data[5], data[6], data[10]};
            crc_2byte[11] = ^{state[3], state[6], state[7], state[11], state[27], data[3], data[6], data[7], data[11]};
            crc_2byte[12] = ^{state[0], state[4], state[7], state[8], state[12], state[28], data[0], data[4], data[7], data[8], data[12]};
            crc_2byte[13] = ^{state[0], state[1], state[5], state[8], state[9], state[13], state[29], data[0], data[1], data[5], data[8], data[9], data[13]};
            crc_2byte[14] = ^{state[1], state[2], state[6], state[9], state[10], state[14], state[30], data[1], data[2], data[6], data[9], data[10], data[14]};
            crc_2byte[15] = ^{state[2], state[3], state[7], state[10], state[11], state[15], state[31], data[2], data[3], data[7], data[10], data[11], data[15]};
            crc_2byte[16] = ^{state[0], state[3], state[6], state[7], state[8], state[10], state[11], state[12], data[0], data[3], data[6], data[7], data[8], data[10], data[11], data[12]};
            crc_2byte[17] = ^{state[0], state[1], state[4], state[7], state[8], state[9], state[11], state[12], state[13], data[0], data[1], data[4], data[7], data[8], data[9], data[11], data[12], data[13]};
            crc_2byte[18] = ^{state[1], state[2], state[5], state[8], state[9], state[10], state[12], state[13], state[14], data[1], data[2], data[5], data[8], data[9], data[10], data[12], data[13], data[14]};
            crc_2byte[19] = ^{state[0], state[2], state[3], state[6], state[9], state[10], state[11], state[13], state[14], state[15], data[0], data[2], data[3], data[6], data[9], data[10], data[11], data[13], data[14], data[15]};
            crc_2byte[20] = ^{state[0], state[1], state[3], state[6], state[11], state[12], state[14], state[15], data[0], data[1], data[3], data[6], data[11], data[12], data[14], data[15]};
            crc_2byte[21] = ^{state[1], state[2], state[6], state[10], state[12], state[13], state[15], data[1], data[2], data[6], data[10], data[12], data[13], data[15]};
            crc_2byte[22] = ^{state[2], state[3], state[4], state[6], state[10], state[11], state[13], state[14], data[2], data[3], data[4], data[6], data[10], data[11], data[13], data[14]};
            crc_2byte[23] = ^{state[3], state[4], state[5], state[7], state[11], state[12], state[14], state[15], data[3], data[4], data[5], data[7], data[11], data[12], data[14], data[15]};
            crc_2byte[24] = ^{state[0], state[5], state[7], state[8], state[10], state[12], state[13], state[15], data[0], data[5], data[7], data[8], data[10], data[12], data[13], data[15]};
            crc_2byte[25] = ^{state[1], state[4], state[7], state[8], state[9], state[10], state[11], state[13], state[14], data[1], data[4], data[7], data[8], data[9], data[10], data[11], data[13], data[14]};
            crc_2byte[26] = ^{state[2], state[5], state[8], state[9], state[10], state[11], state[12], state[14], state[15], data[2], data[5], data[8], data[9], data[10], data[11], data[12], data[14], data[15]};
            crc_2byte[27] = ^{state[0], state[3], state[4], state[7], state[9], state[11], state[12], state[13], state[15], data[0], data[3], data[4], data[7], data[9], data[11], data[12], data[13], data[15]};
            crc_2byte[28] = ^{state[0], state[1], state[5], state[6], state[7], state[8], state[12], state[13], state[14], data[0], data[1], data[5], data[6], data[7], data[8], data[12], data[13], data[14]};
            crc_2byte[29] = ^{state[1], state[2], state[6], state[7], state[8], state[9], state[13], state[14], state[15], data[1], data[2], data[6], data[7], data[8], data[9], data[13], data[14], data[15]};
            crc_2byte[30] = ^{state[2], state[3], state[4], state[6], state[8], state[9], state[14], state[15], data[2], data[3], data[4], data[6], data[8], data[9], data[14], data[15]};
            crc_2byte[31] = ^{state[3], state[5], state[6], state[9], state[15], data[3], data[5], data[6], data[9], data[15]};
        end
    endfunction

    function [31:0] crc_3byte;
        input [31:0] state;
        input [31:0] data;
        begin
            crc_3byte[0] = ^{state[0], state[8], state[12], state[14], state[15], state[18], state[24], data[0], data[8], data[12], data[14], data[15], data[18]};
            crc_3byte[1] = ^{state[0], state[1], state[9], state[13], state[15], state[16], state[19], state[25], data[0], data[1], data[9], data[13], data[15], data[16], data[19]};
            crc_3byte[2] = ^{state[0], state[1], state[2], state[10], state[14], state[16], state[17], state[20], state[26], data[0], data[1], data[2], data[10], data[14], data[16], data[17], data[20]};
            crc_3byte[3] = ^{state[1], state[2], state[3], state[11], state[15], state[17], state[18], state[21], state[27], data[1], data[2], data[3], data[11], data[15], data[17], data[18], data[21]};
            crc_3byte[4] = ^{state[0], state[2], state[3], state[4], state[12], state[16], state[18], state[19], state[22], state[28], data[0], data[2], data[3], data[4], data[12], data[16], data[18], data[19], data[22]};
            crc_3byte[5] = ^{state[0], state[1], state[3], state[4], state[5], state[13], state[17], state[19], state[20], state[23], state[29], data[0], data[1], data[3], data[4], data[5], data[13], data[17], data[19], data[20], data[23]};
            crc_3byte[6] = ^{state[1], state[2], state[4], state[5], state[6], state[8], state[12], state[15], state[20], state[21], state[30], data[1], data[2], data[4], data[5], data[6], data[8], data[12], data[15], data[20], data[21]};
            crc_3byte[7] = ^{state[2], state[3], state[5], state[6], state[7], state[9], state[13], state[16], state[21], state[22], state[31], data[2], data[3], data[5], data[6], data[7], data[9], data[13], data[16], data[21], data[22]};
            crc_3byte[8] = ^{state[3], state[4], state[6], state[7], state[8], state[10], state[14], state[17], state[22], state[23], data[3], data[4], data[6], data[7], data[8], data[10], data[14], data[17], data[22], data[23]};
            crc_3byte[9] = ^{state[0], state[4], state[5], state[7], state[9], state[11], state[12], state[14], state[23], data[0], data[4], data[5], data[7], data[9], data[11], data[12], data[14], data[23]};
            crc_3byte[10] = ^{state[1], state[5], state[6], state[10], state[13], state[14], state[18], data[1], data[5], data[6], data[10], data[13], data[14], data[18]};
            crc_3byte[11] = ^{state[0], state[2], state[6], state[7], state[11], state[14], state[15], state[19], data[0], data[2], data[6], data[7], data[11], data[14], data[15], data[19]};
            crc_3byte[12] = ^{state[1], state[3], state[7], state[8], state[12], state[15], state[16], state[20], data[1], data[3], data[7], data[8], data[12], data[15], data[16], data[20]};
            crc_3byte[13] = ^{state[0], state[2], state[4], state[8], state[9], state[13], state[16], state[17], state[21], data[0], data[2], data[4], data[8], data[9], data[13], data[16], data[17], data[21]};
            crc_3byte[14] = ^{state[0], state[1], state[3], state[5], state[9], state[10], state[14], state[17], state[18], state[22], data[0], data[1], data[3], data[5], data[9], data[10], data[14], data[17], data[18], data[22]};
            crc_3byte[15] = ^{state[1], state[2], state[4], state[6], state[10], state[11], state[15], state[18], state[19], state[23], data[1], data[2], data[4], data[6], data[10], data[11], data[15], data[18], data[19], data[23]};
            crc_3byte[16] = ^{state[2], state[3], state[5], state[7], state[8], state[11], state[14], state[15], state[16], state[18], state[19], state[20], data[2], data[3], data[5], data[7], data[8], data[11], data[14], data[15], data[16], data[18], data[19], data[20]};
            crc_3byte[17] = ^{state[0], state[3], state[4], state[6], state[8], state[9], state[12], state[15], state[16], state[17], state[19], state[20], state[21], data[0], data[3], data[4], data[6], data[8], data[9], data[12], data[15], data[16], data[17], data[19], data[20], data[21]};
            crc_3byte[18] = ^{state[1], state[4], state[5], state[7], state[9], state[10], state[13], state[16], state[17], state[18], state[20], state[21], state[22], data[1], data[4], data[5], data[7], data[9], data[10], data[13], data[16], data[17], data[18], data[20], data[21], data[22]};
            crc_3byte[19] = ^{state[2], state[5], state[6], state[8], state[10], state[11], state[14], state[17], state[18], state[19], state[21], state[22], state[23], data[2], data[5], data[6], data[8], data[10], data[11], data[14], data[17], data[18], data[19], data[21], data[22], data[23]};
            crc_3byte[20] = ^{state[3], state[6], state[7], state[8], state[9], state[11], state[14], state[19], state[20], state[22], state[23], data[3], data[6], data[7], data[8], data[9], data[11], data[14], data[19], data[20], data[22], data[23]};
            crc_3byte[21] = ^{state[4], state[7], state[9], state[10], state[14], state[18], state[20], state[21], state[23], data[4], data[7], data[9], data[10], data[14], data[18], data[20], data[21], data[23]};
            crc_3byte[22] = ^{state[0], state[5], state[10], state[11], state[12], state[14], state[18], state[19], state[21], state[22], data[0], data[5], data[10], data[11], data[12], data[14], data[18], data[19], data[21], data[22]};
            crc_3byte[23] = ^{state[0], state[1], state[6], state[11], state[12], state[13], state[15], state[19], state[20], state[22], state[23], data[0], data[1], data[6], data[11], data[12], data[13], data[15], data[19], data[20], data[22], data[23]};
            crc_3byte[24] = ^{state[0], state[1], state[2], state[7], state[8], state[13], state[15], state[16], state[18], state[20], state[21], state[23], data[0], data[1], data[2], data[7], data[8], data[13], data[15], data[16], data[18], data[20], data[21], data[23]};
            crc_3byte[25] = ^{state[1], state[2], state[3], state[9], state[12], state[15], state[16], state[17], state[18], state[19], state[21], state[22], data[1], data[2], data[3], data[9], data[12], data[15], data[16], data[17], data[18], data[19], data[21], data[22]};
            crc_3byte[26] = ^{state[2], state[3], state[4], state[10], state[13], state[16], state[17], state[18], state[19], state[20], state[22], state[23], data[2], data[3], data[4], data[10], data[13], data[16], data[17], data[18], data[19], data[20], data[22], data[23]};
            crc_3byte[27] = ^{state[3], state[4], state[5], state[8], state[11], state[12], state[15], state[17], state[19], state[20], state[21], state[23], data[3], data[4], data[5], data[8], data[11], data[12], data[15], data[17], data[19], data[20], data[21], data[23]};
            crc_3byte[28] = ^{state[4], state[5], state[6], state[8], state[9], state[13], state[14], state[15], state[16], state[20], state[21], state[22], data[4], data[5], data[6], data[8], data[9], data[13], data[14], data[15], data[16], data[20], data[21], data[22]};
            crc_3byte[29] = ^{state[5], state[6], state[7], state[9], state[10], state[14], state[15], state[16], state[17], state[21], state[22], state[23], data[5], data[6], data[7], data[9], data[10], data[14], data[15], data[16], data[17], data[21], data[22], data[23]};
            crc_3byte[30] = ^{state[6], state[7], state[10], state[11], state[12], state[14], state[16], state[17], state[22], state[23], data[6], data[7], data[10], data[11], data[12], data[14], data[16], data[17], data[22], data[23]};
            crc_3byte[31] = ^{state[7], state[11], state[13], state[14], state[17], state[23], data[7], data[11], data[13], data[14], data[17], data[23]};
        end
    endfunction

    function [31:0] crc_4byte;
        input [31:0] state;
        input [31:0] data;
        begin
            crc_4byte[0] = ^{state[0], state[1], state[2], state[3], state[4], state[6], state[7], state[8], state[16], state[20], state[22], state[23], state[26], data[0], data[1], data[2], data[3], data[4], data[6], data[7], data[8], data[16], data[20], data[22], data[23], data[26]};
            crc_4byte[1] = ^{state[1], state[2], state[3], state[4], state[5], state[7], state[8], state[9], state[17], state[21], state[23], state[24], state[27], data[1], data[2], data[3], data[4], data[5], data[7], data[8], data[9], data[17], data[21], data[23], data[24], data[27]};
            crc_4byte[2] = ^{state[0], state[2], state[3], state[4], state[5], state[6], state[8], state[9], state[10], state[18], state[22], state[24], state[25], state[28], data[0], data[2], data[3], data[4], data[5], data[6], data[8], data[9], data[10], data[18], data[22], data[24], data[25], data[28]};
            crc_4byte[3] = ^{state[1], state[3], state[4], state[5], state[6], state[7], state[9], state[10], state[11], state[19], state[23], state[25], state[26], state[29], data[1], data[3], data[4], data[5], data[6], data[7], data[9], data[10], data[11], data[19], data[23], data[25], data[26], data[29]};
            crc_4byte[4] = ^{state[2], state[4], state[5], state[6], state[7], state[8], state[10], state[11], state[12], state[20], state[24], state[26], state[27], state[30], data[2], data[4], data[5], data[6], data[7], data[8], data[10], data[11], data[12], data[20], data[24], data[26], data[27], data[30]};
            crc_4byte[5] = ^{state[0], state[3], state[5], state[6], state[7], state[8], state[9], state[11], state[12], state[13], state[21], state[25], state[27], state[28], state[31], data[0], data[3], data[5], data[6], data[7], data[8], data[9], data[11], data[12], data[13], data[21], data[25], data[27], data[28], data[31]};
            crc_4byte[6] = ^{state[0], state[2], state[3], state[9], state[10], state[12], state[13], state[14], state[16], state[20], state[23], state[28], state[29], data[0], data[2], data[3], data[9], data[10], data[12], data[13], data[14], data[16], data[20], data[23], data[28], data[29]};
            crc_4byte[7] = ^{state[1], state[3], state[4], state[10], state[11], state[13], state[14], state[15], state[17], state[21], state[24], state[29], state[30], data[1], data[3], data[4], data[10], data[11], data[13], data[14], data[15], data[17], data[21], data[24], data[29], data[30]};
            crc_4byte[8] = ^{state[0], state[2], state[4], state[5], state[11], state[12], state[14], state[15], state[16], state[18], state[22], state[25], state[30], state[31], data[0], data[2], data[4], data[5], data[11], data[12], data[14], data[15], data[16], data[18], data[22], data[25], data[30], data[31]};
            crc_4byte[9] = ^{state[0], state[2], state[4], state[5], state[7], state[8], state[12], state[13], state[15], state[17], state[19], state[20], state[22], state[31], data[0], data[2], data[4], data[5], data[7], data[8], data[12], data[13], data[15], data[17], data[19], data[20], data[22], data[31]};
            crc_4byte[10] = ^{state[0], state[2], state[4], state[5], state[7], state[9], state[13], state[14], state[18], state[21], state[22], state[26], data[0], data[2], data[4], data[5], data[7], data[9], data[13], data[14], data[18], data[21], data[22], data[26]};
            crc_4byte[11] = ^{state[1], state[3], state[5], state[6], state[8], state[10], state[14], state[15], state[19], state[22], state[23], state[27], data[1], data[3], data[5], data[6], data[8], data[10], data[14], data[15], data[19], data[22], data[23], data[27]};
            crc_4byte[12] = ^{state[2], state[4], state[6], state[7], state[9], state[11], state[15], state[16], state[20], state[23], state[24], state[28], data[2], data[4], data[6], data[7], data[9], data[11], data[15], data[16], data[20], data[23], data[24], data[28]};
            crc_4byte[13] = ^{state[0], state[3], state[5], state[7], state[8], state[10], state[12], state[16], state[17], state[21], state[24], state[25], state[29], data[0], data[3], data[5], data[7], data[8], data[10], data[12], data[16], data[17], data[21], data[24], data[25], data[29]};
            crc_4byte[14] = ^{state[0], state[1], state[4], state[6], state[8], state[9], state[11], state[13], state[17], state[18], state[22], state[25], state[26], state[30], data[0], data[1], data[4], data[6], data[8], data[9], data[11], data[13], data[17], data[18], data[22], data[25], data[26], data[30]};
            crc_4byte[15] = ^{state[1], state[2], state[5], state[7], state[9], state[10], state[12], state[14], state[18], state[19], state[23], state[26], state[27], state[31], data[1], data[2], data[5], data[7], data[9], data[10], data[12], data[14], data[18], data[19], data[23], data[26], data[27], data[31]};
            crc_4byte[16] = ^{state[1], state[4], state[7], state[10], state[11], state[13], state[15], state[16], state[19], state[22], state[23], state[24], state[26], state[27], state[28], data[1], data[4], data[7], data[10], data[11], data[13], data[15], data[16], data[19], data[22], data[23], data[24], data[26], data[27], data[28]};
            crc_4byte[17] = ^{state[2], state[5], state[8], state[11], state[12], state[14], state[16], state[17], state[20], state[23], state[24], state[25], state[27], state[28], state[29], data[2], data[5], data[8], data[11], data[12], data[14], data[16], data[17], data[20], data[23], data[24], data[25], data[27], data[28], data[29]};
            crc_4byte[18] = ^{state[0], state[3], state[6], state[9], state[12], state[13], state[15], state[17], state[18], state[21], state[24], state[25], state[26], state[28], state[29], state[30], data[0], data[3], data[6], data[9], data[12], data[13], data[15], data[17], data[18], data[21], data[24], data[25], data[26], data[28], data[29], data[30]};
            crc_4byte[19] = ^{state[0], state[1], state[4], state[7], state[10], state[13], state[14], state[16], state[18], state[19], state[22], state[25], state[26], state[27], state[29], state[30], state[31], data[0], data[1], data[4], data[7], data[10], data[13], data[14], data[16], data[18], data[19], data[22], data[25], data[26], data[27], data[29], data[30], data[31]};
            crc_4byte[20] = ^{state[0], state[3], state[4], state[5], state[6], state[7], state[11], state[14], state[15], state[16], state[17], state[19], state[22], state[27], state[28], state[30], state[31], data[0], data[3], data[4], data[5], data[6], data[7], data[11], data[14], data[15], data[16], data[17], data[19], data[22], data[27], data[28], data[30], data[31]};
            crc_4byte[21] = ^{state[0], state[2], state[3], state[5], state[12], state[15], state[17], state[18], state[22], state[26], state[28], state[29], state[31], data[0], data[2], data[3], data[5], data[12], data[15], data[17], data[18], data[22], data[26], data[28], data[29], data[31]};
            crc_4byte[22] = ^{state[2], state[7], state[8], state[13], state[18], state[19], state[20], state[22], state[26], state[27], state[29], state[30], data[2], data[7], data[8], data[13], data[18], data[19], data[20], data[22], data[26], data[27], data[29], data[30]};
            crc_4byte[23] = ^{state[0], state[3], state[8], state[9], state[14], state[19], state[20], state[21], state[23], state[27], state[28], state[30], state[31], data[0], data[3], data[8], data[9], data[14], data[19], data[20], data[21], data[23], data[27], data[28], data[30], data[31]};
            crc_4byte[24] = ^{state[2], state[3], state[6], state[7], state[8], state[9], state[10], state[15], state[16], state[21], state[23], state[24], state[26], state[28], state[29], state[31], data[2], data[3], data[6], data[7], data[8], data[9], data[10], data[15], data[16], data[21], data[23], data[24], data[26], data[28], data[29], data[31]};
            crc_4byte[25] = ^{state[1], state[2], state[6], state[9], state[10], state[11], state[17], state[20], state[23], state[24], state[25], state[26], state[27], state[29], state[30], data[1], data[2], data[6], data[9], data[10], data[11], data[17], data[20], data[23], data[24], data[25], data[26], data[27], data[29], data[30]};
            crc_4byte[26] = ^{state[2], state[3], state[7], state[10], state[11], state[12], state[18], state[21], state[24], state[25], state[26], state[27], state[28], state[30], state[31], data[2], data[3], data[7], data[10], data[11], data[12], data[18], data[21], data[24], data[25], data[26], data[27], data[28], data[30], data[31]};
            crc_4byte[27] = ^{state[0], state[1], state[2], state[6], state[7], state[11], state[12], state[13], state[16], state[19], state[20], state[23], state[25], state[27], state[28], state[29], state[31], data[0], data[1], data[2], data[6], data[7], data[11], data[12], data[13], data[16], data[19], data[20], data[23], data[25], data[27], data[28], data[29], data[31]};
            crc_4byte[28] = ^{state[0], state[4], state[6], state[12], state[13], state[14], state[16], state[17], state[21], state[22], state[23], state[24], state[28], state[29], state[30], data[0], data[4], data[6], data[12], data[13], data[14], data[16], data[17], data[21], data[22], data[23], data[24], data[28], data[29], data[30]};
            crc_4byte[29] = ^{state[0], state[1], state[5], state[7], state[13], state[14], state[15], state[17], state[18], state[22], state[23], state[24], state[25], state[29], state[30], state[31], data[0], data[1], data[5], data[7], data[13], data[14], data[15], data[17], data[18], data[22], data[23], data[24], data[25], data[29], data[30], data[31]};
            crc_4byte[30] = ^{state[3], state[4], state[7], state[14], state[15], state[18], state[19], state[20], state[22], state[24], state[25], state[30], state[31], data[3], data[4], data[7], data[14], data[15], data[18], data[19], data[20], data[22], data[24], data[25], data[30], data[31]};
            crc_4byte[31] = ^{state[0], state[1], state[2], state[3], state[5], state[6], state[7], state[15], state[19], state[21], state[22], state[25], state[31], data[0], data[1], data[2], data[3], data[5], data[6], data[7], data[15], data[19], data[21], data[22], data[25], data[31]};
        end
    endfunction

    function [31:0] crc_word;
        input [31:0] state;
        input [31:0] data;
        input [3:0] valid_bytes;
        begin
            case (valid_bytes)
                4'b0001: crc_word = crc_1byte(state, data);
                4'b0011: crc_word = crc_2byte(state, data);
                4'b0111: crc_word = crc_3byte(state, data);
                4'b1111: crc_word = crc_4byte(state, data);
                default: crc_word = state;
            endcase
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
