// tb_qk_dot.v -- four P=16 slices make one HEAD_DIM=64 dot product.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_qk_dot;
    localparam LANES = 16, QW = 8, KW = 20, AW = 32;
    reg clk = 0, rst_n = 0, in_valid = 0;
    reg vector_start = 0, vector_last = 0;
    reg [(LANES*QW)-1:0] q_lanes;
    reg [(LANES*KW)-1:0] k_lanes;
    wire out_valid;
    wire signed [AW-1:0] result;
    integer slice, lane, q, k, expected = 0, errors = 0;
    always #5 clk = ~clk;

    qk_dot #(.LANES(LANES), .Q_WIDTH(QW), .K_WIDTH(KW), .ACC_WIDTH(AW)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .vector_start(vector_start), .vector_last(vector_last),
        .q_lanes(q_lanes), .k_lanes(k_lanes),
        .out_valid(out_valid), .result(result)
    );

    initial begin
        q_lanes = 0; k_lanes = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (slice = 0; slice < 4; slice = slice + 1) begin
            @(negedge clk);
            q_lanes = 0; k_lanes = 0;
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                q = ((slice*LANES + lane) % 9) - 4;
                k = (((slice*LANES + lane) * 5) % 16) - 8;
                q_lanes[(lane*QW) +: QW] = q;
                k_lanes[(lane*KW) +: KW] = k * 256;
                expected = expected + q * k * 256;
            end
            in_valid = 1;
            vector_start = (slice == 0);
            vector_last  = (slice == 3);
        end
        @(negedge clk);
        in_valid = 0; vector_start = 0; vector_last = 0;
        if (!out_valid) begin
            $display("FAIL: result valid missing");
            errors = errors + 1;
        end else if ($signed(result) != expected) begin
            $display("FAIL: dot got %0d want %0d", $signed(result), expected);
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("TB PASS: QK dot = %0d", expected);
            $finish;
        end else begin
            $fatal(1, "TB FAIL: qk_dot");
        end
    end
endmodule

`default_nettype wire
