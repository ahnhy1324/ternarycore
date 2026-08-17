// tb_kv_v03_reciprocal.v -- bit-exact normalized reciprocal regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_reciprocal;
    reg clk = 0, rst_n = 0, start = 0;
    reg [27:0] denominator = 0;
    wire busy, done, error_valid;
    wire [12:0] reciprocal_code;
    wire [4:0] reciprocal_exponent;
    wire [7:0] error_code;
    reg [45:0] cases [0:127];
    integer case_count = 0, case_index, timeout, errors = 0;
    string golden_root;

    always #5 clk = ~clk;

    kv_v03_reciprocal dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .denominator(denominator), .busy(busy), .done(done),
        .reciprocal_code(reciprocal_code),
        .reciprocal_exponent(reciprocal_exponent),
        .error_valid(error_valid), .error_code(error_code)
    );

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/rtl_goldens/softmax";
        if (!$value$plusargs("CASE_COUNT=%d", case_count))
            case_count = 87;
        $readmemh({golden_root, "/reciprocal_cases_u46.hex"},
                  cases, 0, case_count-1);
        repeat (3) @(negedge clk);
        rst_n = 1;

        for (case_index = 0; case_index < case_count;
             case_index = case_index + 1) begin
            @(negedge clk);
            denominator = cases[case_index][45:18];
            start = 1;
            @(negedge clk);
            start = 0;
            timeout = 0;
            while (!done && !error_valid && timeout < 60) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error_valid ||
                reciprocal_code !== cases[case_index][12:0] ||
                reciprocal_exponent !== cases[case_index][17:13]) begin
                $display("FAIL reciprocal D=%0d got=%0d,e%0d want=%0d,e%0d",
                         denominator, reciprocal_code, reciprocal_exponent,
                         cases[case_index][12:0], cases[case_index][17:13]);
                errors = errors + 1;
            end
        end

        @(negedge clk);
        denominator = 0;
        start = 1;
        @(negedge clk);
        start = 0;
        if (!error_valid || error_code != 8'h01) begin
            $display("FAIL reciprocal zero denominator");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 reciprocal %0d bit-exact cases",
                     case_count);
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 reciprocal errors=%0d", errors);
    end
endmodule

`default_nettype wire
