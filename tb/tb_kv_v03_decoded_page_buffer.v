// tb_kv_v03_decoded_page_buffer.v
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_decoded_page_buffer;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam integer STREAM_IS_V = (SCALE_BITS == 16);
    localparam integer CONSTANT_CODE = STREAM_IS_V ? 5 : 0;
    localparam [63:0] TAG_COMPRESSED = 64'h0102_0304_0506_0708;
    localparam [63:0] TAG_RAW        = 64'h1112_1314_1516_1718;
    localparam [63:0] TAG_FULL       = 64'h2122_2324_2526_2728;
    localparam [63:0] TAG_FAULT      = 64'h3132_3334_3536_3738;
    localparam [63:0] TAG_ABORT      = 64'h4142_4344_4546_4748;
    localparam [63:0] TAG_RESTART    = 64'h5152_5354_5556_5758;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg start_valid = 1'b0;
    wire start_ready;
    reg [63:0] start_task_tag = 64'b0;
    reg [4:0] start_page_index = 5'b0;
    reg start_stream_is_v = 1'b0;
    reg start_raw_mode = 1'b0;
    reg [15:0] start_payload_bytes = 16'b0;
    reg [14:0] start_expected_symbols = 15'b0;
    reg [7:0] start_token_count = 8'b0;
    reg [8:0] start_scale_slice_bytes = 9'b0;
    reg abort = 1'b0;
    reg page_release = 1'b0;
    wire commit_valid;
    reg commit_ready = 1'b0;
    wire page_active;
    wire busy;
    wire [63:0] page_task_tag;
    wire [4:0] page_index;
    wire page_stream_is_v;
    wire page_raw_mode;
    wire [15:0] page_payload_bytes;
    wire [14:0] page_expected_symbols;
    wire [7:0] page_token_count;
    wire [8:0] page_scale_slice_bytes;

    wire data_rd_en;
    wire [11:0] data_rd_word_addr;
    reg data_rd_valid = 1'b0;
    reg [31:0] data_rd_data = 32'b0;
    reg [3:0] data_rd_byte_valid = 4'b0;
    reg data_rd_last = 1'b0;
    reg [13:0] data_rd_byte_offset = 14'b0;
    wire scale_rd_en;
    wire [6:0] scale_rd_word_addr;
    reg scale_rd_valid = 1'b0;
    reg [31:0] scale_rd_data = 32'b0;
    reg [3:0] scale_rd_byte_valid = 4'b0;
    reg scale_rd_last = 1'b0;
    reg [8:0] scale_rd_byte_offset = 9'b0;

    reg code_rd_en = 1'b0;
    reg [13:0] code_rd_addr = 14'b0;
    wire code_rd_valid;
    wire signed [4:0] code_rd_data;
    reg committed_scale_rd_en = 1'b0;
    reg [6:0] committed_scale_rd_addr = 7'b0;
    wire committed_scale_rd_valid;
    wire [SCALE_BITS-1:0] committed_scale_rd_data;

    wire error_valid;
    wire [2:0] error_source;
    wire [7:0] error_code;
    wire [63:0] error_task_tag;
    wire [4:0] error_page_index;
    wire error_stream_is_v;
    wire aborted;
    wire [63:0] aborted_task_tag;
    wire [4:0] aborted_page_index;
    wire aborted_stream_is_v;
    reg clear_counters = 1'b0;
    wire [31:0] decoder_starvation_cycles;
    wire [31:0] scale_starvation_cycles;
    wire [31:0] raw_fallback_count;

    kv_v03_decoded_page_buffer #(
        .SCALE_BITS(SCALE_BITS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_task_tag(start_task_tag),
        .start_page_index(start_page_index),
        .start_stream_is_v(start_stream_is_v),
        .start_raw_mode(start_raw_mode),
        .start_payload_bytes(start_payload_bytes),
        .start_expected_symbols(start_expected_symbols),
        .start_token_count(start_token_count),
        .start_scale_slice_bytes(start_scale_slice_bytes),
        .abort(abort), .page_release(page_release),
        .commit_valid(commit_valid), .commit_ready(commit_ready),
        .page_active(page_active), .busy(busy),
        .page_task_tag(page_task_tag), .page_index(page_index),
        .page_stream_is_v(page_stream_is_v),
        .page_raw_mode(page_raw_mode),
        .page_payload_bytes(page_payload_bytes),
        .page_expected_symbols(page_expected_symbols),
        .page_token_count(page_token_count),
        .page_scale_slice_bytes(page_scale_slice_bytes),
        .data_rd_en(data_rd_en),
        .data_rd_word_addr(data_rd_word_addr),
        .data_rd_valid(data_rd_valid), .data_rd_data(data_rd_data),
        .data_rd_byte_valid(data_rd_byte_valid),
        .data_rd_last(data_rd_last),
        .data_rd_byte_offset(data_rd_byte_offset),
        .scale_rd_en(scale_rd_en),
        .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(scale_rd_valid), .scale_rd_data(scale_rd_data),
        .scale_rd_byte_valid(scale_rd_byte_valid),
        .scale_rd_last(scale_rd_last),
        .scale_rd_byte_offset(scale_rd_byte_offset),
        .code_rd_en(code_rd_en), .code_rd_addr(code_rd_addr),
        .code_rd_valid(code_rd_valid), .code_rd_data(code_rd_data),
        .committed_scale_rd_en(committed_scale_rd_en),
        .committed_scale_rd_addr(committed_scale_rd_addr),
        .committed_scale_rd_valid(committed_scale_rd_valid),
        .committed_scale_rd_data(committed_scale_rd_data),
        .error_valid(error_valid), .error_source(error_source),
        .error_code(error_code), .error_task_tag(error_task_tag),
        .error_page_index(error_page_index),
        .error_stream_is_v(error_stream_is_v),
        .aborted(aborted), .aborted_task_tag(aborted_task_tag),
        .aborted_page_index(aborted_page_index),
        .aborted_stream_is_v(aborted_stream_is_v),
        .clear_counters(clear_counters),
        .decoder_starvation_cycles(decoder_starvation_cycles),
        .scale_starvation_cycles(scale_starvation_cycles),
        .raw_fallback_count(raw_fallback_count)
    );

    reg [7:0] data_bytes [0:10255];
    reg [7:0] scale_bytes [0:255];
    reg signed [4:0] expected_codes [0:16383];
    reg signed [4:0] equality_codes [0:127];
    reg [15:0] expected_scales [0:127];
    integer active_window_bytes;
    integer active_scale_bytes;
    integer active_symbol_count;
    integer active_token_count;
    integer errors = 0;
    integer i;
    integer j;
    integer bit_index;
    integer byte_index;
    integer bit_in_byte;
    integer code_value;
    integer scale_value;
    integer timeout;

    reg [15:0] lfsr = 16'h1ace;
    integer forced_data_latency = -1;
    integer forced_scale_latency = -1;
    reg data_model_pending = 1'b0;
    reg [11:0] data_model_addr = 12'b0;
    integer data_model_delay = 0;
    reg scale_model_pending = 1'b0;
    reg [6:0] scale_model_addr = 7'b0;
    integer scale_model_delay = 0;
    reg fault_data_offset = 1'b0;
    reg fault_data_mask = 1'b0;
    reg fault_data_early_last = 1'b0;
    reg fault_scale_offset = 1'b0;
    reg fault_scale_mask = 1'b0;
    reg fault_scale_last = 1'b0;

    function [3:0] mask_for_bytes;
        input integer count;
        begin
            if (count <= 1)
                mask_for_bytes = 4'b0001;
            else if (count == 2)
                mask_for_bytes = 4'b0011;
            else if (count == 3)
                mask_for_bytes = 4'b0111;
            else
                mask_for_bytes = 4'b1111;
        end
    endfunction

    // Random response latency models a registered scratch path with bubbles.
    // There is at most one outstanding request per independent read port.
    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 16'h1ace;
            data_model_pending <= 1'b0;
            scale_model_pending <= 1'b0;
            data_rd_valid <= 1'b0;
            scale_rd_valid <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0],
                     lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            data_rd_valid <= 1'b0;
            scale_rd_valid <= 1'b0;

            if (data_rd_en) begin
                if (data_model_pending) begin
                    $display("FAIL scratch data request overlap");
                    errors = errors + 1;
                end
                data_model_pending <= 1'b1;
                data_model_addr <= data_rd_word_addr;
                data_model_delay <= (forced_data_latency >= 0) ?
                                    forced_data_latency : lfsr[2:0];
            end else if (data_model_pending) begin
                if (data_model_delay > 0) begin
                    data_model_delay <= data_model_delay - 1;
                end else begin
                    data_model_pending <= 1'b0;
                    data_rd_valid <= 1'b1;
                    data_rd_data <= {
                        data_bytes[(data_model_addr*4)+3],
                        data_bytes[(data_model_addr*4)+2],
                        data_bytes[(data_model_addr*4)+1],
                        data_bytes[(data_model_addr*4)+0]};
                    data_rd_byte_valid <= fault_data_mask ?
                                          4'b0101 : 4'b1111;
                    data_rd_last <= fault_data_early_last ? 1'b1 :
                        (((data_model_addr + 1) * 4) >= active_window_bytes);
                    data_rd_byte_offset <= (data_model_addr * 4) +
                                           (fault_data_offset ? 4 : 0);
                    fault_data_offset <= 1'b0;
                    fault_data_mask <= 1'b0;
                    fault_data_early_last <= 1'b0;
                end
            end

            if (scale_rd_en) begin
                if (scale_model_pending) begin
                    $display("FAIL scratch scale request overlap");
                    errors = errors + 1;
                end
                scale_model_pending <= 1'b1;
                scale_model_addr <= scale_rd_word_addr;
                scale_model_delay <= (forced_scale_latency >= 0) ?
                                     forced_scale_latency : lfsr[5:3];
            end else if (scale_model_pending) begin
                if (scale_model_delay > 0) begin
                    scale_model_delay <= scale_model_delay - 1;
                end else begin
                    scale_model_pending <= 1'b0;
                    scale_rd_valid <= 1'b1;
                    scale_rd_data <= {
                        scale_bytes[(scale_model_addr*4)+3],
                        scale_bytes[(scale_model_addr*4)+2],
                        scale_bytes[(scale_model_addr*4)+1],
                        scale_bytes[(scale_model_addr*4)+0]};
                    if (fault_scale_mask)
                        scale_rd_byte_valid <= 4'b0101;
                    else if (((scale_model_addr + 1) * 4) >
                             active_scale_bytes)
                        scale_rd_byte_valid <= mask_for_bytes(
                            active_scale_bytes - (scale_model_addr * 4));
                    else
                        scale_rd_byte_valid <= 4'b1111;
                    scale_rd_last <= fault_scale_last ? 1'b0 :
                        (((scale_model_addr + 1) * 4) >=
                         active_scale_bytes);
                    scale_rd_byte_offset <= (scale_model_addr * 4) +
                                            (fault_scale_offset ? 4 : 0);
                    fault_scale_offset <= 1'b0;
                    fault_scale_mask <= 1'b0;
                    fault_scale_last <= 1'b0;
                end
            end
        end
    end

    task clear_images;
        begin
            for (i = 0; i < 10256; i = i + 1)
                data_bytes[i] = 8'b0;
            for (i = 0; i < 256; i = i + 1)
                scale_bytes[i] = 8'b0;
            for (i = 0; i < 16384; i = i + 1)
                expected_codes[i] = 5'sd0;
            for (i = 0; i < 128; i = i + 1)
                expected_scales[i] = 16'b0;
        end
    endtask

    task build_scales;
        input integer tokens;
        begin
            active_scale_bytes = ((tokens * SCALE_BITS) + 7) / 8;
            for (i = 0; i < tokens; i = i + 1) begin
                if (SCALE_BITS == 12)
                    scale_value = ((i * 37) + 13) & 12'hfff;
                else
                    scale_value = ((i * 509) + 257) & 16'hffff;
                expected_scales[i] = scale_value;
                for (j = 0; j < SCALE_BITS; j = j + 1) begin
                    bit_index = (i * SCALE_BITS) + j;
                    byte_index = bit_index / 8;
                    bit_in_byte = bit_index % 8;
                    if ((scale_value >> j) & 1)
                        scale_bytes[byte_index] =
                            scale_bytes[byte_index] | (1 << bit_in_byte);
                end
            end
        end
    endtask

    task build_constant_page;
        input integer raw_page;
        input integer tokens;
        begin
            clear_images();
            active_token_count = tokens;
            active_symbol_count = tokens * 128;
            for (i = 0; i < active_symbol_count; i = i + 1)
                expected_codes[i] = CONSTANT_CODE;
            if (raw_page != 0) begin
                start_payload_bytes = (active_symbol_count *
                    (STREAM_IS_V ? 5 : 4)) / 8;
                for (i = 0; i < active_symbol_count; i = i + 1) begin
                    code_value = CONSTANT_CODE;
                    for (j = 0; j < (STREAM_IS_V ? 5 : 4); j = j + 1) begin
                        bit_index = (i * (STREAM_IS_V ? 5 : 4)) + j;
                        byte_index = 12 + (bit_index / 8);
                        bit_in_byte = bit_index % 8;
                        if ((code_value >> j) & 1)
                            data_bytes[byte_index] =
                                data_bytes[byte_index] | (1 << bit_in_byte);
                    end
                end
            end else begin
                // K=0 is code 00; V=+5 is code 0000.  Both checked-in static
                // codebook entries therefore have an all-zero page image.
                start_payload_bytes = (active_symbol_count *
                    (STREAM_IS_V ? 4 : 2)) / 8;
            end
            build_scales(tokens);
            active_window_bytes =
                (((12 + start_payload_bytes + 4) + 15) / 16) * 16;
            start_stream_is_v = STREAM_IS_V;
            start_raw_mode = (raw_page != 0);
            start_expected_symbols = active_symbol_count;
            start_token_count = tokens;
            start_scale_slice_bytes = active_scale_bytes;
        end
    endtask

    task build_full_raw_page;
        begin
            clear_images();
            active_token_count = 128;
            active_symbol_count = 16384;
            start_payload_bytes = STREAM_IS_V ? 10240 : 8192;
            for (i = 0; i < active_symbol_count; i = i + 1) begin
                if (STREAM_IS_V)
                    code_value = ((i * 7 + 2) % 31) - 15;
                else
                    code_value = ((i * 5 + 3) % 15) - 7;
                expected_codes[i] = code_value;
                for (j = 0; j < (STREAM_IS_V ? 5 : 4); j = j + 1) begin
                    bit_index = (i * (STREAM_IS_V ? 5 : 4)) + j;
                    byte_index = 12 + (bit_index / 8);
                    bit_in_byte = bit_index % 8;
                    if ((code_value >> j) & 1)
                        data_bytes[byte_index] =
                            data_bytes[byte_index] | (1 << bit_in_byte);
                end
            end
            build_scales(128);
            active_window_bytes =
                (((12 + start_payload_bytes + 4) + 15) / 16) * 16;
            start_stream_is_v = STREAM_IS_V;
            start_raw_mode = 1'b1;
            start_expected_symbols = 16384;
            start_token_count = 128;
            start_scale_slice_bytes = active_scale_bytes;
        end
    endtask

    task issue_start;
        input [63:0] tag;
        input [4:0] page;
        begin
            timeout = 0;
            while (!start_ready && timeout < 200000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!start_ready) begin
                $display("FAIL start_ready timeout tag=%016x", tag);
                errors = errors + 1;
            end
            start_task_tag = tag;
            start_page_index = page;
            start_valid = 1'b1;
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task wait_commit;
        input [63:0] wanted_tag;
        input [4:0] wanted_page;
        begin
            timeout = 0;
            while (!commit_valid && !error_valid && timeout < 300000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!commit_valid) begin
                $display("FAIL commit timeout/error tag=%016x source=%0d code=%02x",
                         wanted_tag, error_source, error_code);
                errors = errors + 1;
            end else if (page_task_tag != wanted_tag ||
                         page_index != wanted_page ||
                         page_stream_is_v != STREAM_IS_V ||
                         page_raw_mode != start_raw_mode ||
                         page_payload_bytes != start_payload_bytes ||
                         page_expected_symbols != active_symbol_count ||
                         page_token_count != active_token_count ||
                         page_scale_slice_bytes != active_scale_bytes) begin
                $display("FAIL committed descriptor mismatch tag=%016x",
                         wanted_tag);
                errors = errors + 1;
            end
        end
    endtask

    task accept_commit;
        begin
            commit_ready = 1'b1;
            @(negedge clk);
            commit_ready = 1'b0;
            if (!page_active) begin
                $display("FAIL page did not become active");
                errors = errors + 1;
            end
        end
    endtask

    task verify_committed;
        input integer save_equality;
        input integer compare_equality;
        integer k;
        begin
            for (k = 0; k < active_symbol_count; k = k + 1) begin
                code_rd_addr = k[13:0];
                code_rd_en = 1'b1;
                @(negedge clk);
                if (!code_rd_valid ||
                    $signed(code_rd_data) !== $signed(expected_codes[k])) begin
                    $display("FAIL code[%0d] got=%0d want=%0d valid=%0d",
                             k, $signed(code_rd_data),
                             $signed(expected_codes[k]), code_rd_valid);
                    errors = errors + 1;
                end
                if (save_equality && k < 128)
                    equality_codes[k] = code_rd_data;
                if (compare_equality && k < 128 &&
                    code_rd_data !== equality_codes[k]) begin
                    $display("FAIL compressed/raw equality code[%0d]", k);
                    errors = errors + 1;
                end
            end
            code_rd_en = 1'b0;
            for (k = 0; k < active_token_count; k = k + 1) begin
                committed_scale_rd_addr = k[6:0];
                committed_scale_rd_en = 1'b1;
                @(negedge clk);
                if (!committed_scale_rd_valid ||
                    committed_scale_rd_data !==
                    expected_scales[k][SCALE_BITS-1:0]) begin
                    $display("FAIL scale[%0d] got=%x want=%x valid=%0d",
                             k, committed_scale_rd_data,
                             expected_scales[k][SCALE_BITS-1:0],
                             committed_scale_rd_valid);
                    errors = errors + 1;
                end
            end
            committed_scale_rd_en = 1'b0;
        end
    endtask

    task release_page;
        begin
            page_release = 1'b1;
            @(negedge clk);
            page_release = 1'b0;
            if (page_active || commit_valid) begin
                $display("FAIL release did not hide committed page");
                errors = errors + 1;
            end
        end
    endtask

    task expect_error;
        input [2:0] wanted_source;
        input [7:0] wanted_code;
        input [63:0] wanted_tag;
        begin
            timeout = 0;
            while (!error_valid && timeout < 200000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!error_valid || error_source != wanted_source ||
                error_code != wanted_code || error_task_tag != wanted_tag ||
                error_page_index != start_page_index ||
                error_stream_is_v != STREAM_IS_V ||
                commit_valid || page_active) begin
                $display("FAIL error got source=%0d code=%02x tag=%016x want source=%0d code=%02x tag=%016x",
                         error_source, error_code, error_task_tag,
                         wanted_source, wanted_code, wanted_tag);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    task expect_abort;
        input [63:0] wanted_tag;
        begin
            abort = 1'b1;
            @(negedge clk);
            if (!aborted || aborted_task_tag != wanted_tag ||
                aborted_page_index != start_page_index ||
                aborted_stream_is_v != STREAM_IS_V ||
                commit_valid || page_active) begin
                $display("FAIL tagged abort tag=%016x got=%016x",
                         wanted_tag, aborted_task_tag);
                errors = errors + 1;
            end
            abort = 1'b0;
            timeout = 0;
            while (!start_ready && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!start_ready) begin
                $display("FAIL no-reset abort drain/restart timeout");
                errors = errors + 1;
            end
        end
    endtask

    task run_short_restart;
        input [63:0] tag;
        begin
            build_constant_page(0, 1);
            issue_start(tag, 5'd9);
            wait_commit(tag, 5'd9);
            accept_commit();
            verify_committed(0, 0);
            // A prior long page must not make an out-of-range address visible.
            code_rd_addr = 14'd4095;
            code_rd_en = 1'b1;
            @(negedge clk);
            if (code_rd_valid) begin
                $display("FAIL stale code visible after short page");
                errors = errors + 1;
            end
            code_rd_en = 1'b0;
            committed_scale_rd_addr = 7'd127;
            committed_scale_rd_en = 1'b1;
            @(negedge clk);
            if (committed_scale_rd_valid) begin
                $display("FAIL stale scale visible after short page");
                errors = errors + 1;
            end
            committed_scale_rd_en = 1'b0;
            release_page();
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // Tiny compressed page generated from checked-in static code words.
        build_constant_page(0, 1);
        issue_start(TAG_COMPRESSED, 5'd1);
        wait_commit(TAG_COMPRESSED, 5'd1);
        // Commit backpressure must hold metadata and hide tentative memories.
        code_rd_en = 1'b1;
        code_rd_addr = 0;
        repeat (5) begin
            @(negedge clk);
            if (!commit_valid || code_rd_valid || page_active ||
                page_task_tag != TAG_COMPRESSED) begin
                $display("FAIL held commit/tentative visibility");
                errors = errors + 1;
            end
        end
        code_rd_en = 1'b0;
        accept_commit();
        verify_committed(1, 0);
        release_page();

        // Raw encoding of the same symbols must decode identically.
        build_constant_page(1, 1);
        issue_start(TAG_RAW, 5'd2);
        wait_commit(TAG_RAW, 5'd2);
        accept_commit();
        verify_committed(0, 1);
        release_page();

        // Full raw page128: K4/UQ4.8 in the SCALE12 run, V5/UQ5.11 in SCALE16.
        build_full_raw_page();
        issue_start(TAG_FULL, 5'd3);
        wait_commit(TAG_FULL, 5'd3);
        accept_commit();
        verify_committed(0, 0);
        release_page();
        if (raw_fallback_count != 2) begin
            $display("FAIL raw fallback counter got=%0d want=2",
                     raw_fallback_count);
            errors = errors + 1;
        end
        if (decoder_starvation_cycles == 0 || scale_starvation_cycles == 0) begin
            $display("FAIL randomized scratch starvation counters dec=%0d scale=%0d",
                     decoder_starvation_cycles, scale_starvation_cycles);
            errors = errors + 1;
        end

        // Invalid static prefix propagation.  Complete codebooks have no
        // naturally unused prefix, so corrupt one lookup entry to exercise
        // the decoder's fail-closed invalid-prefix path.
        build_constant_page(0, 1);
        // Keep the complete bad-prefix image in one final word.  An invalid
        // prefix cannot drain the decoder reservoir, so a longer image could
        // correctly stop accepting input before the final marker arrives.
        start_payload_bytes = 1;
        active_window_bytes = 32;
        if (STREAM_IS_V)
            dut.u_decoder.lookup[0] = 10'b0;
        else
            dut.u_decoder.alternate_lookup[0] = 10'b0;
        issue_start(TAG_FAULT, 5'd4);
        expect_error(3, 8'h01, TAG_FAULT);
        if (STREAM_IS_V)
            dut.u_decoder.lookup[0] = 10'h285;
        else
            dut.u_decoder.alternate_lookup[0] = 10'h240;

        // Truncated compressed page.
        build_constant_page(0, 1);
        start_payload_bytes = 1;
        active_window_bytes = 32;
        issue_start(TAG_FAULT + 1, 5'd5);
        expect_error(3, 8'h02, TAG_FAULT + 1);

        // Exact symbols followed by an extra compressed byte are trailing.
        build_constant_page(0, 1);
        start_payload_bytes = start_payload_bytes + 1'b1;
        active_window_bytes =
            (((12 + start_payload_bytes + 4) + 15) / 16) * 16;
        issue_start(TAG_FAULT + 2, 5'd6);
        expect_error(3, 8'h03, TAG_FAULT + 2);

        // Reserved raw narrow-range code (-8 for K, -16 for V).
        build_constant_page(1, 1);
        data_bytes[12] = STREAM_IS_V ? 8'h10 : 8'h08;
        issue_start(TAG_FAULT + 3, 5'd7);
        expect_error(3, 8'h04, TAG_FAULT + 3);

        // Scratch offset and framing failures retain the typed descriptor.
        build_constant_page(0, 1);
        fault_data_offset = 1'b1;
        issue_start(TAG_FAULT + 4, 5'd8);
        expect_error(2, 8'h02, TAG_FAULT + 4);
        build_constant_page(0, 1);
        fault_scale_mask = 1'b1;
        issue_start(TAG_FAULT + 5, 5'd9);
        expect_error(4, 8'h03, TAG_FAULT + 5);

        // Abort while a randomized scratch read is outstanding, then restart
        // without reset.  The drain state absorbs the tagged old response.
        build_full_raw_page();
        forced_data_latency = 12;
        forced_scale_latency = 12;
        issue_start(TAG_ABORT, 5'd10);
        timeout = 0;
        while (!dut.data_outstanding && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        expect_abort(TAG_ABORT);
        forced_data_latency = -1;
        forced_scale_latency = -1;
        run_short_restart(TAG_RESTART);

        // Abort after tentative code writes have begun.
        build_full_raw_page();
        forced_data_latency = 0;
        issue_start(TAG_ABORT + 1, 5'd11);
        timeout = 0;
        while (dut.code_write_count < 40 && timeout < 1000) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        expect_abort(TAG_ABORT + 1);
        forced_data_latency = -1;
        run_short_restart(TAG_RESTART + 1);

        // Abort while commit is held by downstream backpressure.
        build_constant_page(0, 1);
        issue_start(TAG_ABORT + 2, 5'd12);
        wait_commit(TAG_ABORT + 2, 5'd12);
        expect_abort(TAG_ABORT + 2);
        run_short_restart(TAG_RESTART + 2);

        // Reset during decode must immediately hide all tentative state and
        // permit a clean short-after-long restart.
        build_full_raw_page();
        forced_data_latency = 0;
        issue_start(TAG_ABORT + 3, 5'd13);
        timeout = 0;
        while (dut.code_write_count < 24 && timeout < 1000) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        if (commit_valid || page_active || code_rd_valid ||
            committed_scale_rd_valid) begin
            $display("FAIL reset did not hide tentative/committed state");
            errors = errors + 1;
        end
        rst_n = 1'b1;
        forced_data_latency = -1;
        run_short_restart(TAG_RESTART + 3);

        // Descriptor framing fault must fail before issuing any scratch read.
        build_constant_page(1, 1);
        start_expected_symbols = 127;
        issue_start(TAG_FAULT + 6, 5'd14);
        expect_error(1, 8'h01, TAG_FAULT + 6);

        if (errors == 0) begin
            $display("KV_V03_DECODED_PAGE_BUFFER_SCALE%0d_PASS", SCALE_BITS);
            $finish;
        end
        $fatal(1,
            "TB FAIL: decoded page buffer SCALE_BITS=%0d errors=%0d",
            SCALE_BITS, errors);
    end
endmodule

`default_nettype wire
