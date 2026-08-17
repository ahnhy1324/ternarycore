// tb_kv_v03_crc32.v -- CRC-32/ISO-HDLC check and protocol regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_crc32;
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg in_valid = 0;
    reg [31:0] in_data = 0;
    reg [3:0] in_byte_valid = 0;
    reg in_last = 0;
    wire in_ready;
    wire crc_valid;
    wire [31:0] crc;
    wire protocol_error;
    integer errors = 0;

    always #5 clk = ~clk;

    kv_v03_crc32 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_byte_valid(in_byte_valid), .in_last(in_last),
        .crc_valid(crc_valid), .crc(crc), .protocol_error(protocol_error)
    );

    task idle_cycle;
        begin
            @(negedge clk);
            start = 0;
            in_valid = 0;
            in_last = 0;
            in_byte_valid = 0;
            in_data = 0;
        end
    endtask

    task begin_crc;
        begin
            @(negedge clk);
            start = 1;
            in_valid = 0;
            in_last = 0;
            in_byte_valid = 0;
            @(negedge clk);
            start = 0;
        end
    endtask

    task send_word;
        input [31:0] data;
        input [3:0] keep;
        input last;
        begin
            @(negedge clk);
            if (!in_ready) begin
                $display("FAIL CRC input unexpectedly not ready");
                errors = errors + 1;
            end
            in_valid = 1;
            in_data = data;
            in_byte_valid = keep;
            in_last = last;
            @(negedge clk);
            in_valid = 0;
            in_last = 0;
            in_byte_valid = 0;
        end
    endtask

    task expect_crc;
        input [31:0] expected;
        begin
            if (!crc_valid || crc !== expected) begin
                $display("FAIL CRC got valid=%0d value=%08x want=%08x",
                         crc_valid, crc, expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        begin_crc();
        send_word(32'h34333231, 4'b1111, 0);
        send_word(32'h38373635, 4'b1111, 0);
        send_word(32'h00000039, 4'b0001, 1);
        expect_crc(32'hcbf43926);

        // Abort an active interval and restart with data on the start cycle.
        begin_crc();
        @(negedge clk);
        start = 1;
        in_valid = 1;
        in_data = 32'h34333231;
        in_byte_valid = 4'b1111;
        in_last = 0;
        @(negedge clk);
        start = 0;
        in_valid = 0;
        in_byte_valid = 0;
        send_word(32'h38373635, 4'b1111, 0);
        send_word(32'h00000039, 4'b0001, 1);
        expect_crc(32'hcbf43926);

        begin_crc();
        send_word(32'h04030201, 4'b0101, 1);
        if (!protocol_error || crc_valid) begin
            $display("FAIL invalid byte mask was not rejected");
            errors = errors + 1;
        end

        @(negedge clk);
        in_valid = 1;
        in_data = 32'h000000aa;
        in_byte_valid = 4'b0001;
        in_last = 1;
        @(negedge clk);
        in_valid = 0;
        in_last = 0;
        in_byte_valid = 0;
        if (!protocol_error || crc_valid) begin
            $display("FAIL inactive CRC input was not rejected");
            errors = errors + 1;
        end

        idle_cycle();
        if (errors == 0) begin
            $display("TB PASS: v0.3 CRC32 check/restart/protocol");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 CRC32 errors=%0d", errors);
    end
endmodule

`default_nettype wire
