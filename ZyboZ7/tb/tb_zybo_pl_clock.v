`timescale 1ps/1ps
`default_nettype none

module tb_zybo_pl_clock;
    reg clk_in = 1'b0;
    reg resetn = 1'b0;
    wire clk_75;
    wire locked_75;
    wire clk_81p25;
    wire locked_81p25;
    time edge_a;
    time edge_b;
    time period_ps;

    always #5000 clk_in = ~clk_in;

    zybo_pl_clock_75 dut_75 (
        .clk_in(clk_in),
        .resetn(resetn),
        .clk_out(clk_75),
        .locked(locked_75)
    );

    zybo_pl_clock_81p25 dut_81p25 (
        .clk_in(clk_in),
        .resetn(resetn),
        .clk_out(clk_81p25),
        .locked(locked_81p25)
    );

    initial begin
        #20000;
        if (locked_75 !== 1'b0 || locked_81p25 !== 1'b0)
            $fatal(1, "MMCM lock asserted while resetn was low");

        resetn = 1'b1;
        #20000;
        if (locked_75 !== 1'b1 || locked_81p25 !== 1'b1)
            $fatal(1, "MMCM lock did not assert after reset release");

        @(posedge clk_75);
        edge_a = $time;
        @(posedge clk_75);
        edge_b = $time;
        period_ps = edge_b - edge_a;
        if (period_ps < 13332 || period_ps > 13336)
            $fatal(1, "75 MHz wrapper period is %0d ps", period_ps);

        @(posedge clk_81p25);
        edge_a = $time;
        @(posedge clk_81p25);
        edge_b = $time;
        period_ps = edge_b - edge_a;
        if (period_ps < 12306 || period_ps > 12310)
            $fatal(1, "81.25 MHz wrapper period is %0d ps", period_ps);

        resetn = 1'b0;
        #1000;
        if (locked_75 !== 1'b0 || locked_81p25 !== 1'b0)
            $fatal(1, "MMCM lock did not clear on reset assertion");

        $display("ZYBO_PL_CLOCK_IVERILOG_PASS");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "clock test timed out");
    end
endmodule

`default_nettype wire
