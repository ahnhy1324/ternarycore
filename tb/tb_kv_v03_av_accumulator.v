// tb_kv_v03_av_accumulator.v -- real/adversarial integer AV regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_av_accumulator;
`ifdef MULT_STYLE_VAL
    localparam MULT_STYLE = `MULT_STYLE_VAL;
`else
    localparam MULT_STYLE = 2;
`endif
`ifdef SCALE_WIDTH_VAL
    localparam SCALE_WIDTH = `SCALE_WIDTH_VAL;
`else
    localparam SCALE_WIDTH = 12;
`endif
    reg clk = 0, rst_n = 0, start = 0, in_valid = 0;
    reg [12:0] context_len = 0;
    reg [1:0] in_head = 0;
    reg [2:0] in_group = 0;
    reg [15:0] in_exp_code = 0;
    reg [SCALE_WIDTH-1:0] in_v_scale = 0;
    reg [79:0] in_v_codes = 0;
    wire in_ready, out_valid, out_last, busy, done, error_valid;
    reg out_ready = 0;
    wire [1:0] out_head;
    wire [2:0] out_group;
    wire [767:0] out_numerators;
    wire [7:0] error_code;

    reg [4:0] v_codes [0:16383];
    reg [SCALE_WIDTH-1:0] v_scales [0:127];
    reg [15:0] exp_codes [0:511];
    reg [47:0] expected [0:511];
    integer current_context = 0, output_beats = 0;
    integer token, head, group_index, lane, timeout, ready_timeout, errors = 0;
    reg [15:0] ready_lfsr = 16'h3a7d;
    reg [15:0] input_lfsr = 16'h6c51;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_av_accumulator #(
        .MULT_STYLE(MULT_STYLE), .SCALE_WIDTH(SCALE_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .context_len(context_len), .in_valid(in_valid),
        .in_ready(in_ready), .in_head(in_head), .in_group(in_group),
        .in_exp_code(in_exp_code), .in_v_scale(in_v_scale),
        .in_v_codes(in_v_codes), .out_valid(out_valid),
        .out_ready(out_ready), .out_head(out_head), .out_group(out_group),
        .out_numerators(out_numerators), .out_last(out_last),
        .busy(busy), .done(done), .error_valid(error_valid),
        .error_code(error_code)
    );

    always @(negedge clk) begin
        out_ready <= ready_lfsr[2:0] != 3'b000;
        ready_lfsr <= {ready_lfsr[14:0],
                       ready_lfsr[15] ^ ready_lfsr[13] ^
                       ready_lfsr[12] ^ ready_lfsr[10]};
    end

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            if ({out_head, out_group} !== output_beats[4:0]) begin
                $display("FAIL AV output address head=%0d group=%0d beat=%0d",
                         out_head, out_group, output_beats);
                errors = errors + 1;
            end
            for (lane = 0; lane < 16; lane = lane + 1) begin
                if ($signed(out_numerators[(lane*48) +: 48]) !==
                    $signed(expected[out_head*128 + out_group*16 + lane])) begin
                    if (errors < 20)
                        $display("FAIL AV h%0d d%0d got=%0d want=%0d",
                                 out_head, out_group*16+lane,
                                 $signed(out_numerators[(lane*48) +: 48]),
                                 $signed(expected[out_head*128 +
                                                  out_group*16 + lane]));
                    errors = errors + 1;
                end
            end
            if (out_last !== (output_beats == 31)) begin
                $display("FAIL AV out_last beat=%0d", output_beats);
                errors = errors + 1;
            end
            output_beats = output_beats + 1;
        end
    end

    task drive_case;
        input integer length;
        begin
            for (token = 0; token < length; token = token + 1) begin
                for (head = 0; head < 4; head = head + 1) begin
                    for (group_index = 0; group_index < 8;
                         group_index = group_index + 1) begin
                        if (input_lfsr[2:0] == 0) begin
                            @(negedge clk);
                            in_valid = 0;
                            input_lfsr = {input_lfsr[14:0],
                                input_lfsr[15] ^ input_lfsr[13] ^
                                input_lfsr[12] ^ input_lfsr[10]};
                        end
                        @(negedge clk);
                        in_head = head;
                        in_group = group_index;
                        in_exp_code = exp_codes[token*4 + head];
                        in_v_scale = v_scales[token];
                        in_v_codes = 0;
                        for (lane = 0; lane < 16; lane = lane + 1)
                            in_v_codes[(lane*5) +: 5] =
                                v_codes[token*128 + group_index*16 + lane];
                        in_valid = 1;
                        @(posedge clk);
                        ready_timeout = 0;
                        while (!in_ready && ready_timeout < 1000) begin
                            @(posedge clk);
                            ready_timeout = ready_timeout + 1;
                        end
                        if (!in_ready)
                            $fatal(1, "AV input-ready timeout");
                        @(negedge clk);
                        in_valid = 0;
                        input_lfsr = {input_lfsr[14:0],
                            input_lfsr[15] ^ input_lfsr[13] ^
                            input_lfsr[12] ^ input_lfsr[10]};
                    end
                end
            end
        end
    endtask

    task run_case;
        input string case_name;
        input integer length;
        begin
            $readmemh({golden_root, "/", case_name, "/v_codes_s5.hex"},
                      v_codes, 0, length*128-1);
            $readmemh({golden_root, "/", case_name, "/v_scales_u12.hex"},
                      v_scales, 0, length-1);
            $readmemh({golden_root, "/", case_name, "/exp_h4_u16.hex"},
                      exp_codes, 0, length*4-1);
            $readmemh({golden_root, "/", case_name,
                       "/expected_numerators_s48.hex"},
                      expected, 0, 511);
            current_context = length;
            output_beats = 0;
            context_len = length;
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            drive_case(length);
            timeout = 0;
            while (!done && !error_valid && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error_valid || output_beats != 32) begin
                $display("FAIL AV %s style%0d done=%0d err=%0d code=%02x beats=%0d",
                         case_name, MULT_STYLE, done, error_valid,
                         error_code, output_beats);
                errors = errors + 1;
            end else begin
                $display("PASS AV %s style%0d context=%0d",
                         case_name, MULT_STYLE, length);
            end
            repeat (2) @(negedge clk);
        end
    endtask

    task run_scale16_exact_case;
        begin
            // Maximum legal UQ1.15 exponent, UQ5.11 scale, V5 magnitude,
            // and context.  The exact positive numerator is just below the
            // signed-48 limit; alternating lanes cover both signs.
            for (head = 0; head < 4; head = head + 1)
                for (group_index = 0; group_index < 8;
                     group_index = group_index + 1)
                    for (lane = 0; lane < 16; lane = lane + 1)
                        expected[head*128 + group_index*16 + lane] =
                            lane[0] ? 48'h8800_7800_0000 :
                                      48'h77ff_8800_0000;

            current_context = 4096;
            output_beats = 0;
            context_len = 13'd4096;
            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            in_valid = 1;
            for (token = 0; token < 4096; token = token + 1) begin
                for (head = 0; head < 4; head = head + 1) begin
                    for (group_index = 0; group_index < 8;
                         group_index = group_index + 1) begin
                        in_head = head;
                        in_group = group_index;
                        in_exp_code = 16'h8000;
                        in_v_scale = {SCALE_WIDTH{1'b1}};
                        in_v_codes = 0;
                        for (lane = 0; lane < 16; lane = lane + 1)
                            in_v_codes[(lane*5) +: 5] =
                                lane[0] ? -5'sd15 : 5'sd15;
                        @(posedge clk);
                        if (!in_ready)
                            $fatal(1, "AV UQ5.11 input-ready failure");
                        @(negedge clk);
                    end
                end
            end
            in_valid = 0;
            timeout = 0;
            while (!done && !error_valid && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error_valid || output_beats != 32) begin
                $display("FAIL AV UQ5.11 exact style%0d done=%0d err=%0d code=%02x beats=%0d",
                         MULT_STYLE, done, error_valid, error_code,
                         output_beats);
                errors = errors + 1;
            end else begin
                $display("PASS AV UQ5.11 signed-48 exact style%0d context=4096",
                         MULT_STYLE);
            end
            repeat (2) @(negedge clk);
        end
    endtask

    task expect_error;
        input [7:0] wanted;
        begin
            timeout = 0;
            while (!error_valid && timeout < 20) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!error_valid || error_code != wanted || done) begin
                $display("FAIL AV expected error=%02x got=%02x",
                         wanted, error_code);
                errors = errors + 1;
            end
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/rtl_goldens/av";
        repeat (4) @(negedge clk);
        rst_n = 1;

        run_case("real_c128_l00_kvh0", 128);
        run_case("adversarial_c7", 7);
        if (SCALE_WIDTH == 16)
            run_scale16_exact_case();

        // A start while pipeline data is live must abort.  Merely pausing the
        // valid registers would apply the pending accumulator update twice.
        context_len = 1;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        in_head = 0;
        in_group = 0;
        in_exp_code = 1;
        in_v_scale = 1;
        in_v_codes = 0;
        in_valid = 1;
        @(posedge clk);
        ready_timeout = 0;
        while (!in_ready && ready_timeout < 1000) begin
            @(posedge clk);
            ready_timeout = ready_timeout + 1;
        end
        if (!in_ready)
            $fatal(1, "AV busy-start setup input-ready timeout");
        @(negedge clk);
        in_valid = 0;
        start = 1;
        @(negedge clk);
        start = 0;
        expect_error(8'h02);
        if (busy) begin
            $display("FAIL AV busy-start abort left engine active");
            errors = errors + 1;
        end else begin
            $display("PASS AV busy-start abort clears live pipeline");
        end

        // A full case after the abort detects stale stage-valid or bank state.
        run_case("adversarial_c7", 7);

        // Schedule mismatch is rejected before any accumulator commit.
        context_len = 1;
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        in_head = 0;
        in_group = 1;
        in_exp_code = 1;
        in_v_scale = 1;
        in_v_codes = 0;
        in_valid = 1;
        expect_error(8'h03);

        // Reserved V5 -16 and zero scale have distinct faults.
        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        in_head = 0;
        in_group = 0;
        in_v_scale = 1;
        in_v_codes = 0;
        in_v_codes[4:0] = 5'b10000;
        in_valid = 1;
        expect_error(8'h04);

        @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        in_head = 0;
        in_group = 0;
        in_v_scale = 0;
        in_v_codes = 0;
        in_valid = 1;
        expect_error(8'h05);

        if (errors == 0) begin
            $display("TB PASS: v0.3 AV P16 accumulator scale%0d style%0d",
                     SCALE_WIDTH, MULT_STYLE);
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 AV errors=%0d", errors);
    end
endmodule

`default_nettype wire
