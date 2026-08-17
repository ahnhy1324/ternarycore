// tb_kv_v03_decoders.v -- page64/page128 bit-exact PACKED5 decoder regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_decoders;
    reg clk = 0;
    reg rst_n = 0;

    reg k_start = 0, k_integrity = 0, k_raw = 0, k_in_valid = 0;
    reg [14:0] k_expected = 0;
    reg [31:0] k_in_data = 0;
    reg [3:0] k_in_keep = 0;
    reg k_in_last = 0, k_out_ready = 0;
    wire k_in_ready, k_out_valid, k_out_last, k_busy, k_done, k_error;
    wire [1:0] k_out_count;
    wire signed [4:0] k_symbol0, k_symbol1;
    wire [7:0] k_error_code;

    reg v_start = 0, v_integrity = 0, v_raw = 0, v_in_valid = 0;
    reg [14:0] v_expected = 0;
    reg [31:0] v_in_data = 0;
    reg [3:0] v_in_keep = 0;
    reg v_in_last = 0, v_out_ready = 0;
    wire v_in_ready, v_out_valid, v_out_last, v_busy, v_done, v_error;
    wire [1:0] v_out_count;
    wire signed [4:0] v_symbol0, v_symbol1;
    wire [7:0] v_error_code;

    reg [7:0] payload_mem [0:10251];
    reg [7:0] expected_mem [0:16383];
    reg [9:0] lookup_expected [0:255];
    integer errors = 0;
    integer active_stream = 0;
    integer output_index = 0;
    integer expected_count = 0;
    integer offset, byte_index, bytes_this_word, timeout, ready_timeout, i;
    reg [15:0] ready_lfsr = 16'h63ad;
    reg [15:0] input_lfsr = 16'h275b;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_k4_decoder k_dut (
        .clk(clk), .rst_n(rst_n), .start(k_start),
        .integrity_passed(k_integrity), .raw_mode(k_raw),
        .expected_symbols(k_expected), .in_valid(k_in_valid),
        .in_ready(k_in_ready), .in_data(k_in_data),
        .in_byte_valid(k_in_keep), .in_last(k_in_last),
        .out_valid(k_out_valid), .out_ready(k_out_ready),
        .out_count(k_out_count), .out_symbol0(k_symbol0),
        .out_symbol1(k_symbol1), .out_last(k_out_last),
        .busy(k_busy), .done(k_done), .error_valid(k_error),
        .error_code(k_error_code)
    );

    kv_v03_v5_decoder v_dut (
        .clk(clk), .rst_n(rst_n), .start(v_start),
        .integrity_passed(v_integrity), .raw_mode(v_raw),
        .expected_symbols(v_expected), .in_valid(v_in_valid),
        .in_ready(v_in_ready), .in_data(v_in_data),
        .in_byte_valid(v_in_keep), .in_last(v_in_last),
        .out_valid(v_out_valid), .out_ready(v_out_ready),
        .out_count(v_out_count), .out_symbol0(v_symbol0),
        .out_symbol1(v_symbol1), .out_last(v_out_last),
        .busy(v_busy), .done(v_done), .error_valid(v_error),
        .error_code(v_error_code)
    );

    always @(negedge clk) begin
        k_out_ready <= ready_lfsr[2:0] != 3'b000;
        v_out_ready <= ready_lfsr[2:0] != 3'b000;
        ready_lfsr <= {ready_lfsr[14:0],
                       ready_lfsr[15] ^ ready_lfsr[13] ^
                       ready_lfsr[12] ^ ready_lfsr[10]};
    end

    task check_symbol;
        input signed [4:0] symbol;
        begin
            if (output_index >= expected_count) begin
                if (errors < 20)
                    $display("FAIL decoder emitted extra symbol %0d", symbol);
                errors = errors + 1;
            end else if (symbol !== $signed(expected_mem[output_index])) begin
                if (errors < 20)
                    $display("FAIL decoder symbol %0d got=%0d want=%0d",
                             output_index, symbol,
                             $signed(expected_mem[output_index]));
                errors = errors + 1;
            end
            output_index = output_index + 1;
        end
    endtask

    always @(posedge clk) begin
        if (active_stream == 1 && k_out_valid && k_out_ready) begin
            check_symbol(k_symbol0);
            if (k_out_count == 2)
                check_symbol(k_symbol1);
            if (k_out_last !== (output_index == expected_count)) begin
                $display("FAIL K out_last at output %0d/%0d",
                         output_index, expected_count);
                errors = errors + 1;
            end
        end
        if (active_stream == 2 && v_out_valid && v_out_ready) begin
            check_symbol(v_symbol0);
            if (v_out_count == 2)
                check_symbol(v_symbol1);
            if (v_out_last !== (output_index == expected_count)) begin
                $display("FAIL V out_last at output %0d/%0d",
                         output_index, expected_count);
                errors = errors + 1;
            end
        end
    end

    task load_case;
        input string payload_name;
        input string expected_name;
        input integer payload_bytes;
        input integer symbol_count;
        begin
            $readmemh({golden_root, "/", payload_name}, payload_mem,
                      0, payload_bytes-1);
            $readmemh({golden_root, "/", expected_name}, expected_mem,
                      0, symbol_count-1);
        end
    endtask

    task drive_k_payload;
        input integer payload_bytes;
        begin
            offset = 0;
            while (offset < payload_bytes) begin
                if (input_lfsr[2:0] == 0) begin
                    @(negedge clk);
                    k_in_valid = 0;
                    input_lfsr = {input_lfsr[14:0], input_lfsr[15] ^
                                  input_lfsr[13] ^ input_lfsr[12] ^
                                  input_lfsr[10]};
                end
                bytes_this_word = payload_bytes - offset;
                if (bytes_this_word > 4)
                    bytes_this_word = 4;
                @(negedge clk);
                k_in_data = 0;
                for (byte_index = 0; byte_index < bytes_this_word;
                     byte_index = byte_index + 1)
                    k_in_data[(byte_index*8) +: 8] =
                        payload_mem[offset+byte_index];
                case (bytes_this_word)
                    1: k_in_keep = 4'b0001;
                    2: k_in_keep = 4'b0011;
                    3: k_in_keep = 4'b0111;
                    default: k_in_keep = 4'b1111;
                endcase
                k_in_last = (offset + bytes_this_word == payload_bytes);
                k_in_valid = 1;
                @(posedge clk);
                ready_timeout = 0;
                while (!k_in_ready && ready_timeout < 30000) begin
                    @(posedge clk);
                    ready_timeout = ready_timeout + 1;
                end
                if (!k_in_ready)
                    $fatal(1, "K decoder input-ready timeout");
                @(negedge clk);
                k_in_valid = 0;
                k_in_last = 0;
                k_in_keep = 0;
                offset = offset + bytes_this_word;
                input_lfsr = {input_lfsr[14:0], input_lfsr[15] ^
                              input_lfsr[13] ^ input_lfsr[12] ^
                              input_lfsr[10]};
            end
        end
    endtask

    task drive_v_payload;
        input integer payload_bytes;
        begin
            offset = 0;
            while (offset < payload_bytes) begin
                if (input_lfsr[2:0] == 0) begin
                    @(negedge clk);
                    v_in_valid = 0;
                    input_lfsr = {input_lfsr[14:0], input_lfsr[15] ^
                                  input_lfsr[13] ^ input_lfsr[12] ^
                                  input_lfsr[10]};
                end
                bytes_this_word = payload_bytes - offset;
                if (bytes_this_word > 4)
                    bytes_this_word = 4;
                @(negedge clk);
                v_in_data = 0;
                for (byte_index = 0; byte_index < bytes_this_word;
                     byte_index = byte_index + 1)
                    v_in_data[(byte_index*8) +: 8] =
                        payload_mem[offset+byte_index];
                case (bytes_this_word)
                    1: v_in_keep = 4'b0001;
                    2: v_in_keep = 4'b0011;
                    3: v_in_keep = 4'b0111;
                    default: v_in_keep = 4'b1111;
                endcase
                v_in_last = (offset + bytes_this_word == payload_bytes);
                v_in_valid = 1;
                @(posedge clk);
                ready_timeout = 0;
                while (!v_in_ready && ready_timeout < 30000) begin
                    @(posedge clk);
                    ready_timeout = ready_timeout + 1;
                end
                if (!v_in_ready)
                    $fatal(1, "V decoder input-ready timeout");
                @(negedge clk);
                v_in_valid = 0;
                v_in_last = 0;
                v_in_keep = 0;
                offset = offset + bytes_this_word;
                input_lfsr = {input_lfsr[14:0], input_lfsr[15] ^
                              input_lfsr[13] ^ input_lfsr[12] ^
                              input_lfsr[10]};
            end
        end
    endtask

    task run_k_case;
        input integer tokens;
        input integer payload_bytes;
        input integer raw;
        input string payload_name;
        input string expected_name;
        begin
            output_index = 0;
            expected_count = tokens * 128;
            load_case(payload_name, expected_name,
                      payload_bytes, expected_count);
            active_stream = 1;
            @(negedge clk);
            k_integrity = 1;
            k_raw = raw;
            k_expected = expected_count;
            k_start = 1;
            @(negedge clk);
            k_start = 0;
            drive_k_payload(payload_bytes);
            timeout = 0;
            while (!k_done && !k_error && timeout < 30000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!k_done || k_error || output_index != expected_count) begin
                $display("FAIL K case %s done=%0d err=%0d code=%02x output=%0d/%0d",
                         payload_name, k_done, k_error, k_error_code,
                         output_index, expected_count);
                errors = errors + 1;
            end else begin
                $display("PASS K decoder %s", payload_name);
            end
            active_stream = 0;
            @(negedge clk);
        end
    endtask

    task run_v_case;
        input integer tokens;
        input integer payload_bytes;
        input integer raw;
        input string payload_name;
        input string expected_name;
        begin
            output_index = 0;
            expected_count = tokens * 128;
            load_case(payload_name, expected_name,
                      payload_bytes, expected_count);
            active_stream = 2;
            @(negedge clk);
            v_integrity = 1;
            v_raw = raw;
            v_expected = expected_count;
            v_start = 1;
            @(negedge clk);
            v_start = 0;
            drive_v_payload(payload_bytes);
            timeout = 0;
            while (!v_done && !v_error && timeout < 30000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!v_done || v_error || output_index != expected_count) begin
                $display("FAIL V case %s done=%0d err=%0d code=%02x output=%0d/%0d",
                         payload_name, v_done, v_error, v_error_code,
                         output_index, expected_count);
                errors = errors + 1;
            end else begin
                $display("PASS V decoder %s", payload_name);
            end
            active_stream = 0;
            @(negedge clk);
        end
    endtask

    task expect_k_error;
        input [7:0] wanted;
        begin
            timeout = 0;
            while (!k_error && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!k_error || k_error_code != wanted || k_done) begin
                $display("FAIL expected K decoder error %02x got %02x",
                         wanted, k_error_code);
                errors = errors + 1;
            end
            active_stream = 0;
            @(negedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/codec/decoder_goldens";
        repeat (3) @(negedge clk);
        rst_n = 1;

        $readmemh({golden_root, "/k_lookahead_256x10.hex"}, lookup_expected);
        for (i = 0; i < 256; i = i + 1)
            if (k_dut.u_decoder.lookup[i] !== lookup_expected[i]) begin
                $display("FAIL K lookup %0d got=%03x want=%03x",
                         i, k_dut.u_decoder.lookup[i], lookup_expected[i]);
                errors = errors + 1;
            end
        $readmemh({golden_root, "/v_lookahead_256x10.hex"}, lookup_expected);
        for (i = 0; i < 256; i = i + 1)
            if (v_dut.u_decoder.lookup[i] !== lookup_expected[i]) begin
                $display("FAIL V lookup %0d got=%03x want=%03x",
                         i, v_dut.u_decoder.lookup[i], lookup_expected[i]);
                errors = errors + 1;
            end

        run_k_case(64, 3554, 0,
            "k_compressed_page64_payload_bytes.hex",
            "k_compressed_page64_expected_codes.hex");
        run_k_case(128, 7107, 0,
            "k_compressed_page128_payload_bytes.hex",
            "k_compressed_page128_expected_codes.hex");
        run_k_case(64, 4096, 1,
            "k_raw_page64_payload_bytes.hex",
            "k_raw_page64_expected_codes.hex");
        run_v_case(64, 4457, 0,
            "v_compressed_page64_payload_bytes.hex",
            "v_compressed_page64_expected_codes.hex");
        run_v_case(128, 8913, 0,
            "v_compressed_page128_payload_bytes.hex",
            "v_compressed_page128_expected_codes.hex");
        run_v_case(64, 5120, 1,
            "v_raw_page64_payload_bytes.hex",
            "v_raw_page64_expected_codes.hex");

        // CRC/integrity must gate every decoder start.
        @(negedge clk);
        k_integrity = 0;
        k_raw = 0;
        k_expected = 128;
        k_start = 1;
        @(negedge clk);
        k_start = 0;
        expect_k_error(8'h05);

        // Truncated compressed page.
        for (i = 0; i < 65; i = i + 1)
            payload_mem[i] = 0;
        active_stream = 0;
        @(negedge clk);
        k_integrity = 1;
        k_raw = 0;
        k_expected = 128;
        k_start = 1;
        @(negedge clk);
        k_start = 0;
        drive_k_payload(1);
        expect_k_error(8'h02);

        // Reserved raw K code -8 in the first nibble.
        for (i = 0; i < 65; i = i + 1)
            payload_mem[i] = 0;
        payload_mem[0] = 8'h08;
        @(negedge clk);
        k_integrity = 1;
        k_raw = 1;
        k_expected = 128;
        k_start = 1;
        @(negedge clk);
        k_start = 0;
        drive_k_payload(4);
        expect_k_error(8'h04);

        // Exact symbols followed by one extra raw byte is trailing data.
        for (i = 0; i < 65; i = i + 1)
            payload_mem[i] = 0;
        @(negedge clk);
        k_integrity = 1;
        k_raw = 1;
        k_expected = 128;
        k_start = 1;
        @(negedge clk);
        k_start = 0;
        drive_k_payload(65);
        expect_k_error(8'h03);

        if (errors == 0) begin
            $display("TB PASS: v0.3 K4/V5 page decoders and faults");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 decoder errors=%0d", errors);
    end
endmodule

`default_nettype wire
