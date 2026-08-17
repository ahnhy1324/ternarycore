// tb_kv_v03_decoder_cluster_2x2.v -- concurrent K/V page-task regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_decoder_cluster_2x2;
    reg clk = 0;
    reg rst_n = 0;
    reg [1:0] start = 0, integrity = 0, stream_is_v = 0, raw_mode = 0;
    reg [14:0] expected0 = 0, expected1 = 0;
    reg in_valid0 = 0, in_valid1 = 0;
    reg [31:0] in_data0 = 0, in_data1 = 0;
    reg [3:0] in_keep0 = 0, in_keep1 = 0;
    reg in_last0 = 0, in_last1 = 0;
    reg out_ready0 = 0, out_ready1 = 0;

    wire [1:0] in_ready, out_valid, out_last, busy, done, error_valid;
    wire [3:0] out_count;
    wire [9:0] out_symbol0, out_symbol1;
    wire [15:0] error_code;
    wire signed [4:0] symbol00 = out_symbol0[4:0];
    wire signed [4:0] symbol01 = out_symbol1[4:0];
    wire signed [4:0] symbol10 = out_symbol0[9:5];
    wire signed [4:0] symbol11 = out_symbol1[9:5];

    reg [7:0] payload0 [0:5119];
    reg [7:0] payload1 [0:5119];
    reg [7:0] golden0 [0:8191];
    reg [7:0] golden1 [0:8191];
    integer index0 = 0, index1 = 0, wanted0 = 0, wanted1 = 0;
    integer errors = 0, timeout = 0, fill_index;
    reg [1:0] done_seen = 0, error_seen = 0;
    reg [15:0] ready_lfsr = 16'h4d2b;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_decoder_cluster_2x2 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .integrity_passed(integrity), .stream_is_v(stream_is_v),
        .raw_mode(raw_mode), .expected_symbols({expected1, expected0}),
        .in_valid({in_valid1, in_valid0}), .in_ready(in_ready),
        .in_data({in_data1, in_data0}),
        .in_byte_valid({in_keep1, in_keep0}),
        .in_last({in_last1, in_last0}), .out_valid(out_valid),
        .out_ready({out_ready1, out_ready0}), .out_count(out_count),
        .out_symbol0(out_symbol0), .out_symbol1(out_symbol1),
        .out_last(out_last), .busy(busy), .done(done),
        .error_valid(error_valid), .error_code(error_code)
    );

    always @(negedge clk) begin
        out_ready0 <= ready_lfsr[2:0] != 3'b000;
        out_ready1 <= ready_lfsr[5:3] != 3'b000;
        ready_lfsr <= {ready_lfsr[14:0],
                       ready_lfsr[15] ^ ready_lfsr[13] ^
                       ready_lfsr[12] ^ ready_lfsr[10]};
    end

    task check0;
        input signed [4:0] value;
        begin
            if (index0 >= wanted0 ||
                value !== $signed(golden0[index0])) begin
                if (errors < 20)
                    $display("FAIL cluster lane0 symbol %0d got=%0d want=%0d",
                             index0, value, $signed(golden0[index0]));
                errors = errors + 1;
            end
            index0 = index0 + 1;
        end
    endtask

    task check1;
        input signed [4:0] value;
        begin
            if (index1 >= wanted1 ||
                value !== $signed(golden1[index1])) begin
                if (errors < 20)
                    $display("FAIL cluster lane1 symbol %0d got=%0d want=%0d",
                             index1, value, $signed(golden1[index1]));
                errors = errors + 1;
            end
            index1 = index1 + 1;
        end
    endtask

    always @(posedge clk) begin
        done_seen <= done_seen | done;
        error_seen <= error_seen | error_valid;
        if (out_valid[0] && out_ready0) begin
            check0(symbol00);
            if (out_count[1:0] == 2)
                check0(symbol01);
            if (out_last[0] !== (index0 == wanted0)) begin
                $display("FAIL cluster lane0 out_last at %0d/%0d",
                         index0, wanted0);
                errors = errors + 1;
            end
        end
        if (out_valid[1] && out_ready1) begin
            check1(symbol10);
            if (out_count[3:2] == 2)
                check1(symbol11);
            if (out_last[1] !== (index1 == wanted1)) begin
                $display("FAIL cluster lane1 out_last at %0d/%0d",
                         index1, wanted1);
                errors = errors + 1;
            end
        end
    end

    task drive0;
        input integer byte_length;
        integer offset, byte_no, word_bytes;
        begin
            offset = 0;
            while (offset < byte_length) begin
                word_bytes = byte_length - offset;
                if (word_bytes > 4)
                    word_bytes = 4;
                @(negedge clk);
                in_data0 = 0;
                for (byte_no = 0; byte_no < word_bytes; byte_no = byte_no + 1)
                    in_data0[(byte_no*8) +: 8] = payload0[offset+byte_no];
                in_keep0 = (4'b0001 << word_bytes) - 1'b1;
                in_last0 = (offset + word_bytes == byte_length);
                in_valid0 = 1;
                @(posedge clk);
                while (!in_ready[0])
                    @(posedge clk);
                @(negedge clk);
                in_valid0 = 0;
                in_last0 = 0;
                in_keep0 = 0;
                offset = offset + word_bytes;
            end
        end
    endtask

    task drive1;
        input integer byte_length;
        integer offset, byte_no, word_bytes;
        begin
            offset = 0;
            while (offset < byte_length) begin
                word_bytes = byte_length - offset;
                if (word_bytes > 4)
                    word_bytes = 4;
                @(negedge clk);
                in_data1 = 0;
                for (byte_no = 0; byte_no < word_bytes; byte_no = byte_no + 1)
                    in_data1[(byte_no*8) +: 8] = payload1[offset+byte_no];
                in_keep1 = (4'b0001 << word_bytes) - 1'b1;
                in_last1 = (offset + word_bytes == byte_length);
                in_valid1 = 1;
                @(posedge clk);
                while (!in_ready[1])
                    @(posedge clk);
                @(negedge clk);
                in_valid1 = 0;
                in_last1 = 0;
                in_keep1 = 0;
                offset = offset + word_bytes;
            end
        end
    endtask

    task launch_pair;
        input [1:0] pair_integrity;
        input [1:0] pair_stream_is_v;
        input [1:0] pair_raw;
        begin
            index0 = 0;
            index1 = 0;
            done_seen = 0;
            error_seen = 0;
            @(negedge clk);
            integrity = pair_integrity;
            stream_is_v = pair_stream_is_v;
            raw_mode = pair_raw;
            start = 2'b11;
            @(negedge clk);
            start = 0;
        end
    endtask

    task wait_pair;
        input [1:0] wanted_done;
        input [1:0] wanted_error;
        begin
            timeout = 0;
            while ((done_seen != wanted_done || error_seen != wanted_error) &&
                   timeout < 30000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (done_seen != wanted_done || error_seen != wanted_error) begin
                $display("FAIL cluster timeout done=%b/%b error=%b/%b code=%04x",
                         done_seen, wanted_done, error_seen, wanted_error,
                         error_code);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/codec/decoder_goldens";
        repeat (3) @(negedge clk);
        rst_n = 1;

        // Baseline 2x2: one complete K page and one complete V page.
        $readmemh({golden_root, "/k_compressed_page64_payload_bytes.hex"},
                  payload0, 0, 3553);
        $readmemh({golden_root, "/k_compressed_page64_expected_codes.hex"},
                  golden0, 0, 8191);
        $readmemh({golden_root, "/v_compressed_page64_payload_bytes.hex"},
                  payload1, 0, 4456);
        $readmemh({golden_root, "/v_compressed_page64_expected_codes.hex"},
                  golden1, 0, 8191);
        wanted0 = 8192;
        wanted1 = 8192;
        expected0 = wanted0;
        expected1 = wanted1;
        launch_pair(2'b11, 2'b10, 2'b00);
        fork
            drive0(3554);
            drive1(4457);
        join
        wait_pair(2'b11, 2'b00);
        if (index0 != wanted0 || index1 != wanted1) begin
            $display("FAIL cluster compressed counts %0d/%0d %0d/%0d",
                     index0, wanted0, index1, wanted1);
            errors = errors + 1;
        end else begin
            $display("PASS cluster concurrent compressed K/V page64");
        end

        // Swap task types at runtime and verify both raw widths concurrently.
        $readmemh({golden_root, "/v_raw_page64_payload_bytes.hex"},
                  payload0, 0, 5119);
        $readmemh({golden_root, "/v_raw_page64_expected_codes.hex"},
                  golden0, 0, 8191);
        $readmemh({golden_root, "/k_raw_page64_payload_bytes.hex"},
                  payload1, 0, 4095);
        $readmemh({golden_root, "/k_raw_page64_expected_codes.hex"},
                  golden1, 0, 8191);
        launch_pair(2'b11, 2'b01, 2'b11);
        fork
            drive0(5120);
            drive1(4096);
        join
        wait_pair(2'b11, 2'b00);
        if (index0 != wanted0 || index1 != wanted1) begin
            $display("FAIL cluster raw counts %0d/%0d %0d/%0d",
                     index0, wanted0, index1, wanted1);
            errors = errors + 1;
        end else begin
            $display("PASS cluster runtime-swapped raw V/K page64");
        end

        // Integrity failure in lane 0 must not prevent lane 1 completion.
        for (fill_index = 0; fill_index < 64; fill_index = fill_index + 1)
            payload1[fill_index] = 0;
        for (fill_index = 0; fill_index < 128; fill_index = fill_index + 1)
            golden1[fill_index] = 0;
        wanted0 = 0;
        wanted1 = 128;
        expected0 = 128;
        expected1 = 128;
        launch_pair(2'b10, 2'b00, 2'b11);
        drive1(64);
        wait_pair(2'b10, 2'b01);
        if (index0 != 0 || index1 != 128 || error_code[7:0] != 8'h05) begin
            $display("FAIL cluster fault isolation counts=%0d/%0d code=%04x",
                     index0, index1, error_code);
            errors = errors + 1;
        end else begin
            $display("PASS cluster independent integrity fault isolation");
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 decoder cluster 2x2");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 decoder cluster errors=%0d", errors);
    end
endmodule

`default_nettype wire
