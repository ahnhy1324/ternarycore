// kv_v03_symbol_decoder.v -- two-symbol/cycle PACKED5 compressed/raw decoder.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_symbol_decoder #(
    parameter integer SYMBOL_WIDTH = 4,
    parameter integer STREAM_IS_V = 0,
    parameter integer RUNTIME_STREAM_SELECT = 0,
    parameter integer MAX_SYMBOLS = 16384
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire         integrity_passed,
    input  wire         stream_is_v,
    input  wire         raw_mode,
    input  wire [14:0]  expected_symbols,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [31:0]  in_data,
    input  wire [3:0]   in_byte_valid,
    input  wire         in_last,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [1:0]   out_count,
    output wire signed [4:0] out_symbol0,
    output wire signed [4:0] out_symbol1,
    output wire         out_last,
    output wire         busy,
    output reg          done,
    output reg          error_valid,
    output reg  [7:0]   error_code
);
    localparam [7:0] ERR_PREFIX    = 8'h01;
    localparam [7:0] ERR_TRUNCATED = 8'h02;
    localparam [7:0] ERR_TRAILING  = 8'h03;
    localparam [7:0] ERR_RESERVED  = 8'h04;
    localparam [7:0] ERR_PROTOCOL  = 8'h05;

    reg active;
    reg mode_raw;
    reg mode_stream_is_v;
    reg [14:0] expected_reg;
    reg [14:0] emitted_symbols;
    reg [63:0] reservoir;
    reg [6:0] bit_count;
    reg saw_last;

    function [9:0] packed_entry;
        input [3:0] length;
        input signed [5:0] symbol;
        begin
            packed_entry = {1'b1, length, symbol[4:0]};
        end
    endfunction

    function [9:0] k_entry;
        input [7:0] prefix;
        begin
            casez (prefix)
                8'b00??????: k_entry = packed_entry(4'd2,  6'sd0);
                8'b010?????: k_entry = packed_entry(4'd3,  6'sd2);
                8'b011?????: k_entry = packed_entry(4'd3, -6'sd2);
                8'b1000????: k_entry = packed_entry(4'd4,  6'sd3);
                8'b1001000?: k_entry = packed_entry(4'd7,  6'sd7);
                8'b1001001?: k_entry = packed_entry(4'd7, -6'sd7);
                8'b1001010?: k_entry = packed_entry(4'd7,  6'sd6);
                8'b1001011?: k_entry = packed_entry(4'd7, -6'sd6);
                8'b10011???: k_entry = packed_entry(4'd5,  6'sd4);
                8'b1010????: k_entry = packed_entry(4'd4, -6'sd3);
                8'b101100??: k_entry = packed_entry(4'd6,  6'sd5);
                8'b101101??: k_entry = packed_entry(4'd6, -6'sd5);
                8'b10111???: k_entry = packed_entry(4'd5, -6'sd4);
                8'b110?????: k_entry = packed_entry(4'd3,  6'sd1);
                8'b111?????: k_entry = packed_entry(4'd3, -6'sd1);
                default:     k_entry = 10'b0;
            endcase
        end
    endfunction

    function [9:0] v_entry;
        input [7:0] prefix;
        begin
            casez (prefix)
                8'b0000????: v_entry = packed_entry(4'd4,   6'sd5);
                8'b000100??: v_entry = packed_entry(4'd6, -6'sd10);
                8'b000101??: v_entry = packed_entry(4'd6,  6'sd10);
                8'b0001100?: v_entry = packed_entry(4'd7,  6'sd15);
                8'b0001101?: v_entry = packed_entry(4'd7,  6'sd12);
                8'b0001110?: v_entry = packed_entry(4'd7, -6'sd15);
                8'b0001111?: v_entry = packed_entry(4'd7, -6'sd12);
                8'b0010????: v_entry = packed_entry(4'd4,   6'sd4);
                8'b00110???: v_entry = packed_entry(4'd5,   6'sd7);
                8'b00111???: v_entry = packed_entry(4'd5,  -6'sd7);
                8'b0100????: v_entry = packed_entry(4'd4,  -6'sd4);
                8'b010100??: v_entry = packed_entry(4'd6,   6'sd9);
                8'b01010100: v_entry = packed_entry(4'd8, -6'sd14);
                8'b01010101: v_entry = packed_entry(4'd8,  6'sd14);
                8'b0101011?: v_entry = packed_entry(4'd7,  6'sd11);
                8'b010110??: v_entry = packed_entry(4'd6,  -6'sd9);
                8'b0101110?: v_entry = packed_entry(4'd7, -6'sd11);
                8'b01011110: v_entry = packed_entry(4'd8,  6'sd13);
                8'b01011111: v_entry = packed_entry(4'd8, -6'sd13);
                8'b011?????: v_entry = packed_entry(4'd3,   6'sd0);
                8'b1000????: v_entry = packed_entry(4'd4,   6'sd3);
                8'b1001????: v_entry = packed_entry(4'd4,  -6'sd3);
                8'b10100???: v_entry = packed_entry(4'd5,  -6'sd6);
                8'b10101???: v_entry = packed_entry(4'd5,   6'sd6);
                8'b1011????: v_entry = packed_entry(4'd4,   6'sd2);
                8'b1100????: v_entry = packed_entry(4'd4,  -6'sd2);
                8'b1101????: v_entry = packed_entry(4'd4,  -6'sd1);
                8'b1110????: v_entry = packed_entry(4'd4,   6'sd1);
                8'b111100??: v_entry = packed_entry(4'd6,   6'sd8);
                8'b111101??: v_entry = packed_entry(4'd6,  -6'sd8);
                8'b11111???: v_entry = packed_entry(4'd5,  -6'sd5);
                default:     v_entry = 10'b0;
            endcase
        end
    endfunction

    reg [9:0] lookup [0:255];
    reg [9:0] alternate_lookup [0:255];
    integer init_index;
    initial begin
        for (init_index = 0; init_index < 256; init_index = init_index + 1) begin
            lookup[init_index] = STREAM_IS_V ?
                v_entry(init_index[7:0]) : k_entry(init_index[7:0]);
            alternate_lookup[init_index] = STREAM_IS_V ?
                k_entry(init_index[7:0]) : v_entry(init_index[7:0]);
        end
    end

    function [7:0] reverse_byte;
        input [7:0] value;
        integer index;
        begin
            for (index = 0; index < 8; index = index + 1)
                reverse_byte[index] = value[7-index];
        end
    endfunction

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    // Avoid a shift-by-64 expression when checking the live reservoir tail.
    // Some synthesis tools give width-sized shifts implementation-specific
    // behavior, while this bounded reduction has one unambiguous meaning.
    function low_bits_nonzero;
        input [63:0] value;
        input [6:0] count;
        integer bit_index;
        begin
            low_bits_nonzero = 1'b0;
            for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
                if (bit_index < count)
                    low_bits_nonzero = low_bits_nonzero | value[bit_index];
        end
    endfunction

    reg [7:0] prefix0, prefix1;
    reg [9:0] entry0, entry1;
    reg [3:0] length0, length1;
    reg [6:0] remaining_count;
    reg signed [4:0] symbol0_comb, symbol1_comb;
    reg decodable0, decodable1;
    reg reserved0, reserved1;
    reg [3:0] raw_width;
    integer symbol_bit;
    always @* begin
        raw_width = mode_stream_is_v ? 4'd5 : 4'd4;
        if (bit_count >= 8)
            prefix0 = reservoir >> (bit_count - 8);
        else
            prefix0 = reservoir << (8 - bit_count);
        entry0 = (mode_stream_is_v == STREAM_IS_V) ?
                 lookup[prefix0] : alternate_lookup[prefix0];
        length0 = mode_raw ? raw_width : entry0[8:5];
        symbol0_comb = entry0[4:0];
        if (mode_raw) begin
            symbol0_comb = 5'b0;
            if (bit_count >= raw_width) begin
                for (symbol_bit = 0; symbol_bit < 5;
                     symbol_bit = symbol_bit + 1)
                    if (symbol_bit < raw_width)
                        symbol0_comb[symbol_bit] =
                            reservoir[bit_count-1-symbol_bit];
                if (raw_width == 4)
                    symbol0_comb[4] = symbol0_comb[3];
            end
        end
        reserved0 = mode_raw && (bit_count >= raw_width) &&
            (((raw_width == 4) && symbol0_comb[3:0] == 4'h8) ||
             ((raw_width == 5) && symbol0_comb[4:0] == 5'h10));
        decodable0 = (emitted_symbols < expected_reg) && !reserved0 &&
            (mode_raw ? (bit_count >= raw_width) :
             (entry0[9] && length0 != 0 && length0 <= bit_count &&
              (bit_count >= 8 || saw_last)));

        remaining_count = decodable0 ? bit_count - length0 : 0;
        if (remaining_count >= 8)
            prefix1 = reservoir >> (remaining_count - 8);
        else
            prefix1 = reservoir << (8 - remaining_count);
        entry1 = (mode_stream_is_v == STREAM_IS_V) ?
                 lookup[prefix1] : alternate_lookup[prefix1];
        length1 = mode_raw ? raw_width : entry1[8:5];
        symbol1_comb = entry1[4:0];
        if (mode_raw) begin
            symbol1_comb = 5'b0;
            if (remaining_count >= raw_width) begin
                for (symbol_bit = 0; symbol_bit < 5;
                     symbol_bit = symbol_bit + 1)
                    if (symbol_bit < raw_width)
                        symbol1_comb[symbol_bit] =
                            reservoir[remaining_count-1-symbol_bit];
                if (raw_width == 4)
                    symbol1_comb[4] = symbol1_comb[3];
            end
        end
        reserved1 = mode_raw && (remaining_count >= raw_width) &&
            (((raw_width == 4) && symbol1_comb[3:0] == 4'h8) ||
             ((raw_width == 5) && symbol1_comb[4:0] == 5'h10));
        decodable1 = decodable0 &&
            (emitted_symbols + 1 < expected_reg) && !reserved1 &&
            (mode_raw ? (remaining_count >= raw_width) :
             (entry1[9] && length1 != 0 && length1 <= remaining_count &&
              (remaining_count >= 8 || saw_last)));
    end

    assign out_valid = active && decodable0;
    assign out_count = decodable1 ? 2 : (decodable0 ? 1 : 0);
    assign out_symbol0 = symbol0_comb;
    assign out_symbol1 = symbol1_comb;
    assign out_last = out_valid &&
        (emitted_symbols + out_count == expected_reg);
    assign busy = active;
    assign in_ready = active && !saw_last && (bit_count <= 32) &&
                      !(out_valid && !out_ready);

    wire pop_symbols = out_valid && out_ready;
    wire push_word = in_valid && in_ready;
    wire [4:0] consumed_bits = pop_symbols ?
        (length0 + (decodable1 ? length1 : 0)) : 0;

    reg [63:0] work_reservoir;
    reg [6:0] work_bit_count;
    reg [14:0] work_emitted;
    reg work_saw_last;
    reg [7:0] append_byte;
    integer append_index;
    always @* begin
        work_reservoir = reservoir;
        work_bit_count = bit_count;
        work_emitted = emitted_symbols;
        work_saw_last = saw_last;
        append_byte = 8'b0;

        if (pop_symbols) begin
            work_bit_count = work_bit_count - consumed_bits;
            work_emitted = work_emitted + out_count;
        end

        if (push_word && valid_mask(in_byte_valid)) begin
            for (append_index = 0; append_index < 4;
                 append_index = append_index + 1) begin
                if (in_byte_valid[append_index]) begin
                    append_byte = in_data[(append_index*8) +: 8];
                    if (mode_raw)
                        append_byte = reverse_byte(append_byte);
                    work_reservoir = (work_reservoir << 8) | append_byte;
                    work_bit_count = work_bit_count + 8;
                end
            end
            if (in_last)
                work_saw_last = 1'b1;
        end
    end

    wire trailing_nonzero = low_bits_nonzero(work_reservoir, work_bit_count);

    always @(posedge clk) begin
        if (!rst_n) begin
            active          <= 1'b0;
            mode_raw        <= 1'b0;
            mode_stream_is_v <= STREAM_IS_V;
            expected_reg    <= 15'b0;
            emitted_symbols <= 15'b0;
            reservoir       <= 64'b0;
            bit_count       <= 7'b0;
            saw_last        <= 1'b0;
            done            <= 1'b0;
            error_valid     <= 1'b0;
            error_code      <= 8'b0;
        end else begin
            done        <= 1'b0;
            error_valid <= 1'b0;

            if (start) begin
                mode_raw        <= raw_mode;
                mode_stream_is_v <= RUNTIME_STREAM_SELECT ?
                                    stream_is_v : STREAM_IS_V;
                expected_reg    <= expected_symbols;
                emitted_symbols <= 15'b0;
                reservoir       <= 64'b0;
                bit_count       <= 7'b0;
                saw_last        <= 1'b0;
                if (!integrity_passed || expected_symbols == 0 ||
                    expected_symbols > MAX_SYMBOLS) begin
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
                end else if (mode_raw && reserved0) begin
                    active      <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_RESERVED;
                end else if (saw_last && emitted_symbols < expected_reg &&
                             !out_valid) begin
                    active      <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= (!mode_raw && bit_count >= 8 && !entry0[9]) ?
                                   ERR_PREFIX : ERR_TRUNCATED;
                end else begin
                    reservoir       <= work_reservoir;
                    bit_count       <= work_bit_count;
                    emitted_symbols <= work_emitted;
                    saw_last        <= work_saw_last;

                    if (work_saw_last && work_emitted == expected_reg) begin
                        active <= 1'b0;
                        // done is the page commit point. Although the input CRC
                        // was checked before start, a later format fault can
                        // still invalidate symbols already streamed out. The
                        // integration must therefore keep downstream effects
                        // in scratch state until this pulse is observed.
                        if ((mode_raw && work_bit_count != 0) ||
                            (!mode_raw && (work_bit_count > 7 || trailing_nonzero))) begin
                            error_valid <= 1'b1;
                            error_code  <= ERR_TRAILING;
                        end else begin
                            done <= 1'b1;
                        end
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (SYMBOL_WIDTH != 4 && SYMBOL_WIDTH != 5)
            $error("kv_v03_symbol_decoder: SYMBOL_WIDTH must be 4 or 5");
        if ((STREAM_IS_V && SYMBOL_WIDTH != 5) ||
            (!STREAM_IS_V && SYMBOL_WIDTH != 4))
            $error("kv_v03_symbol_decoder: stream/width mismatch");
        if (RUNTIME_STREAM_SELECT != 0 && RUNTIME_STREAM_SELECT != 1)
            $error("kv_v03_symbol_decoder: RUNTIME_STREAM_SELECT must be 0 or 1");
    end
`endif
endmodule

`default_nettype wire
