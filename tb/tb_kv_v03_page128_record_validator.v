// tb_kv_v03_page128_record_validator.v -- fail-closed page record tests.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_page128_record_validator;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam integer MAX_PAGE_BYTES = 10256;
    localparam integer WATCHDOG = 20000;

    localparam [7:0] ERR_PAGE_DESCRIPTOR   = 8'h01;
    localparam [7:0] ERR_TOKEN_DESCRIPTOR  = 8'h02;
    localparam [7:0] ERR_WINDOW_DESCRIPTOR = 8'h03;
    localparam [7:0] ERR_SCALE_DESCRIPTOR  = 8'h04;
    localparam [7:0] ERR_DATA_TAG          = 8'h05;
    localparam [7:0] ERR_DATA_FRAMING      = 8'h06;
    localparam [7:0] ERR_RECORD_WINDOW     = 8'h07;
    localparam [7:0] ERR_NONZERO_PADDING   = 8'h08;
    localparam [7:0] ERR_SCALE_TAG         = 8'h09;
    localparam [7:0] ERR_SCALE_FRAMING     = 8'h0a;
    localparam [7:0] ERR_STREAM_MISMATCH   = 8'h0b;
    localparam [7:0] ERR_TOKEN_MISMATCH    = 8'h0c;
    localparam [7:0] ERR_SCALE_MISMATCH    = 8'h0d;
    localparam [7:0] ERR_HEADER_MAGIC      = 8'h21;
    localparam [7:0] ERR_HEADER_CRC        = 8'h27;
    localparam [7:0] ERR_SCALE12_PADDING   = 8'h32;

    localparam [63:0] TAG_BASE    = 64'h5652_4543_0000_0000;
    localparam [63:0] TAG_RESTART = 64'h5652_4543_cafe_0000;

    reg clk = 0;
    reg rst_n = 0;

    reg cmd_valid = 0;
    wire cmd_ready;
    reg [4:0] cmd_page_index = 0;
    reg [5:0] cmd_page_count = 0;
    reg [12:0] cmd_token_base = 0;
    reg [7:0] cmd_token_count = 0;
    reg [14:0] cmd_expected_symbols = 0;
    reg [31:0] cmd_page_window_bytes = 0;
    reg [8:0] cmd_scale_slice_bytes = 0;
    reg cmd_stream_is_v = 0;
    reg [63:0] cmd_task_tag = 0;
    reg abort = 0;

    reg data_valid = 0;
    wire data_ready;
    reg [31:0] data_data = 0;
    reg [3:0] data_byte_valid = 0;
    reg data_last = 0;
    reg [13:0] data_byte_offset = 0;
    reg [63:0] data_task_tag = 0;
    reg [4:0] data_page_index = 0;
    reg data_stream_is_v = 0;

    reg scale_valid = 0;
    wire scale_ready;
    reg [31:0] scale_data = 0;
    reg [3:0] scale_byte_valid = 0;
    reg scale_last = 0;
    reg [13:0] scale_byte_offset = 0;
    reg [63:0] scale_task_tag = 0;
    reg [4:0] scale_page_index = 0;
    reg scale_stream_is_v = 0;

    wire verified_valid;
    reg verified_ready = 0;
    wire [63:0] verified_task_tag;
    wire [4:0] verified_page_index;
    wire [5:0] verified_page_count;
    wire [12:0] verified_token_base;
    wire [7:0] verified_token_count;
    wire [14:0] verified_expected_symbols;
    wire verified_raw_mode;
    wire verified_stream_is_v;
    wire [15:0] verified_payload_bytes;
    wire [7:0] verified_scale_format_id;
    wire [13:0] verified_record_bytes;
    wire [13:0] verified_page_window_bytes;
    wire [8:0] verified_scale_slice_bytes;
    wire [13:0] verified_padding_bytes;

    wire busy;
    wire aborted;
    wire [63:0] aborted_task_tag;
    wire [4:0] aborted_page_index;
    wire aborted_stream_is_v;
    wire error_valid;
    wire [7:0] error_code;
    wire [63:0] error_task_tag;
    wire [4:0] error_page_index;
    wire error_stream_is_v;

    reg [7:0] record_mem [0:MAX_PAGE_BYTES-1];
    reg [7:0] scale_mem [0:511];

    integer errors = 0;
    integer error_pulses = 0;
    integer abort_pulses = 0;
    integer verified_handshakes = 0;
    integer data_handshakes = 0;
    integer scale_handshakes = 0;
    integer data_input_stall_cycles = 0;
    integer scale_input_stall_cycles = 0;
    reg prior_error = 0;
    reg prior_aborted = 0;
    reg unknown_reported = 0;
    reg allow_verified = 0;
    reg data_phase_done = 0;
    reg [7:0] seen_error_code = 0;
    reg [63:0] seen_error_tag = 0;
    reg [4:0] seen_error_page = 0;
    reg seen_error_stream = 0;
    reg [63:0] seen_abort_tag = 0;
    reg [4:0] seen_abort_page = 0;
    reg seen_abort_stream = 0;

    integer active_window = 0;
    integer active_record = 0;
    integer active_payload = 0;
    integer active_scale_bytes = 0;
    reg active_raw = 0;
    reg active_stream = 0;
    reg [7:0] active_scale_id = 0;
    reg [63:0] active_tag = 0;
    reg [4:0] active_page = 1;
    reg [5:0] active_page_count = 2;
    reg [12:0] active_token_base = 128;
    reg [7:0] active_tokens = 1;
    reg [14:0] active_symbols = 128;

    integer i;
    integer timeout;
    integer before_count;
    reg [31:0] held_word;
    reg [3:0] held_mask;

    always #5 clk = ~clk;

    kv_v03_page128_record_validator #(
        .TAG_WIDTH(64),
        .SCALE_BITS(SCALE_BITS),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_page_index(cmd_page_index), .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base),
        .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .cmd_stream_is_v(cmd_stream_is_v),
        .cmd_task_tag(cmd_task_tag), .abort(abort),
        .data_valid(data_valid), .data_ready(data_ready),
        .data_data(data_data), .data_byte_valid(data_byte_valid),
        .data_last(data_last), .data_byte_offset(data_byte_offset),
        .data_task_tag(data_task_tag),
        .data_page_index(data_page_index),
        .data_stream_is_v(data_stream_is_v),
        .scale_valid(scale_valid), .scale_ready(scale_ready),
        .scale_data(scale_data), .scale_byte_valid(scale_byte_valid),
        .scale_last(scale_last), .scale_byte_offset(scale_byte_offset),
        .scale_task_tag(scale_task_tag),
        .scale_page_index(scale_page_index),
        .scale_stream_is_v(scale_stream_is_v),
        .verified_valid(verified_valid), .verified_ready(verified_ready),
        .verified_task_tag(verified_task_tag),
        .verified_page_index(verified_page_index),
        .verified_page_count(verified_page_count),
        .verified_token_base(verified_token_base),
        .verified_token_count(verified_token_count),
        .verified_expected_symbols(verified_expected_symbols),
        .verified_raw_mode(verified_raw_mode),
        .verified_stream_is_v(verified_stream_is_v),
        .verified_payload_bytes(verified_payload_bytes),
        .verified_scale_format_id(verified_scale_format_id),
        .verified_record_bytes(verified_record_bytes),
        .verified_page_window_bytes(verified_page_window_bytes),
        .verified_scale_slice_bytes(verified_scale_slice_bytes),
        .verified_padding_bytes(verified_padding_bytes),
        .busy(busy), .aborted(aborted),
        .aborted_task_tag(aborted_task_tag),
        .aborted_page_index(aborted_page_index),
        .aborted_stream_is_v(aborted_stream_is_v),
        .error_valid(error_valid), .error_code(error_code),
        .error_task_tag(error_task_tag),
        .error_page_index(error_page_index),
        .error_stream_is_v(error_stream_is_v)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            error_pulses <= 0;
            abort_pulses <= 0;
            verified_handshakes <= 0;
            data_handshakes <= 0;
            scale_handshakes <= 0;
            data_input_stall_cycles <= 0;
            scale_input_stall_cycles <= 0;
            prior_error <= 0;
            prior_aborted <= 0;
            unknown_reported <= 0;
        end else begin
            if ((^{cmd_ready, data_ready, scale_ready, verified_valid,
                   verified_task_tag, verified_page_index,
                   verified_page_count, verified_token_base,
                   verified_token_count, verified_expected_symbols,
                   verified_raw_mode, verified_stream_is_v,
                   verified_payload_bytes, verified_scale_format_id,
                   verified_record_bytes, verified_page_window_bytes,
                   verified_scale_slice_bytes, verified_padding_bytes,
                   busy, aborted, aborted_task_tag, aborted_page_index,
                   aborted_stream_is_v, error_valid, error_code,
                   error_task_tag, error_page_index,
                   error_stream_is_v}) === 1'bx) begin
                if (!unknown_reported) begin
                    $display("FAIL validator output contained X/Z");
                    errors <= errors + 1;
                end
                unknown_reported <= 1;
            end else begin
                unknown_reported <= 0;
            end
            if (error_valid) begin
                if (error_pulses != 0) begin
                    $display("FAIL duplicate nonconsecutive error pulse");
                    errors <= errors + 1;
                end
                error_pulses <= error_pulses + 1;
                seen_error_code <= error_code;
                seen_error_tag <= error_task_tag;
                seen_error_page <= error_page_index;
                seen_error_stream <= error_stream_is_v;
                if (prior_error) begin
                    $display("FAIL error_valid was not a one-cycle pulse");
                    errors <= errors + 1;
                end
            end
            if (aborted) begin
                if (abort_pulses != 0) begin
                    $display("FAIL duplicate nonconsecutive abort pulse");
                    errors <= errors + 1;
                end
                abort_pulses <= abort_pulses + 1;
                seen_abort_tag <= aborted_task_tag;
                seen_abort_page <= aborted_page_index;
                seen_abort_stream <= aborted_stream_is_v;
                if (prior_aborted) begin
                    $display("FAIL aborted was not a one-cycle pulse");
                    errors <= errors + 1;
                end
            end
            prior_error <= error_valid;
            prior_aborted <= aborted;

            if (verified_valid && !allow_verified) begin
                $display("FAIL verified_valid asserted before the test permitted commit");
                errors <= errors + 1;
            end
            if (verified_valid && verified_ready)
                verified_handshakes <= verified_handshakes + 1;
            if (data_valid && data_ready)
                data_handshakes <= data_handshakes + 1;
            if (scale_valid && scale_ready)
                scale_handshakes <= scale_handshakes + 1;
            if (data_valid && !data_ready)
                data_input_stall_cycles <= data_input_stall_cycles + 1;
            if (scale_valid && !scale_ready)
                scale_input_stall_cycles <= scale_input_stall_cycles + 1;
            if (busy && cmd_ready) begin
                $display("FAIL cmd_ready asserted while validator busy");
                errors <= errors + 1;
            end
            if (scale_ready && !data_phase_done) begin
                $display("FAIL scale_ready asserted before the data window completed");
                errors <= errors + 1;
            end
            if (abort && (data_ready || scale_ready || verified_valid)) begin
                $display("FAIL abort did not combinationally gate a handshake interface");
                errors <= errors + 1;
            end
        end
    end

    function [3:0] mask_for_count;
        input integer count;
        begin
            case (count)
                1: mask_for_count = 4'b0001;
                2: mask_for_count = 4'b0011;
                3: mask_for_count = 4'b0111;
                default: mask_for_count = 4'b1111;
            endcase
        end
    endfunction

    function [31:0] crc_byte;
        input [31:0] state;
        input [7:0] value;
        reg [31:0] work;
        integer bit_no;
        begin
            work = state;
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                if (work[0] ^ value[bit_no])
                    work = (work >> 1) ^ 32'hedb8_8320;
                else
                    work = work >> 1;
            end
            crc_byte = work;
        end
    endfunction

    function [31:0] word_from_record;
        input integer offset;
        input integer count;
        integer lane;
        begin
            word_from_record = 0;
            for (lane = 0; lane < count; lane = lane + 1)
                word_from_record[(lane*8) +: 8] = record_mem[offset+lane];
        end
    endfunction

    function [31:0] word_from_scale;
        input integer offset;
        input integer count;
        integer lane;
        begin
            word_from_scale = 0;
            for (lane = 0; lane < count; lane = lane + 1)
                word_from_scale[(lane*8) +: 8] = scale_mem[offset+lane];
        end
    endfunction

    task clear_vectors;
        begin
            for (i = 0; i < MAX_PAGE_BYTES; i = i + 1)
                record_mem[i] = 0;
            for (i = 0; i < 512; i = i + 1)
                scale_mem[i] = 0;
        end
    endtask

    // One K token, 128 zero symbols.  K code zero is "00", so the compressed
    // payload is exactly 32 zero bytes.  CRC covers bytes 0..7, payload, then
    // scale 23 01; it excludes stored CRC bytes and alignment padding.
    task build_k_uq4_8;
        input integer window_bytes;
        input [63:0] tag;
        begin
            clear_vectors();
            active_window = window_bytes;
            active_record = 44;
            active_payload = 32;
            active_scale_bytes = 2;
            active_raw = 0;
            active_stream = 0;
            active_scale_id = 1;
            active_tag = tag;
            active_page = 1;
            active_page_count = 2;
            active_token_base = 128;
            active_tokens = 1;
            active_symbols = 128;
            record_mem[0] = 8'h03; record_mem[1] = 8'hc3;
            record_mem[2] = 8'h00; record_mem[3] = 8'h00;
            record_mem[4] = 8'h20; record_mem[5] = 8'h00;
            record_mem[6] = 8'h01; record_mem[7] = 8'h01;
            record_mem[8] = 8'h39; record_mem[9] = 8'h5c;
            record_mem[10] = 8'he6; record_mem[11] = 8'h16;
            scale_mem[0] = 8'h23;
            scale_mem[1] = 8'h01;
        end
    endtask

    // One V token, 128 zero symbols.  V code zero is "011", producing the
    // 6d/b6/db pattern.  This is the minimal UQ5.11 positive vector.
    task build_v_uq5_11;
        input [63:0] tag;
        begin
            clear_vectors();
            active_window = 64;
            active_record = 60;
            active_payload = 48;
            active_scale_bytes = 2;
            active_raw = 0;
            active_stream = 1;
            active_scale_id = 2;
            active_tag = tag;
            active_page = 1;
            active_page_count = 2;
            active_token_base = 128;
            active_tokens = 1;
            active_symbols = 128;
            record_mem[0] = 8'h03; record_mem[1] = 8'hc3;
            record_mem[2] = 8'h02; record_mem[3] = 8'h00;
            record_mem[4] = 8'h30; record_mem[5] = 8'h00;
            record_mem[6] = 8'h01; record_mem[7] = 8'h02;
            record_mem[8] = 8'h69; record_mem[9] = 8'hff;
            record_mem[10] = 8'h5f; record_mem[11] = 8'h42;
            for (i = 0; i < 48; i = i + 1) begin
                case (i % 3)
                    0: record_mem[12+i] = 8'h6d;
                    1: record_mem[12+i] = 8'hb6;
                    default: record_mem[12+i] = 8'hdb;
                endcase
            end
            scale_mem[0] = 8'h89;
            scale_mem[1] = 8'h67;
        end
    endtask

    task stamp_page_crc;
        reg [31:0] work;
        integer index;
        begin
            work = 32'hffff_ffff;
            for (index = 0; index < 8; index = index + 1)
                work = crc_byte(work, record_mem[index]);
            for (index = 0; index < active_payload; index = index + 1)
                work = crc_byte(work, record_mem[12+index]);
            for (index = 0; index < active_scale_bytes; index = index + 1)
                work = crc_byte(work, scale_mem[index]);
            work = work ^ 32'hffff_ffff;
            record_mem[8] = work[7:0];
            record_mem[9] = work[15:8];
            record_mem[10] = work[23:16];
            record_mem[11] = work[31:24];
        end
    endtask

    // Full page128 raw records exercise the maximum legal data/scale loops.
    // Raw codes are deterministic and avoid the reserved negative minima;
    // every scale is nonzero and packed according to the selected profile.
    task build_full_raw;
        input [63:0] tag;
        integer symbol_no;
        integer bit_no;
        integer bit_position;
        integer code_value;
        integer scale_value;
        begin
            clear_vectors();
            active_raw = 1;
            active_tag = tag;
            active_page = 0;
            active_page_count = 1;
            active_token_base = 0;
            active_tokens = 128;
            active_symbols = 16384;
            record_mem[0] = 8'h03;
            record_mem[1] = 8'hc3;
            record_mem[3] = 8'h7f;
            record_mem[6] = 8'h01;

            if (SCALE_BITS == 12) begin
                active_window = 8208;
                active_record = 8204;
                active_payload = 8192;
                active_scale_bytes = 192;
                active_stream = 0;
                active_scale_id = 1;
                record_mem[2] = 8'h01;
                record_mem[4] = 8'h00;
                record_mem[5] = 8'h20;
                record_mem[7] = 8'h01;
                // Two legal K4 nibbles per byte, never reserved 0x8.
                for (i = 0; i < active_payload; i = i + 1)
                    record_mem[12+i] = (((i+1) & 7) << 4) | (i & 7);
                // Contiguous LSB-first UQ4.8 reservoir.
                for (i = 0; i < 128; i = i + 1) begin
                    scale_value = i + 1;
                    for (bit_no = 0; bit_no < 12; bit_no = bit_no + 1) begin
                        bit_position = i*12 + bit_no;
                        if ((scale_value >> bit_no) & 1)
                            scale_mem[bit_position/8][bit_position%8] = 1'b1;
                    end
                end
            end else begin
                active_window = 10256;
                active_record = 10252;
                active_payload = 10240;
                active_scale_bytes = 256;
                active_stream = 1;
                active_scale_id = 2;
                record_mem[2] = 8'h03;
                record_mem[4] = 8'h00;
                record_mem[5] = 8'h28;
                record_mem[7] = 8'h02;
                // LSB-reservoir V5 values 0..15 are all legal.
                for (symbol_no = 0; symbol_no < 16384;
                     symbol_no = symbol_no + 1) begin
                    code_value = symbol_no & 15;
                    for (bit_no = 0; bit_no < 5; bit_no = bit_no + 1) begin
                        bit_position = symbol_no*5 + bit_no;
                        if ((code_value >> bit_no) & 1)
                            record_mem[12 + bit_position/8]
                                      [bit_position%8] = 1'b1;
                    end
                end
                for (i = 0; i < 128; i = i + 1) begin
                    scale_value = i + 1;
                    scale_mem[i*2] = scale_value[7:0];
                    scale_mem[i*2+1] = 8'h00;
                end
            end
            stamp_page_crc();
            if (SCALE_BITS == 12 &&
                {record_mem[11], record_mem[10], record_mem[9],
                 record_mem[8]} !== 32'h34a3_f4fa)
                $fatal(1, "RAW K12 generated CRC drifted");
            if (SCALE_BITS == 16 &&
                {record_mem[11], record_mem[10], record_mem[9],
                 record_mem[8]} !== 32'h99a4_9517)
                $fatal(1, "RAW V16 generated CRC drifted");
        end
    endtask

    task load_command_fields;
        begin
            cmd_page_index = active_page;
            cmd_page_count = active_page_count;
            cmd_token_base = active_token_base;
            cmd_token_count = active_tokens;
            cmd_expected_symbols = active_symbols;
            cmd_page_window_bytes = active_window;
            cmd_scale_slice_bytes = active_scale_bytes;
            cmd_stream_is_v = active_stream;
            cmd_task_tag = active_tag;
        end
    endtask

    task reset_seen;
        begin
            error_pulses = 0;
            abort_pulses = 0;
            seen_error_code = 0;
            seen_error_tag = 0;
            seen_error_page = 0;
            seen_error_stream = 0;
            seen_abort_tag = 0;
            seen_abort_page = 0;
            seen_abort_stream = 0;
            allow_verified = 0;
            data_phase_done = 0;
            data_input_stall_cycles = 0;
            scale_input_stall_cycles = 0;
        end
    endtask

    task issue_loaded_command;
        begin
            reset_seen();
            timeout = 0;
            while (!cmd_ready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready)
                $fatal(1, "command-ready watchdog expired");
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task issue_active_command;
        begin
            load_command_fields();
            issue_loaded_command();
        end
    endtask

    task send_data_raw;
        input [31:0] value;
        input [3:0] mask;
        input [13:0] offset;
        input last;
        input [63:0] tag;
        input [4:0] page;
        input stream;
        integer accepted;
        begin
            data_data = value;
            data_byte_valid = mask;
            data_byte_offset = offset;
            data_last = last;
            data_task_tag = tag;
            data_page_index = page;
            data_stream_is_v = stream;
            data_valid = 1;
            timeout = 0;
            accepted = 0;
            while (!accepted && timeout < 1000) begin
                @(posedge clk);
                if (data_ready === 1'b1) begin
                    accepted = 1;
                end else begin
                    if (data_ready !== 1'b0 || data_valid !== 1'b1 ||
                        data_data !== value || data_byte_valid !== mask ||
                        data_byte_offset !== offset || data_last !== last ||
                        data_task_tag !== tag || data_page_index !== page ||
                        data_stream_is_v !== stream)
                        $fatal(1, "data source changed while backpressured offset=%0d",
                               offset);
                end
                timeout = timeout + 1;
            end
            if (!accepted)
                $fatal(1, "data-ready watchdog expired offset=%0d", offset);
            @(negedge clk);
            data_valid = 0;
            data_last = 0;
            data_byte_valid = 0;
        end
    endtask

    task send_data_piece;
        input integer offset;
        input integer count;
        input last;
        begin
            send_data_raw(word_from_record(offset, count),
                          mask_for_count(count), offset[13:0], last,
                          active_tag, active_page, active_stream);
        end
    endtask

    task drive_header_standard;
        begin
            send_data_piece(0, 4, 0);
            send_data_piece(4, 4, 0);
            send_data_piece(8, 4, 0);
        end
    endtask

    task drive_data_standard;
        input integer missing_final_last;
        integer offset;
        integer count;
        begin
            offset = 0;
            while (offset < active_window) begin
                count = active_window - offset;
                if (count > 4)
                    count = 4;
                send_data_piece(offset, count,
                    ((offset + count) == active_window) &&
                    !missing_final_last);
                offset = offset + count;
                if ((offset & 15) == 8)
                    @(negedge clk); // deterministic input bubble
            end
            data_phase_done = 1;
        end
    endtask

    // Header fragments deliberately use every legal partial mask and cross
    // both byte 8 (CRC exclusion) and byte 12 (payload start).
    task drive_data_fragmented_header;
        integer offset;
        integer count;
        begin
            send_data_piece(0, 1, 0);
            send_data_piece(1, 2, 0);
            send_data_piece(3, 3, 0);
            send_data_piece(6, 3, 0); // crosses prefix/stored-CRC boundary
            send_data_piece(9, 4, 0); // crosses stored-CRC/payload boundary
            offset = 13;
            while (offset < active_window) begin
                count = active_window - offset;
                if (count > 4)
                    count = 4;
                send_data_piece(offset, count,
                                offset + count == active_window);
                offset = offset + count;
            end
            data_phase_done = 1;
        end
    endtask

    task send_scale_raw;
        input [31:0] value;
        input [3:0] mask;
        input [13:0] offset;
        input last;
        input [63:0] tag;
        input [4:0] page;
        input stream;
        integer accepted;
        begin
            scale_data = value;
            scale_byte_valid = mask;
            scale_byte_offset = offset;
            scale_last = last;
            scale_task_tag = tag;
            scale_page_index = page;
            scale_stream_is_v = stream;
            scale_valid = 1;
            timeout = 0;
            accepted = 0;
            while (!accepted && timeout < 1000) begin
                @(posedge clk);
                if (scale_ready === 1'b1) begin
                    accepted = 1;
                end else begin
                    if (scale_ready !== 1'b0 || scale_valid !== 1'b1 ||
                        scale_data !== value || scale_byte_valid !== mask ||
                        scale_byte_offset !== offset || scale_last !== last ||
                        scale_task_tag !== tag || scale_page_index !== page ||
                        scale_stream_is_v !== stream)
                        $fatal(1, "scale source changed while backpressured offset=%0d",
                               offset);
                end
                timeout = timeout + 1;
            end
            if (!accepted)
                $fatal(1, "scale-ready watchdog expired offset=%0d", offset);
            @(negedge clk);
            scale_valid = 0;
            scale_last = 0;
            scale_byte_valid = 0;
        end
    endtask

    task drive_scale_standard;
        input integer fragmented;
        integer offset;
        integer count;
        begin
            offset = 0;
            if (fragmented) begin
                send_scale_raw(word_from_scale(0, 1), 4'b0001, 0, 0,
                               active_tag, active_page, active_stream);
                @(negedge clk);
                offset = 1;
            end
            while (offset < active_scale_bytes) begin
                count = active_scale_bytes - offset;
                if (count > 4)
                    count = 4;
                send_scale_raw(word_from_scale(offset, count),
                               mask_for_count(count), offset[13:0],
                               offset + count == active_scale_bytes,
                               active_tag, active_page, active_stream);
                offset = offset + count;
                if ((offset & 15) == 4)
                    @(negedge clk); // deterministic scale-stream bubble
            end
        end
    endtask

    task wait_error_code;
        input [7:0] wanted;
        begin
            timeout = 0;
            while (error_pulses == 0 && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            repeat (2) @(negedge clk);
            if (error_pulses != 1 || seen_error_code != wanted ||
                seen_error_tag != active_tag ||
                seen_error_page != active_page ||
                seen_error_stream != active_stream || abort_pulses != 0 ||
                error_valid || aborted || verified_valid || busy) begin
                $display("FAIL error want=%02x got pulses=%0d code=%02x tag=%016x/%016x page=%0d/%0d stream=%0d/%0d abort=%0d verified=%0d busy=%0d",
                         wanted, error_pulses, seen_error_code,
                         seen_error_tag, active_tag,
                         seen_error_page, active_page,
                         seen_error_stream, active_stream,
                         abort_pulses, verified_valid, busy);
                errors = errors + 1;
            end
        end
    endtask

    task wait_abort_status;
        begin
            timeout = 0;
            while (abort_pulses == 0 && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            repeat (2) @(negedge clk);
            if (abort_pulses != 1 || seen_abort_tag != active_tag ||
                seen_abort_page != active_page ||
                seen_abort_stream != active_stream || error_pulses != 0 ||
                error_valid || aborted || verified_valid || busy) begin
                $display("FAIL abort pulses=%0d tag=%016x/%016x page=%0d/%0d stream=%0d/%0d err=%0d verified=%0d busy=%0d",
                         abort_pulses, seen_abort_tag, active_tag,
                         seen_abort_page, active_page,
                         seen_abort_stream, active_stream,
                         error_pulses, verified_valid, busy);
                errors = errors + 1;
            end
        end
    endtask

    task wait_verified_and_consume;
        integer handshakes_before;
        reg [63:0] hold_tag;
        reg [13:0] hold_record;
        reg [13:0] hold_padding;
        begin
            allow_verified = 1;
            timeout = 0;
            while (!verified_valid && error_pulses == 0 &&
                   abort_pulses == 0 && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!verified_valid)
                $fatal(1, "verified-valid watchdog expired error=%0d abort=%0d",
                       error_pulses, abort_pulses);
            if (error_pulses != 0 || abort_pulses != 0 || !busy ||
                verified_task_tag != active_tag ||
                verified_page_index != active_page ||
                verified_page_count != active_page_count ||
                verified_token_base != active_token_base ||
                verified_token_count != active_tokens ||
                verified_expected_symbols != active_symbols ||
                verified_raw_mode != active_raw ||
                verified_stream_is_v != active_stream ||
                verified_payload_bytes != active_payload ||
                verified_scale_format_id != active_scale_id ||
                verified_record_bytes != active_record ||
                verified_page_window_bytes != active_window ||
                verified_scale_slice_bytes != active_scale_bytes ||
                verified_padding_bytes != active_window-active_record) begin
                $display("FAIL verified descriptor/profile scale_bits=%0d", SCALE_BITS);
                errors = errors + 1;
            end

            hold_tag = verified_task_tag;
            hold_record = verified_record_bytes;
            hold_padding = verified_padding_bytes;
            verified_ready = 0;
            repeat (3) begin
                @(negedge clk);
                if (!verified_valid || verified_task_tag != hold_tag ||
                    verified_page_index != active_page ||
                    verified_page_count != active_page_count ||
                    verified_token_base != active_token_base ||
                    verified_token_count != active_tokens ||
                    verified_expected_symbols != active_symbols ||
                    verified_raw_mode != active_raw ||
                    verified_stream_is_v != active_stream ||
                    verified_payload_bytes != active_payload ||
                    verified_scale_format_id != active_scale_id ||
                    verified_record_bytes != hold_record ||
                    verified_page_window_bytes != active_window ||
                    verified_scale_slice_bytes != active_scale_bytes ||
                    verified_padding_bytes != hold_padding || cmd_ready ||
                    data_ready || scale_ready || error_pulses != 0 ||
                    abort_pulses != 0) begin
                    $display("FAIL verified output changed/accepted under backpressure");
                    errors = errors + 1;
                end
            end
            handshakes_before = verified_handshakes;
            verified_ready = 1;
            @(negedge clk);
            verified_ready = 0;
            @(negedge clk);
            if (verified_valid || busy || !cmd_ready ||
                verified_handshakes != handshakes_before + 1 ||
                error_pulses != 0 || abort_pulses != 0) begin
                $display("FAIL verified consume valid=%0d busy=%0d ready=%0d handshakes=%0d/%0d",
                         verified_valid, busy, cmd_ready,
                         verified_handshakes, handshakes_before + 1);
                errors = errors + 1;
            end
            allow_verified = 0;
        end
    endtask

    task run_success;
        input integer fragmented_header;
        input integer fragmented_scale;
        begin
            issue_active_command();
            if (verified_valid || scale_ready)
                $fatal(1, "verification/scale exposed before data");
            if (fragmented_header)
                drive_data_fragmented_header();
            else
                drive_data_standard(0);
            if (verified_valid)
                $fatal(1, "verified before scale slice");
            drive_scale_standard(fragmented_scale);
            wait_verified_and_consume();
        end
    endtask

    task pulse_abort;
        begin
            abort = 1;
            #1;
            if (data_ready || scale_ready || verified_valid)
                $fatal(1, "abort gating was not immediate");
            @(negedge clk);
            abort = 0;
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            rst_n = 0;
            cmd_valid = 0;
            data_valid = 0;
            scale_valid = 0;
            verified_ready = 0;
            abort = 0;
            repeat (2) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            allow_verified = 0;
            data_phase_done = 0;
            if (!cmd_ready || busy || verified_valid || data_ready ||
                scale_ready || error_valid || aborted) begin
                $display("FAIL reset left validator state alive");
                errors = errors + 1;
            end
        end
    endtask

    task rebuild_profile;
        input [63:0] tag;
        begin
            if (SCALE_BITS == 12)
                build_k_uq4_8(48, tag);
            else
                build_v_uq5_11(tag);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // Profile-positive tiny vectors.  SCALE12 proves both exact record and
        // legal zero-padded window; SCALE16 proves the minimal V/UQ5.11 page.
        if (SCALE_BITS == 12) begin
            build_k_uq4_8(44, TAG_BASE + 1);
            run_success(0, 0);
            build_k_uq4_8(48, TAG_BASE + 2);
            run_success(1, 1);

            // The opposite frozen profile must not be silently accepted.
            build_v_uq5_11(TAG_BASE + 3);
            issue_active_command();
            drive_header_standard();
            wait_error_code(ERR_SCALE_MISMATCH);
        end else begin
            build_v_uq5_11(TAG_BASE + 1);
            run_success(0, 0);
            build_v_uq5_11(TAG_BASE + 2);
            run_success(1, 1);

            build_k_uq4_8(44, TAG_BASE + 3);
            issue_active_command();
            drive_header_standard();
            wait_error_code(ERR_SCALE_MISMATCH);
            build_k_uq4_8(48, TAG_BASE + 4);
            issue_active_command();
            drive_header_standard();
            wait_error_code(ERR_SCALE_MISMATCH);
        end

        // The scheduler deliberately permits more than the minimum alignment
        // fill.  Twenty zero bytes after the record are legal and excluded
        // from CRC in both compile-time scale profiles.
        if (SCALE_BITS == 12) begin
            build_k_uq4_8(64, TAG_BASE + 8'h08);
        end else begin
            build_v_uq5_11(TAG_BASE + 8'h08);
            active_window = 80;
        end
        run_success(0, 1);

        build_full_raw(TAG_BASE + 8'h09);
        run_success(1, 1);
        if (data_input_stall_cycles == 0) begin
            $display("FAIL full RAW data source never exercised input backpressure");
            errors = errors + 1;
        end
        if (SCALE_BITS == 12 && scale_input_stall_cycles == 0) begin
            $display("FAIL full RAW SCALE12 source never exercised input backpressure");
            errors = errors + 1;
        end

        // Command descriptor fault identities.
        rebuild_profile(TAG_BASE + 8'h10);
        load_command_fields(); cmd_page_count = 0;
        issue_loaded_command(); wait_error_code(ERR_PAGE_DESCRIPTOR);
        rebuild_profile(TAG_BASE + 8'h11);
        load_command_fields(); cmd_expected_symbols = 129;
        issue_loaded_command(); wait_error_code(ERR_TOKEN_DESCRIPTOR);
        rebuild_profile(TAG_BASE + 8'h12);
        load_command_fields(); cmd_page_window_bytes = 11;
        issue_loaded_command(); wait_error_code(ERR_WINDOW_DESCRIPTOR);
        rebuild_profile(TAG_BASE + 8'h13);
        load_command_fields(); cmd_scale_slice_bytes = 3;
        issue_loaded_command(); wait_error_code(ERR_SCALE_DESCRIPTOR);

        // Header, cross-descriptor identity, and record/window validation.
        rebuild_profile(TAG_BASE + 8'h20);
        record_mem[0] = 8'h02;
        issue_active_command(); drive_header_standard();
        wait_error_code(ERR_HEADER_MAGIC);

        rebuild_profile(TAG_BASE + 8'h21);
        record_mem[2] = record_mem[2] ^ 8'h02;
        issue_active_command(); drive_header_standard();
        wait_error_code(ERR_STREAM_MISMATCH);

        rebuild_profile(TAG_BASE + 8'h22);
        record_mem[3] = 8'h01;
        issue_active_command(); drive_header_standard();
        wait_error_code(ERR_TOKEN_MISMATCH);

        rebuild_profile(TAG_BASE + 8'h23);
        if (SCALE_BITS == 12)
            record_mem[4] = 8'd37; // 12+37 > 48, still compressed < raw K
        else
            record_mem[4] = 8'd53; // 12+53 > 64, still compressed < raw V
        issue_active_command(); drive_header_standard();
        wait_error_code(ERR_RECORD_WINDOW);

        // CRC scope: a structurally valid header-prefix change, payload bit,
        // scale bit, and stored-CRC bit each fail only at the CRC gate.
        rebuild_profile(TAG_BASE + 8'h30);
        record_mem[4] = record_mem[4] + 1'b1;
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); wait_error_code(ERR_HEADER_CRC);

        rebuild_profile(TAG_BASE + 8'h31);
        record_mem[12] = record_mem[12] ^ 8'h01;
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); wait_error_code(ERR_HEADER_CRC);

        rebuild_profile(TAG_BASE + 8'h32);
        scale_mem[0] = scale_mem[0] ^ 8'h01;
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); wait_error_code(ERR_HEADER_CRC);

        rebuild_profile(TAG_BASE + 8'h33);
        record_mem[8] = record_mem[8] ^ 8'h01;
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); wait_error_code(ERR_HEADER_CRC);

        rebuild_profile(TAG_RESTART + 8'h33);
        run_success(1, 1);

        // Alignment padding is outside CRC but is independently fail-closed.
        rebuild_profile(TAG_BASE + 8'h34);
        record_mem[active_record] = 8'h01;
        issue_active_command(); drive_data_standard(0);
        wait_error_code(ERR_NONZERO_PADDING);

        // Header completion at offset 11 carries one declared payload byte
        // and two early padding bytes in the same beat.  A nonzero early pad
        // must fail before scale or CRC publication.
        rebuild_profile(TAG_BASE + 8'h35);
        active_window = 16;
        active_record = 13;
        active_payload = 1;
        record_mem[4] = 8'h01;
        record_mem[5] = 8'h00;
        record_mem[12] = 8'h00;
        record_mem[13] = 8'h01;
        record_mem[14] = 8'h00;
        record_mem[15] = 8'h00;
        issue_active_command();
        send_data_piece(0, 4, 0);
        send_data_piece(4, 4, 0);
        send_data_piece(8, 3, 0);
        send_data_piece(11, 4, 0);
        wait_error_code(ERR_NONZERO_PADDING);

        // Data identity and every framing component: offset, mask, LAST.
        rebuild_profile(TAG_BASE + 8'h40);
        issue_active_command();
        send_data_raw(word_from_record(0, 4), 4'hf, 0, 0,
                      active_tag ^ 64'h1, active_page, active_stream);
        wait_error_code(ERR_DATA_TAG);

        rebuild_profile(TAG_BASE + 8'h45);
        issue_active_command();
        send_data_raw(word_from_record(0, 4), 4'hf, 0, 0,
                      active_tag, active_page + 1'b1, active_stream);
        wait_error_code(ERR_DATA_TAG);

        rebuild_profile(TAG_BASE + 8'h46);
        issue_active_command();
        send_data_raw(word_from_record(0, 4), 4'hf, 0, 0,
                      active_tag, active_page, !active_stream);
        wait_error_code(ERR_DATA_TAG);

        rebuild_profile(TAG_BASE + 8'h41);
        issue_active_command();
        send_data_raw(word_from_record(0, 4), 4'hf, 1, 0,
                      active_tag, active_page, active_stream);
        wait_error_code(ERR_DATA_FRAMING);

        rebuild_profile(TAG_BASE + 8'h42);
        issue_active_command();
        send_data_raw(word_from_record(0, 2), 4'b0101, 0, 0,
                      active_tag, active_page, active_stream);
        wait_error_code(ERR_DATA_FRAMING);

        rebuild_profile(TAG_BASE + 8'h43);
        issue_active_command();
        send_data_raw(word_from_record(0, 4), 4'hf, 0, 1,
                      active_tag, active_page, active_stream);
        wait_error_code(ERR_DATA_FRAMING);

        rebuild_profile(TAG_BASE + 8'h44);
        issue_active_command(); drive_data_standard(1);
        wait_error_code(ERR_DATA_FRAMING);

        // Scale identity and framing are checked independently after a valid
        // complete data window.
        rebuild_profile(TAG_BASE + 8'h48);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'h3, 0, 1,
                       active_tag ^ 64'h1, active_page, active_stream);
        wait_error_code(ERR_SCALE_TAG);

        rebuild_profile(TAG_BASE + 8'h4c);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'h3, 0, 1,
                       active_tag, active_page + 1'b1, active_stream);
        wait_error_code(ERR_SCALE_TAG);

        rebuild_profile(TAG_BASE + 8'h4d);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'h3, 0, 1,
                       active_tag, active_page, !active_stream);
        wait_error_code(ERR_SCALE_TAG);

        rebuild_profile(TAG_BASE + 8'h49);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'h3, 1, 1,
                       active_tag, active_page, active_stream);
        wait_error_code(ERR_SCALE_FRAMING);

        rebuild_profile(TAG_BASE + 8'h4a);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'b0101, 0, 1,
                       active_tag, active_page, active_stream);
        wait_error_code(ERR_SCALE_FRAMING);

        rebuild_profile(TAG_BASE + 8'h4b);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 2), 4'h3, 0, 0,
                       active_tag, active_page, active_stream);
        wait_error_code(ERR_SCALE_FRAMING);

        // A recomputed CRC makes malformed UQ4.8 tail padding an independent
        // scale-reader fault rather than a CRC fault.
        if (SCALE_BITS == 12) begin
            build_k_uq4_8(48, TAG_BASE + 8'h50);
            record_mem[8] = 8'h25; record_mem[9] = 8'hae;
            record_mem[10] = 8'h5b; record_mem[11] = 8'hab;
            scale_mem[1] = 8'hf1;
            issue_active_command(); drive_data_standard(0);
            drive_scale_standard(0); wait_error_code(ERR_SCALE12_PADDING);
        end

        // Abort before input, midway through a fragmented header, after data,
        // midway through scale, and while a verified descriptor is held.
        rebuild_profile(TAG_BASE + 8'h60);
        issue_active_command(); pulse_abort(); wait_abort_status();

        rebuild_profile(TAG_BASE + 8'h61);
        issue_active_command(); send_data_piece(0, 1, 0);
        pulse_abort(); wait_abort_status();

        rebuild_profile(TAG_BASE + 8'h62);
        issue_active_command(); drive_data_standard(0);
        pulse_abort(); wait_abort_status();

        rebuild_profile(TAG_BASE + 8'h63);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 1), 4'h1, 0, 0,
                       active_tag, active_page, active_stream);
        pulse_abort(); wait_abort_status();

        rebuild_profile(TAG_RESTART + 8'h63);
        run_success(1, 1);

        rebuild_profile(TAG_BASE + 8'h64);
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); allow_verified = 1;
        timeout = 0;
        while (!verified_valid && timeout < WATCHDOG) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (!verified_valid)
            $fatal(1, "verified hold timeout before abort");
        before_count = verified_handshakes;
        verified_ready = 1;
        pulse_abort();
        verified_ready = 0;
        wait_abort_status();
        if (verified_handshakes != before_count) begin
            $display("FAIL abort allowed a held verified handshake");
            errors = errors + 1;
        end
        allow_verified = 0;

        // A presented data beat on the abort edge is not a ghost handshake.
        rebuild_profile(TAG_BASE + 8'h65);
        issue_active_command();
        timeout = 0;
        while (!data_ready && timeout < 1000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (!data_ready)
            $fatal(1, "data-ready timeout before coincident abort");
        before_count = data_handshakes;
        data_data = word_from_record(0, 4);
        data_byte_valid = 4'hf;
        data_byte_offset = 0;
        data_last = 0;
        data_task_tag = active_tag;
        data_page_index = active_page;
        data_stream_is_v = active_stream;
        data_valid = 1;
        abort = 1;
        #1;
        if (data_ready)
            $fatal(1, "coincident abort did not gate data_ready");
        @(negedge clk);
        data_valid = 0;
        data_byte_valid = 0;
        abort = 0;
        wait_abort_status();
        if (data_handshakes != before_count) begin
            $display("FAIL coincident abort accepted a ghost data beat");
            errors = errors + 1;
        end

        // The identical priority rule applies after data completion when a
        // scale beat is presented on the abort edge.
        rebuild_profile(TAG_BASE + 8'h66);
        issue_active_command(); drive_data_standard(0);
        timeout = 0;
        while (!scale_ready && timeout < 1000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (!scale_ready)
            $fatal(1, "scale-ready timeout before coincident abort");
        before_count = scale_handshakes;
        scale_data = word_from_scale(0, 2);
        scale_byte_valid = 4'h3;
        scale_byte_offset = 0;
        scale_last = 1;
        scale_task_tag = active_tag;
        scale_page_index = active_page;
        scale_stream_is_v = active_stream;
        scale_valid = 1;
        abort = 1;
        #1;
        if (scale_ready)
            $fatal(1, "coincident abort did not gate scale_ready");
        @(negedge clk);
        scale_valid = 0;
        scale_byte_valid = 0;
        scale_last = 0;
        abort = 0;
        wait_abort_status();
        if (scale_handshakes != before_count) begin
            $display("FAIL coincident abort accepted a ghost scale beat");
            errors = errors + 1;
        end

        // Reset erases a partially loaded payload, then a distinct identity
        // must verify without inheriting its bytes or CRC state.
        rebuild_profile(TAG_BASE + 8'h68);
        issue_active_command(); drive_header_standard();
        send_data_piece(12, 4, 0);
        reset_dut();
        rebuild_profile(TAG_RESTART + 8'h68);
        run_success(1, 1);

        // Reset separately in the scale phase and prove another clean tagged
        // restart.  A one-byte fragment leaves real scale reservoir state.
        rebuild_profile(TAG_BASE + 8'h6a);
        issue_active_command(); drive_data_standard(0);
        send_scale_raw(word_from_scale(0, 1), 4'h1, 0, 0,
                       active_tag, active_page, active_stream);
        reset_dut();
        rebuild_profile(TAG_RESTART + 8'h6a);
        run_success(0, 1);

        // Reset also suppresses a fully verified descriptor under backpressure.
        rebuild_profile(TAG_BASE + 8'h69);
        issue_active_command(); drive_data_standard(0);
        drive_scale_standard(0); allow_verified = 1;
        timeout = 0;
        while (!verified_valid && timeout < WATCHDOG) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (!verified_valid)
            $fatal(1, "verified hold timeout before reset");
        reset_dut();

        // Distinct short restart proves no prior header/CRC/tag/tail survives.
        rebuild_profile(TAG_RESTART + SCALE_BITS);
        run_success(1, 1);

        if (errors == 0) begin
            $display("TB PASS: page128 record validator scale_bits=%0d", SCALE_BITS);
            $finish;
        end
        $fatal(1, "TB FAIL: page128 record validator scale_bits=%0d errors=%0d",
               SCALE_BITS, errors);
    end
endmodule

`default_nettype wire
