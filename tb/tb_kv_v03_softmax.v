// tb_kv_v03_softmax.v -- adversarial and real-capture bit-exact regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_softmax;
    reg clk = 0, rst_n = 0, start = 0;
    reg [1:0] score_row = 0;
    reg [12:0] context_len = 0;
    wire score_rd_en;
    wire [1:0] score_rd_row;
    wire [11:0] score_rd_addr;
    wire store_rd_valid;
    wire signed [15:0] store_rd_data;
    reg block_read_response = 0;
    wire score_rd_valid = store_rd_valid && !block_read_response;
    reg exp_ready = 0;
    wire exp_valid, exp_last, busy, done, error_valid;
    wire [11:0] exp_index;
    wire [15:0] exp_code;
    wire signed [15:0] maximum_score;
    wire [27:0] denominator;
    wire [12:0] reciprocal_code, underflow_count;
    wire [4:0] reciprocal_exponent;
    wire [7:0] error_code;

    reg wr_en = 0;
    reg [1:0] wr_row = 0;
    reg [11:0] wr_addr = 0;
    reg signed [15:0] wr_data = 0;
    reg [15:0] scores [0:4095];
    reg [15:0] expected_exp [0:4095];
    reg [74:0] expected_meta [0:0];
    integer output_index = 0, expected_length = 0;
    integer write_index, timeout, errors = 0;
    reg [15:0] ready_lfsr = 16'h721d;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_score_store store (
        .clk(clk), .wr_en(wr_en), .wr_row(wr_row), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(score_rd_en), .rd_row(score_rd_row),
        .rd_addr(score_rd_addr), .rd_valid(store_rd_valid),
        .rd_data(store_rd_data)
    );

    kv_v03_softmax #(.READ_TIMEOUT_CYCLES(16)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .score_row(score_row),
        .context_len(context_len), .score_rd_en(score_rd_en),
        .score_rd_row(score_rd_row), .score_rd_addr(score_rd_addr),
        .score_rd_valid(score_rd_valid), .score_rd_data(store_rd_data),
        .exp_valid(exp_valid), .exp_ready(exp_ready),
        .exp_index(exp_index), .exp_code(exp_code), .exp_last(exp_last),
        .busy(busy), .done(done), .maximum_score(maximum_score),
        .denominator(denominator), .reciprocal_code(reciprocal_code),
        .reciprocal_exponent(reciprocal_exponent),
        .underflow_count(underflow_count), .error_valid(error_valid),
        .error_code(error_code)
    );

    always @(negedge clk) begin
        exp_ready <= ready_lfsr[2:0] != 3'b000;
        ready_lfsr <= {ready_lfsr[14:0],
                       ready_lfsr[15] ^ ready_lfsr[13] ^
                       ready_lfsr[12] ^ ready_lfsr[10]};
    end

    always @(posedge clk) begin
        if (exp_valid && exp_ready) begin
            if (output_index >= expected_length ||
                exp_index !== output_index[11:0] ||
                exp_code !== expected_exp[output_index]) begin
                if (errors < 20)
                    $display("FAIL softmax exp %0d index=%0d code=%04x want=%04x",
                             output_index, exp_index, exp_code,
                             expected_exp[output_index]);
                errors = errors + 1;
            end
            if (exp_last !== (output_index == expected_length-1)) begin
                $display("FAIL softmax exp_last at %0d/%0d",
                         output_index, expected_length);
                errors = errors + 1;
            end
            output_index = output_index + 1;
        end
    end

    task run_case;
        input string case_name;
        input integer length;
        input [1:0] row;
        begin
            $readmemh({golden_root, "/", case_name, "/scores_s16.hex"},
                      scores, 0, length-1);
            $readmemh({golden_root, "/", case_name, "/exp_u16.hex"},
                      expected_exp, 0, length-1);
            $readmemh({golden_root, "/", case_name,
                       "/expected_meta_u75.hex"}, expected_meta, 0, 0);
            for (write_index = 0; write_index < length;
                 write_index = write_index + 1) begin
                @(negedge clk);
                wr_en = 1;
                wr_row = row;
                wr_addr = write_index[11:0];
                wr_data = scores[write_index];
            end
            @(negedge clk);
            wr_en = 0;
            output_index = 0;
            expected_length = length;
            score_row = row;
            context_len = length;
            start = 1;
            @(negedge clk);
            start = 0;
            timeout = 0;
            while (!done && !error_valid && timeout < length*8 + 200) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error_valid || output_index != length) begin
                $display("FAIL softmax case %s done=%0d error=%0d code=%02x output=%0d/%0d",
                         case_name, done, error_valid, error_code,
                         output_index, length);
                errors = errors + 1;
            end else if (maximum_score !== $signed(expected_meta[0][74:59]) ||
                         underflow_count !== expected_meta[0][58:46] ||
                         reciprocal_exponent !== expected_meta[0][45:41] ||
                         reciprocal_code !== expected_meta[0][40:28] ||
                         denominator !== expected_meta[0][27:0]) begin
                $display("FAIL softmax meta %s max=%0d/%0d under=%0d/%0d D=%0d/%0d recip=%0d,e%0d/%0d,e%0d",
                         case_name, maximum_score,
                         $signed(expected_meta[0][74:59]), underflow_count,
                         expected_meta[0][58:46], denominator,
                         expected_meta[0][27:0], reciprocal_code,
                         reciprocal_exponent, expected_meta[0][40:28],
                         expected_meta[0][45:41]);
                errors = errors + 1;
            end else begin
                $display("PASS softmax %s length=%0d cycles=%0d",
                         case_name, length, timeout);
            end
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/rtl_goldens/softmax";
        repeat (4) @(negedge clk);
        rst_n = 1;

        // Long first, then short, exercises stale counters and denominator.
        run_case("uniform_4096", 4096, 0);
        run_case("single_sink_65", 65, 1);
        run_case("lut_boundary_129", 129, 2);
        run_case("real_engineering_c128_l00_h0", 128, 3);

        context_len = 0;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        if (!error_valid || error_code != 8'h01) begin
            $display("FAIL softmax invalid context error=%0d code=%02x",
                     error_valid, error_code);
            errors = errors + 1;
        end else begin
            $display("PASS softmax invalid context rejected");
        end

        // Suppress a legal synchronous response: timeout must be an error.
        context_len = 1;
        score_row = 0;
        block_read_response = 1;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        timeout = 0;
        while (!error_valid && timeout < 40) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        block_read_response = 0;
        if (!error_valid || error_code != 8'h03) begin
            $display("FAIL softmax read timeout error=%0d code=%02x",
                     error_valid, error_code);
            errors = errors + 1;
        end else begin
            $display("PASS softmax read timeout is fatal");
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 softmax adversarial/real bit-exact");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 softmax errors=%0d", errors);
    end
endmodule

`default_nettype wire
