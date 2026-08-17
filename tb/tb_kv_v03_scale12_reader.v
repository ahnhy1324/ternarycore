// tb_kv_v03_scale12_reader.v -- scale-plane boundaries/backpressure/faults.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_scale12_reader;
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg [8:0] expected_scales = 0;
    reg in_valid = 0;
    wire in_ready;
    reg [31:0] in_data = 0;
    reg [3:0] in_byte_valid = 0;
    reg in_last = 0;
    wire out_valid;
    reg out_ready = 0;
    wire [11:0] out_scale;
    wire busy, done, error_valid;
    wire [7:0] error_code;

    reg [7:0] byte_mem [0:255];
    reg [11:0] expected_mem [0:128];
    integer errors = 0;
    integer expected_index = 0;
    integer active_expected = 0;
    integer i, j, bit_position, total_bytes, word_offset, bytes_this_word;
    integer timeout, ready_timeout;
    reg monitor_enable = 0;
    reg backpressure_enable = 0;
    reg [15:0] lfsr = 16'h5a3c;

    always #5 clk = ~clk;

    kv_v03_scale12_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .expected_scales(expected_scales), .in_valid(in_valid),
        .in_ready(in_ready), .in_data(in_data),
        .in_byte_valid(in_byte_valid), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready), .out_scale(out_scale),
        .busy(busy), .done(done), .error_valid(error_valid),
        .error_code(error_code)
    );

    always @(negedge clk) begin
        if (backpressure_enable) begin
            out_ready <= lfsr[2:0] != 3'b000;
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end else begin
            out_ready <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (monitor_enable && out_valid && out_ready) begin
            if (expected_index >= active_expected) begin
                $display("FAIL unexpected extra scale %03x", out_scale);
                errors = errors + 1;
            end else if (out_scale !== expected_mem[expected_index]) begin
                $display("FAIL scale %0d got=%03x want=%03x",
                         expected_index, out_scale, expected_mem[expected_index]);
                errors = errors + 1;
            end
            expected_index = expected_index + 1;
        end
    end

    task build_payload;
        input integer count;
        begin
            for (i = 0; i < 256; i = i + 1)
                byte_mem[i] = 0;
            for (i = 0; i < count; i = i + 1) begin
                expected_mem[i] = (i * 37 + 5) & 12'hfff;
                for (j = 0; j < 12; j = j + 1) begin
                    bit_position = i * 12 + j;
                    if (expected_mem[i][j])
                        byte_mem[bit_position / 8][bit_position % 8] = 1'b1;
                end
            end
            total_bytes = (count * 12 + 7) / 8;
        end
    endtask

    task begin_case;
        input integer count;
        input integer use_backpressure;
        begin
            build_payload(count);
            expected_index = 0;
            active_expected = count;
            monitor_enable = 1;
            backpressure_enable = use_backpressure;
            @(negedge clk);
            expected_scales = count;
            start = 1;
            @(negedge clk);
            start = 0;
        end
    endtask

    task drive_built_payload;
        begin
            word_offset = 0;
            while (word_offset < total_bytes) begin
                ready_timeout = 0;
                while (!in_ready && ready_timeout < 1000) begin
                    @(negedge clk);
                    ready_timeout = ready_timeout + 1;
                end
                if (!in_ready)
                    $fatal(1, "scale reader input-ready timeout");
                bytes_this_word = total_bytes - word_offset;
                if (bytes_this_word > 4)
                    bytes_this_word = 4;
                @(negedge clk);
                in_data = 0;
                for (j = 0; j < bytes_this_word; j = j + 1)
                    in_data[(j*8) +: 8] = byte_mem[word_offset+j];
                case (bytes_this_word)
                    1: in_byte_valid = 4'b0001;
                    2: in_byte_valid = 4'b0011;
                    3: in_byte_valid = 4'b0111;
                    default: in_byte_valid = 4'b1111;
                endcase
                in_last = (word_offset + bytes_this_word == total_bytes);
                in_valid = 1;
                @(negedge clk);
                in_valid = 0;
                in_last = 0;
                in_byte_valid = 0;
                word_offset = word_offset + bytes_this_word;
            end
        end
    endtask

    task wait_success;
        input integer count;
        begin
            timeout = 0;
            while (!done && !error_valid && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error_valid || expected_index != count) begin
                $display("FAIL scale case n=%0d done=%0d err=%0d code=%02x outputs=%0d",
                         count, done, error_valid, error_code, expected_index);
                errors = errors + 1;
            end else begin
                $display("PASS scale12 length %0d", count);
            end
            monitor_enable = 0;
            backpressure_enable = 0;
            @(negedge clk);
        end
    endtask

    task run_case;
        input integer count;
        input integer use_backpressure;
        begin
            begin_case(count, use_backpressure);
            drive_built_payload();
            wait_success(count);
        end
    endtask

    task expect_error;
        input [7:0] wanted;
        begin
            timeout = 0;
            while (!error_valid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!error_valid || error_code != wanted || done) begin
                $display("FAIL expected scale error %02x got valid=%0d code=%02x done=%0d",
                         wanted, error_valid, error_code, done);
                errors = errors + 1;
            end
            monitor_enable = 0;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        run_case(1, 1);
        run_case(7, 1);
        run_case(63, 1);
        run_case(64, 1);
        run_case(65, 1);
        run_case(127, 1);
        run_case(128, 1);
        // Explicit short-after-long stale-state regression.
        run_case(1, 0);

        // Underflow: declare seven scales, provide only six.
        begin_case(7, 0);
        build_payload(6);
        drive_built_payload();
        expect_error(8'h01);

        // Overflow: one scale requires two bytes; a third full byte is illegal.
        begin_case(1, 0);
        @(negedge clk);
        in_data = 32'h00000005;
        in_byte_valid = 4'b0111;
        in_last = 1;
        in_valid = 1;
        @(negedge clk);
        in_valid = 0;
        in_last = 0;
        in_byte_valid = 0;
        expect_error(8'h02);

        // Non-zero high padding nibble after one scale is illegal.
        begin_case(1, 0);
        @(negedge clk);
        in_data = 32'h0000f005;
        in_byte_valid = 4'b0011;
        in_last = 1;
        in_valid = 1;
        @(negedge clk);
        in_valid = 0;
        in_last = 0;
        in_byte_valid = 0;
        expect_error(8'h02);

        // Non-contiguous byte mask is a protocol error.
        begin_case(1, 0);
        @(negedge clk);
        in_data = 32'h00000005;
        in_byte_valid = 4'b0101;
        in_last = 1;
        in_valid = 1;
        @(negedge clk);
        in_valid = 0;
        in_last = 0;
        in_byte_valid = 0;
        expect_error(8'h03);

        // Invalid page token count is rejected at start.
        @(negedge clk);
        expected_scales = 9'd129;
        start = 1;
        @(negedge clk);
        start = 0;
        expect_error(8'h03);

        if (errors == 0) begin
            $display("TB PASS: v0.3 scale12 boundaries/backpressure/faults");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 scale12 errors=%0d", errors);
    end
endmodule

`default_nettype wire
