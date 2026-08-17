// tb_kv_v03_decoder_cluster_4x1.v -- four-page decoder concurrency test.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_decoder_cluster_4x1;
    reg clk = 0;
    reg rst_n = 0;
    reg [3:0] start = 0, integrity = 0, stream_is_v = 0, raw_mode = 0;
    reg [59:0] expected_symbols = 0;
    reg [3:0] in_valid = 0, in_last = 0, out_ready = 0;
    reg [127:0] in_data = 0;
    reg [15:0] in_keep = 0;

    wire [3:0] in_ready, out_valid, out_last, busy, done, error_valid;
    wire [19:0] out_symbol;
    wire [31:0] error_code;

    reg [7:0] payload0 [0:5119];
    reg [7:0] payload1 [0:5119];
    reg [7:0] payload2 [0:5119];
    reg [7:0] payload3 [0:5119];
    reg [7:0] golden0 [0:8191];
    reg [7:0] golden1 [0:8191];
    reg [7:0] golden2 [0:8191];
    reg [7:0] golden3 [0:8191];
    integer index [0:3];
    integer wanted [0:3];
    integer errors = 0, timeout = 0, lane, fill_index;
    integer ready_lane, monitor_lane;
    reg [3:0] done_seen = 0, error_seen = 0;
    reg [15:0] ready_lfsr = 16'h73a9;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_decoder_cluster_4x1 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .integrity_passed(integrity), .stream_is_v(stream_is_v),
        .raw_mode(raw_mode), .expected_symbols(expected_symbols),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .in_byte_valid(in_keep), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_symbol(out_symbol), .out_last(out_last), .busy(busy),
        .done(done), .error_valid(error_valid), .error_code(error_code)
    );

    always @(negedge clk) begin
        for (ready_lane = 0; ready_lane < 4; ready_lane = ready_lane + 1)
            out_ready[ready_lane] <=
                ready_lfsr[(ready_lane*3) +: 3] != 3'b000;
        ready_lfsr <= {ready_lfsr[14:0],
                       ready_lfsr[15] ^ ready_lfsr[13] ^
                       ready_lfsr[12] ^ ready_lfsr[10]};
    end

    function automatic signed [7:0] golden_value;
        input integer selected_lane;
        input integer selected_index;
        begin
            case (selected_lane)
                0: golden_value = golden0[selected_index];
                1: golden_value = golden1[selected_index];
                2: golden_value = golden2[selected_index];
                default: golden_value = golden3[selected_index];
            endcase
        end
    endfunction

    function automatic [7:0] payload_value;
        input integer selected_lane;
        input integer selected_index;
        begin
            case (selected_lane)
                0: payload_value = payload0[selected_index];
                1: payload_value = payload1[selected_index];
                2: payload_value = payload2[selected_index];
                default: payload_value = payload3[selected_index];
            endcase
        end
    endfunction

    always @(posedge clk) begin
        done_seen <= done_seen | done;
        error_seen <= error_seen | error_valid;
        for (monitor_lane = 0; monitor_lane < 4;
             monitor_lane = monitor_lane + 1) begin
            if (out_valid[monitor_lane] && out_ready[monitor_lane]) begin
                if (index[monitor_lane] >= wanted[monitor_lane] ||
                    $signed(out_symbol[(monitor_lane*5) +: 5]) !==
                    golden_value(monitor_lane, index[monitor_lane])) begin
                    if (errors < 20)
                        $display("FAIL cluster4 lane=%0d index=%0d got=%0d want=%0d",
                                 monitor_lane, index[monitor_lane],
                                 $signed(out_symbol[(monitor_lane*5) +: 5]),
                                 golden_value(monitor_lane,
                                              index[monitor_lane]));
                    errors = errors + 1;
                end
                index[monitor_lane] = index[monitor_lane] + 1;
                if (out_last[monitor_lane] !==
                    (index[monitor_lane] == wanted[monitor_lane])) begin
                    $display("FAIL cluster4 lane=%0d out_last at %0d/%0d",
                             monitor_lane, index[monitor_lane],
                             wanted[monitor_lane]);
                    errors = errors + 1;
                end
            end
        end
    end

    task automatic drive_lane;
        input integer selected_lane;
        input integer byte_length;
        integer offset, byte_no, word_bytes, ready_timeout;
        reg [31:0] next_word;
        begin
            offset = 0;
            while (offset < byte_length) begin
                word_bytes = byte_length - offset;
                if (word_bytes > 4)
                    word_bytes = 4;
                next_word = 0;
                for (byte_no = 0; byte_no < word_bytes; byte_no = byte_no + 1)
                    next_word[(byte_no*8) +: 8] =
                        payload_value(selected_lane, offset + byte_no);
                @(negedge clk);
                in_data[(selected_lane*32) +: 32] = next_word;
                in_keep[(selected_lane*4) +: 4] =
                    (4'b0001 << word_bytes) - 1'b1;
                in_last[selected_lane] =
                    (offset + word_bytes == byte_length);
                in_valid[selected_lane] = 1;
                @(posedge clk);
                ready_timeout = 0;
                while (!in_ready[selected_lane] && ready_timeout < 30000) begin
                    @(posedge clk);
                    ready_timeout = ready_timeout + 1;
                end
                if (!in_ready[selected_lane])
                    $fatal(1, "cluster4 lane %0d input-ready timeout",
                           selected_lane);
                @(negedge clk);
                in_valid[selected_lane] = 0;
                in_last[selected_lane] = 0;
                in_keep[(selected_lane*4) +: 4] = 0;
                offset = offset + word_bytes;
            end
        end
    endtask

    task launch_all;
        input [3:0] launch_integrity;
        input [3:0] launch_stream_is_v;
        input [3:0] launch_raw;
        begin
            done_seen = 0;
            error_seen = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                index[lane] = 0;
            @(negedge clk);
            integrity = launch_integrity;
            stream_is_v = launch_stream_is_v;
            raw_mode = launch_raw;
            start = 4'b1111;
            @(negedge clk);
            start = 0;
        end
    endtask

    task wait_all;
        input [3:0] wanted_done;
        input [3:0] wanted_error;
        begin
            timeout = 0;
            while ((done_seen != wanted_done || error_seen != wanted_error) &&
                   timeout < 30000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (done_seen != wanted_done || error_seen != wanted_error) begin
                $display("FAIL cluster4 timeout done=%b/%b error=%b/%b code=%08x",
                         done_seen, wanted_done, error_seen, wanted_error,
                         error_code);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/codec/decoder_goldens";
        for (lane = 0; lane < 4; lane = lane + 1) begin
            index[lane] = 0;
            wanted[lane] = 8192;
            expected_symbols[(lane*15) +: 15] = 8192;
        end
        repeat (3) @(negedge clk);
        rst_n = 1;

        // Exercise both codebooks and both raw widths concurrently.  Every
        // lane owns a complete page, so no prefix stream is split.
        $readmemh({golden_root, "/k_compressed_page64_payload_bytes.hex"},
                  payload0, 0, 3553);
        $readmemh({golden_root, "/k_compressed_page64_expected_codes.hex"},
                  golden0, 0, 8191);
        $readmemh({golden_root, "/v_compressed_page64_payload_bytes.hex"},
                  payload1, 0, 4456);
        $readmemh({golden_root, "/v_compressed_page64_expected_codes.hex"},
                  golden1, 0, 8191);
        $readmemh({golden_root, "/k_raw_page64_payload_bytes.hex"},
                  payload2, 0, 4095);
        $readmemh({golden_root, "/k_raw_page64_expected_codes.hex"},
                  golden2, 0, 8191);
        $readmemh({golden_root, "/v_raw_page64_payload_bytes.hex"},
                  payload3, 0, 5119);
        $readmemh({golden_root, "/v_raw_page64_expected_codes.hex"},
                  golden3, 0, 8191);
        launch_all(4'b1111, 4'b1010, 4'b1100);
        fork
            drive_lane(0, 3554);
            drive_lane(1, 4457);
            drive_lane(2, 4096);
            drive_lane(3, 5120);
        join
        wait_all(4'b1111, 4'b0000);
        for (lane = 0; lane < 4; lane = lane + 1)
            if (index[lane] != wanted[lane]) begin
                $display("FAIL cluster4 lane=%0d count=%0d/%0d",
                         lane, index[lane], wanted[lane]);
                errors = errors + 1;
            end
        if (errors == 0)
            $display("PASS cluster4 concurrent compressed/raw K/V pages");

        // One rejected page must not disturb three valid short page tasks.
        for (fill_index = 0; fill_index < 80; fill_index = fill_index + 1) begin
            payload1[fill_index] = 0;
            payload2[fill_index] = 0;
            payload3[fill_index] = 0;
        end
        for (fill_index = 0; fill_index < 128; fill_index = fill_index + 1) begin
            golden1[fill_index] = 0;
            golden2[fill_index] = 0;
            golden3[fill_index] = 0;
        end
        wanted[0] = 0;
        wanted[1] = 128;
        wanted[2] = 128;
        wanted[3] = 128;
        for (lane = 0; lane < 4; lane = lane + 1)
            expected_symbols[(lane*15) +: 15] = 128;
        launch_all(4'b1110, 4'b0100, 4'b1111);
        fork
            drive_lane(1, 64);
            drive_lane(2, 80);
            drive_lane(3, 64);
        join
        wait_all(4'b1110, 4'b0001);
        if (index[0] != 0 || index[1] != 128 || index[2] != 128 ||
            index[3] != 128 || error_code[7:0] != 8'h05) begin
            $display("FAIL cluster4 isolation counts=%0d,%0d,%0d,%0d code=%08x",
                     index[0], index[1], index[2], index[3], error_code);
            errors = errors + 1;
        end else begin
            $display("PASS cluster4 independent integrity isolation");
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 decoder cluster 4x1");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 decoder cluster4 errors=%0d", errors);
    end
endmodule

`default_nettype wire
