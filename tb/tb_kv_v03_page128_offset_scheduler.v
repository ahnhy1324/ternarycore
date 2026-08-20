// tb_kv_v03_page128_offset_scheduler.v -- fail-closed page128 planning tests.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif
`ifndef ADDR_WIDTH_VAL
`define ADDR_WIDTH_VAL 32
`endif

module tb_kv_v03_page128_offset_scheduler;
    localparam integer ADDR_WIDTH = `ADDR_WIDTH_VAL;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam integer SCALE_STRIDE = (SCALE_BITS == 12) ? 192 : 256;
    localparam [ADDR_WIDTH-1:0] DATA_BASE = 64'h0000_0000_0100_0000;
    localparam [ADDR_WIDTH-1:0] SCALE_BASE = 64'h0000_0000_0200_0000;
    localparam [ADDR_WIDTH-1:0] TOP_WINDOW_BASE =
        {ADDR_WIDTH{1'b1}} - 31;
    localparam [63:0] TEST_TAG = 64'h4b56_0303_1234_5678;
    localparam [63:0] FAULT_TAG = 64'h4b56_0303_dead_beef;

    reg clk = 0;
    reg rst_n = 0;
    reg cmd_valid = 0;
    wire cmd_ready;
    reg [12:0] cmd_context_len = 0;
    reg [ADDR_WIDTH-1:0] cmd_data_base = 0;
    reg [31:0] cmd_data_stream_bytes = 0;
    reg [ADDR_WIDTH-1:0] cmd_scale_base = 0;
    reg [31:0] cmd_scale_plane_bytes = 0;
    reg [31:0] cmd_offset_crc32 = 0;
    reg cmd_stream_is_v = 0;
    reg [63:0] cmd_task_tag = 0;
    reg abort = 0;

    reg offset_valid = 0;
    wire offset_ready;
    reg [31:0] offset_data = 0;
    reg offset_last = 0;

    wire page_valid;
    reg page_ready = 0;
    wire [4:0] page_index;
    wire [5:0] page_count;
    wire [12:0] token_base;
    wire [7:0] token_count;
    wire [14:0] expected_symbols;
    wire [ADDR_WIDTH-1:0] data_addr;
    wire [ADDR_WIDTH-1:0] data_limit;
    wire [31:0] page_window_bytes;
    wire [ADDR_WIDTH-1:0] scale_addr;
    wire [8:0] scale_slice_bytes;
    wire stream_is_v;
    wire [63:0] task_tag;
    wire busy, table_valid, done, aborted, error_valid;
    wire [7:0] error_code;

    integer errors = 0;
    integer page_handshakes = 0;
    integer table_count;
    integer test_stream_bytes;
    reg [31:0] table_words [0:31];

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (rst_n && page_valid && !table_valid)
            $fatal(1, "page_valid asserted without a validated table");
        if (page_valid && page_ready)
            page_handshakes <= page_handshakes + 1;
    end

    kv_v03_page128_offset_scheduler #(
        .ADDR_WIDTH(ADDR_WIDTH), .TAG_WIDTH(64), .SCALE_BITS(SCALE_BITS),
        .MAX_CONTEXT(4096)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_context_len(cmd_context_len), .cmd_data_base(cmd_data_base),
        .cmd_data_stream_bytes(cmd_data_stream_bytes),
        .cmd_scale_base(cmd_scale_base),
        .cmd_scale_plane_bytes(cmd_scale_plane_bytes),
        .cmd_offset_crc32(cmd_offset_crc32),
        .cmd_stream_is_v(cmd_stream_is_v), .cmd_task_tag(cmd_task_tag),
        .abort(abort),
        .offset_valid(offset_valid), .offset_ready(offset_ready),
        .offset_data(offset_data), .offset_last(offset_last),
        .page_valid(page_valid), .page_ready(page_ready),
        .page_index(page_index), .page_count(page_count),
        .token_base(token_base), .token_count(token_count),
        .expected_symbols(expected_symbols), .data_addr(data_addr),
        .data_limit(data_limit), .page_window_bytes(page_window_bytes),
        .scale_addr(scale_addr), .scale_slice_bytes(scale_slice_bytes),
        .stream_is_v(stream_is_v), .task_tag(task_tag),
        .busy(busy), .table_valid(table_valid), .done(done),
        .aborted(aborted), .error_valid(error_valid),
        .error_code(error_code)
    );

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

    function [31:0] table_crc;
        input integer count;
        reg [31:0] work;
        integer word_no, byte_no;
        begin
            work = 32'hffff_ffff;
            for (word_no = 0; word_no < count; word_no = word_no + 1)
                for (byte_no = 0; byte_no < 4; byte_no = byte_no + 1)
                    work = crc_byte(
                        work, table_words[word_no][byte_no*8 +: 8]);
            table_crc = work ^ 32'hffff_ffff;
        end
    endfunction

    task build_raw_k_table;
        input integer ctx;
        integer i, final_tokens;
        begin
            table_count = (ctx + 127) / 128;
            for (i = 0; i < table_count; i = i + 1)
                table_words[i] = i * 8208;
            final_tokens = ctx - (table_count - 1) * 128;
            test_stream_bytes = (table_count - 1) * 8208 +
                                12 + final_tokens * 64;
        end
    endtask

    task issue_command;
        input [12:0] ctx;
        input [ADDR_WIDTH-1:0] data_base_value;
        input [31:0] stream_bytes_value;
        input [ADDR_WIDTH-1:0] scale_base_value;
        input [31:0] scale_bytes_value;
        input [31:0] crc_value;
        input stream_value;
        input [63:0] tag_value;
        integer timeout;
        begin
            timeout = 0;
            while (!cmd_ready && timeout < 20) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready) begin
                $display("FAIL command interface did not become ready");
                errors = errors + 1;
            end
            @(negedge clk);
            cmd_context_len = ctx;
            cmd_data_base = data_base_value;
            cmd_data_stream_bytes = stream_bytes_value;
            cmd_scale_base = scale_base_value;
            cmd_scale_plane_bytes = scale_bytes_value;
            cmd_offset_crc32 = crc_value;
            cmd_stream_is_v = stream_value;
            cmd_task_tag = tag_value;
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task send_offset_word;
        input [31:0] value;
        input last;
        input integer gap_cycles;
        integer timeout, gap;
        begin
            for (gap = 0; gap < gap_cycles; gap = gap + 1)
                @(negedge clk);
            timeout = 0;
            while (!offset_ready && timeout < 30) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!offset_ready) begin
                $display("FAIL offset interface did not become ready");
                errors = errors + 1;
            end
            offset_data = value;
            offset_last = last;
            offset_valid = 1;
            @(negedge clk);
            offset_valid = 0;
            offset_last = 0;
            offset_data = 0;
        end
    endtask

    task send_valid_table;
        input integer count;
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                if (page_valid) begin
                    $display("FAIL page became visible before table validation");
                    errors = errors + 1;
                end
                send_offset_word(table_words[i], i == count - 1, i % 2);
            end
        end
    endtask

    task wait_for_table_or_error;
        integer timeout;
        begin
            timeout = 0;
            while (!table_valid && !error_valid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!table_valid && !error_valid) begin
                $display("FAIL table validation timeout");
                errors = errors + 1;
            end
        end
    endtask

    task expect_error;
        input [7:0] wanted;
        input integer old_handshakes;
        integer timeout;
        begin
            timeout = 0;
            while (!error_valid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!error_valid || error_code !== wanted || page_valid ||
                table_valid || busy) begin
                $display("FAIL error got valid=%0d code=%02x want=%02x page=%0d table=%0d busy=%0d",
                         error_valid, error_code, wanted, page_valid,
                         table_valid, busy);
                errors = errors + 1;
            end
            if (page_handshakes != old_handshakes) begin
                $display("FAIL fault exposed a page handshake");
                errors = errors + 1;
            end
        end
    endtask

    task check_and_consume_pages;
        input integer ctx;
        input [ADDR_WIDTH-1:0] expected_data_base;
        input [ADDR_WIDTH-1:0] expected_scale_base;
        input expected_stream;
        input [63:0] expected_tag;
        integer i, final_tokens, wanted_tokens, wanted_scale_bytes, timeout;
        reg [ADDR_WIDTH-1:0] held_data_addr, held_scale_addr;
        begin
            final_tokens = ctx - (table_count - 1) * 128;
            for (i = 0; i < table_count; i = i + 1) begin
                timeout = 0;
                while (!page_valid && !error_valid && timeout < 100) begin
                    @(negedge clk);
                    timeout = timeout + 1;
                end
                if (!page_valid && !error_valid)
                    $fatal(1, "page descriptor timeout context=%0d page=%0d",
                           ctx, i);
                if (error_valid) begin
                    $display("FAIL valid table produced error=%02x", error_code);
                    errors = errors + 1;
                end
                wanted_tokens = (i == table_count - 1) ? final_tokens : 128;
                wanted_scale_bytes = (wanted_tokens * SCALE_BITS + 7) / 8;
                if (page_index != i || page_count != table_count ||
                    token_base != i*128 || token_count != wanted_tokens ||
                    expected_symbols != wanted_tokens*128 ||
                    data_addr != expected_data_base + table_words[i] ||
                    data_limit != expected_data_base +
                        ((i+1 < table_count) ? table_words[i+1] : test_stream_bytes) ||
                    page_window_bytes !=
                        ((i+1 < table_count) ? table_words[i+1] : test_stream_bytes) -
                        table_words[i] ||
                    scale_addr != expected_scale_base + i*SCALE_STRIDE ||
                    scale_slice_bytes != wanted_scale_bytes ||
                    stream_is_v != expected_stream || task_tag != expected_tag) begin
                    $display("FAIL descriptor context=%0d page=%0d", ctx, i);
                    errors = errors + 1;
                end

                // Hold ready low and prove every externally visible field is stable.
                held_data_addr = data_addr;
                held_scale_addr = scale_addr;
                page_ready = 0;
                repeat (2) @(negedge clk);
                if (!page_valid || data_addr != held_data_addr ||
                    scale_addr != held_scale_addr || page_index != i ||
                    page_count != table_count || token_base != i*128 ||
                    token_count != wanted_tokens ||
                    expected_symbols != wanted_tokens*128 ||
                    data_limit != expected_data_base +
                        ((i+1 < table_count) ? table_words[i+1] : test_stream_bytes) ||
                    page_window_bytes !=
                        ((i+1 < table_count) ? table_words[i+1] : test_stream_bytes) -
                        table_words[i] ||
                    scale_slice_bytes != wanted_scale_bytes ||
                    stream_is_v != expected_stream || task_tag != expected_tag) begin
                    $display("FAIL descriptor changed under backpressure page=%0d", i);
                    errors = errors + 1;
                end
                page_ready = 1;
                @(negedge clk);
                page_ready = 0;
            end
            if (!done || busy || table_valid || page_valid) begin
                $display("FAIL completion context=%0d done=%0d busy=%0d table=%0d page=%0d",
                         ctx, done, busy, table_valid, page_valid);
                errors = errors + 1;
            end
        end
    endtask

    task run_valid_context_with_identity;
        input integer ctx;
        input [ADDR_WIDTH-1:0] data_base_value;
        input [ADDR_WIDTH-1:0] scale_base_value;
        input stream_value;
        input [63:0] tag_value;
        begin
            build_raw_k_table(ctx);
            issue_command(ctx, data_base_value, test_stream_bytes,
                          scale_base_value,
                          (ctx*SCALE_BITS + 7)/8, table_crc(table_count),
                          stream_value, tag_value);

            // Command inputs are not live after the handshake.
            cmd_context_len = 13'd1;
            cmd_data_base = {ADDR_WIDTH{1'b1}};
            cmd_data_stream_bytes = 1;
            cmd_scale_base = {ADDR_WIDTH{1'b1}};
            cmd_scale_plane_bytes = 1;
            cmd_offset_crc32 = 0;
            cmd_stream_is_v = 1;
            cmd_task_tag = 0;

            send_valid_table(table_count);
            wait_for_table_or_error();
            if (!table_valid || error_valid) begin
                $display("FAIL valid context=%0d table=%0d error=%0d/%02x",
                         ctx, table_valid, error_valid, error_code);
                errors = errors + 1;
            end else begin
                check_and_consume_pages(ctx, data_base_value, scale_base_value,
                                        stream_value, tag_value);
            end
        end
    endtask

    task run_valid_context;
        input integer ctx;
        begin
            run_valid_context_with_identity(
                ctx, DATA_BASE, SCALE_BASE, 1'b0, TEST_TAG);
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);
            rst_n = 0;
            cmd_valid = 0;
            offset_valid = 0;
            offset_last = 0;
            page_ready = 0;
            abort = 0;
            repeat (2) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
        end
    endtask

    task expect_preflight_error;
        input [12:0] ctx;
        input [ADDR_WIDTH-1:0] data_base_value;
        input [31:0] stream_bytes_value;
        input [ADDR_WIDTH-1:0] scale_base_value;
        input [31:0] scale_bytes_value;
        input [7:0] wanted;
        integer handshakes_before;
        reg [63:0] fault_tag;
        begin
            fault_tag = TEST_TAG ^ 64'h0000_0000_55aa_00ff;
            handshakes_before = page_handshakes;
            issue_command(ctx, data_base_value, stream_bytes_value,
                          scale_base_value, scale_bytes_value,
                          32'h2144df1c, 1, fault_tag);
            expect_error(wanted, handshakes_before);
            if (task_tag != fault_tag || !stream_is_v) begin
                $display("FAIL preflight fault retained stale task identity");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        integer handshakes_before;
        integer timeout;
        reg [31:0] good_crc;

        repeat (4) @(negedge clk);
        rst_n = 1;

        table_words[0] = 0;
        if (table_crc(1) !== 32'h2144df1c) begin
            $display("FAIL one-entry CRC got=%08x", table_crc(1));
            errors = errors + 1;
        end
        table_words[0] = 0;
        table_words[1] = 32'h0000_1bd0;
        if (table_crc(2) !== 32'h53052a61) begin
            $display("FAIL checked-in K two-page CRC got=%08x", table_crc(2));
            errors = errors + 1;
        end
        table_words[1] = 32'h0000_22e0;
        if (table_crc(2) !== 32'h88940cdf) begin
            $display("FAIL checked-in V two-page CRC got=%08x", table_crc(2));
            errors = errors + 1;
        end

        run_valid_context(1);
        run_valid_context(7);
        run_valid_context(63);
        run_valid_context(64);
        run_valid_context(65);
        run_valid_context(127);
        run_valid_context(128);
        run_valid_context(129);
        run_valid_context(511);
        run_valid_context(512);
        run_valid_context(513);
        run_valid_context(1023);
        run_valid_context(1024);
        run_valid_context(1025);
        run_valid_context(4095);
        run_valid_context(4096);

        // A nonzero aligned first offset is legal in the executable contract.
        table_count = 1;
        table_words[0] = 16;
        test_stream_bytes = 100;
        issue_command(1, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (SCALE_BITS+7)/8, table_crc(1), 1, TEST_TAG);
        send_valid_table(1);
        wait_for_table_or_error();
        check_and_consume_pages(1, DATA_BASE, SCALE_BASE, 1, TEST_TAG);

        // The final representable exclusive limit is legal; one more byte
        // below is rejected by the following preflight test.
        table_count = 1;
        table_words[0] = 0;
        test_stream_bytes = 31;
        issue_command(1, TOP_WINDOW_BASE, test_stream_bytes, SCALE_BASE,
                      (SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_valid_table(1);
        wait_for_table_or_error();
        check_and_consume_pages(
            1, TOP_WINDOW_BASE, SCALE_BASE, 0, TEST_TAG);

        expect_preflight_error(0, DATA_BASE, 100, SCALE_BASE, 1, 8'h01);
        expect_preflight_error(4097, DATA_BASE, 100, SCALE_BASE,
                               (4097*SCALE_BITS+7)/8, 8'h01);
        expect_preflight_error(1, DATA_BASE+1, 100, SCALE_BASE,
                               (SCALE_BITS+7)/8, 8'h02);
        expect_preflight_error(1, DATA_BASE, 0, SCALE_BASE,
                               (SCALE_BITS+7)/8, 8'h02);
        // The frozen stream contract is byte-addressable. Bus-facing stages
        // may impose their own alignment rules, but the planner preserves an
        // unaligned scale-plane base.
        table_count = 1;
        table_words[0] = 0;
        test_stream_bytes = 100;
        issue_command(1, DATA_BASE, test_stream_bytes, SCALE_BASE+1,
                      (SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_valid_table(1);
        wait_for_table_or_error();
        check_and_consume_pages(
            1, DATA_BASE, SCALE_BASE+1, 0, TEST_TAG);
        expect_preflight_error(128, DATA_BASE, 8204, SCALE_BASE,
                               (128*SCALE_BITS+7)/8 + 1, 8'h02);
        expect_preflight_error(1, TOP_WINDOW_BASE, 32,
                               SCALE_BASE, (SCALE_BITS+7)/8, 8'h02);
        expect_preflight_error(128, DATA_BASE, 8204,
                               {ADDR_WIDTH{1'b1}} - 15,
                               (128*SCALE_BITS+7)/8, 8'h02);

        // CRC wins when a corrupted word is also structurally invalid.
        build_raw_k_table(129);
        good_crc = table_crc(2);
        table_words[1] = 8209;
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, good_crc, 1, FAULT_TAG);
        send_valid_table(2);
        expect_error(8'h04, handshakes_before);
        if (task_tag != FAULT_TAG || !stream_is_v) begin
            $display("FAIL table CRC fault retained stale task identity");
            errors = errors + 1;
        end
        repeat (3) begin
            @(negedge clk);
            if (!error_valid || error_code != 8'h04 ||
                task_tag != FAULT_TAG || !stream_is_v) begin
                $display("FAIL table CRC error was not sticky");
                errors = errors + 1;
            end
        end
        abort = 1;
        @(negedge clk);
        abort = 0;
        if (!error_valid || error_code != 8'h04 || task_tag != FAULT_TAG) begin
            $display("FAIL idle abort changed sticky table CRC error");
            errors = errors + 1;
        end

        // With the matching CRC, the same unaligned word is an offset fault.
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_valid_table(2);
        expect_error(8'h05, handshakes_before);

        table_words[0] = 0;
        table_words[1] = 0;
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_valid_table(2);
        expect_error(8'h05, handshakes_before);

        table_words[0] = 16;
        table_words[1] = 0;
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_valid_table(2);
        expect_error(8'h05, handshakes_before);

        table_words[0] = 0;
        table_words[1] = test_stream_bytes;
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_valid_table(2);
        expect_error(8'h05, handshakes_before);

        // Extra 16-byte-aligned zero padding is legal in the stream contract.
        // Header/payload validation, not the offset planner, checks its bytes.
        table_words[0] = 0;
        table_words[1] = 8224;
        test_stream_bytes = 8224 + 76;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_valid_table(2);
        wait_for_table_or_error();
        check_and_consume_pages(
            129, DATA_BASE, SCALE_BASE, 0, TEST_TAG);

        // A final window shorter than the fixed 12-byte header is invalid.
        table_count = 1;
        table_words[0] = 16;
        handshakes_before = page_handshakes;
        issue_command(1, DATA_BASE, 24, SCALE_BASE,
                      (SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_valid_table(1);
        expect_error(8'h05, handshakes_before);

        // Early and missing LAST are exact-count protocol faults.
        build_raw_k_table(129);
        handshakes_before = page_handshakes;
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_offset_word(table_words[0], 1, 0);
        expect_error(8'h03, handshakes_before);

        table_count = 1;
        table_words[0] = 0;
        handshakes_before = page_handshakes;
        issue_command(1, DATA_BASE, 76, SCALE_BASE,
                      (SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_offset_word(0, 0, 0);
        expect_error(8'h03, handshakes_before);

        // Reset during table load must erase the partial table and identity.
        build_raw_k_table(129);
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_offset_word(table_words[0], 0, 0);
        reset_dut();
        if (!cmd_ready || busy || table_valid || page_valid || done ||
            aborted || error_valid) begin
            $display("FAIL reset during table load left live state");
            errors = errors + 1;
        end
        run_valid_context_with_identity(
            1, DATA_BASE + 'h0010_0000, SCALE_BASE + 'h0010_0000,
            1'b1, FAULT_TAG);

        // Reset while a validated descriptor is backpressured must suppress
        // it immediately and permit a distinct clean restart.
        build_raw_k_table(128);
        issue_command(128, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (128*SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_valid_table(1);
        wait_for_table_or_error();
        timeout = 0;
        while (!page_valid && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!page_valid)
            $fatal(1, "stalled descriptor did not appear before reset");
        page_ready = 0;
        reset_dut();
        if (!cmd_ready || busy || table_valid || page_valid || done ||
            aborted || error_valid) begin
            $display("FAIL reset during stalled emit left live state");
            errors = errors + 1;
        end
        run_valid_context_with_identity(
            1, DATA_BASE + 'h0020_0000, SCALE_BASE + 'h0020_0000,
            1'b1, FAULT_TAG ^ 64'h55aa);

        // Abort while loading, then prove a clean short restart.
        build_raw_k_table(129);
        issue_command(129, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (129*SCALE_BITS+7)/8, table_crc(2), 0, TEST_TAG);
        send_offset_word(table_words[0], 0, 0);
        @(negedge clk);
        abort = 1;
        @(negedge clk);
        abort = 0;
        if (!aborted || busy || page_valid || table_valid) begin
            $display("FAIL load abort did not invalidate transaction");
            errors = errors + 1;
        end
        run_valid_context(1);

        // Abort and a presented table word on the same edge must not create
        // a ghost input handshake or later descriptor.
        build_raw_k_table(1);
        issue_command(1, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (SCALE_BITS+7)/8, table_crc(1), 0, FAULT_TAG);
        timeout = 0;
        while (!offset_ready && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!offset_ready)
            $fatal(1, "offset_ready timeout before coincident abort");
        offset_data = table_words[0];
        offset_last = 1;
        offset_valid = 1;
        abort = 1;
        @(negedge clk);
        offset_valid = 0;
        offset_last = 0;
        abort = 0;
        if (!aborted || busy || offset_ready || page_valid || table_valid) begin
            $display("FAIL coincident load abort accepted a ghost word");
            errors = errors + 1;
        end
        run_valid_context(1);

        // Abort a valid descriptor with ready high on the same edge.  The
        // combinational valid gate must prevent even that final handshake.
        build_raw_k_table(128);
        issue_command(128, DATA_BASE, test_stream_bytes, SCALE_BASE,
                      (128*SCALE_BITS+7)/8, table_crc(1), 0, TEST_TAG);
        send_valid_table(1);
        wait_for_table_or_error();
        timeout = 0;
        while (!page_valid && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!page_valid)
            $fatal(1, "page_valid timeout before coincident abort");
        handshakes_before = page_handshakes;
        page_ready = 1;
        abort = 1;
        @(negedge clk);
        abort = 0;
        page_ready = 0;
        if (!aborted || busy || page_valid || table_valid ||
            page_handshakes != handshakes_before) begin
            $display("FAIL emit abort exposed stale descriptor");
            errors = errors + 1;
        end
        run_valid_context(1);

        if (errors == 0) begin
            $display("TB PASS: page128 offset scheduler addr_width=%0d scale_bits=%0d",
                     ADDR_WIDTH, SCALE_BITS);
            $finish;
        end
        $fatal(1, "TB FAIL: page128 offset scheduler addr_width=%0d scale_bits=%0d errors=%0d",
               ADDR_WIDTH, SCALE_BITS, errors);
    end
endmodule

`default_nettype wire
