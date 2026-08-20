`timescale 1ps/1ps
`default_nettype none

// Simulation-only behavioral substitutes for the two 7-series primitives
// used by zybo_pl_clock.v. They also make the selected MMCM ratios part of the
// Icarus gate instead of silently accepting any legal primitive parameters.
module MMCME2_BASE #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter real CLKFBOUT_MULT_F = 5.000,
    parameter real CLKFBOUT_PHASE = 0.000,
    parameter real CLKIN1_PERIOD = 0.000,
    parameter real CLKOUT0_DIVIDE_F = 1.000,
    parameter real CLKOUT0_DUTY_CYCLE = 0.500,
    parameter real CLKOUT0_PHASE = 0.000,
    parameter integer DIVCLK_DIVIDE = 1,
    parameter real REF_JITTER1 = 0.010,
    parameter STARTUP_WAIT = "FALSE"
) (
    output wire CLKFBOUT,
    output wire CLKFBOUTB,
    output reg  CLKOUT0,
    output wire CLKOUT0B,
    output wire CLKOUT1,
    output wire CLKOUT1B,
    output wire CLKOUT2,
    output wire CLKOUT2B,
    output wire CLKOUT3,
    output wire CLKOUT3B,
    output wire CLKOUT4,
    output wire CLKOUT5,
    output wire CLKOUT6,
    output reg  LOCKED,
    input  wire CLKFBIN,
    input  wire CLKIN1,
    input  wire PWRDWN,
    input  wire RST
);
    integer half_period_ps;

    assign CLKFBOUT  = CLKIN1;
    assign CLKFBOUTB = ~CLKIN1;
    assign CLKOUT0B  = ~CLKOUT0;
    assign CLKOUT1   = 1'b0;
    assign CLKOUT1B  = 1'b1;
    assign CLKOUT2   = 1'b0;
    assign CLKOUT2B  = 1'b1;
    assign CLKOUT3   = 1'b0;
    assign CLKOUT3B  = 1'b1;
    assign CLKOUT4   = 1'b0;
    assign CLKOUT5   = 1'b0;
    assign CLKOUT6   = 1'b0;

    initial begin
        CLKOUT0 = 1'b0;
        LOCKED = 1'b0;
        if (DIVCLK_DIVIDE != 1 || CLKIN1_PERIOD != 10.000)
            $fatal(1, "unexpected MMCM input/divider configuration");
        if (CLKFBOUT_MULT_F == 9.000 && CLKOUT0_DIVIDE_F == 12.000)
            half_period_ps = 6667;
        else if (CLKFBOUT_MULT_F == 8.125 && CLKOUT0_DIVIDE_F == 10.000)
            half_period_ps = 6154;
        else
            $fatal(1, "unexpected MMCM ratio: multiply=%0f divide=%0f",
                   CLKFBOUT_MULT_F, CLKOUT0_DIVIDE_F);
    end

    always begin
        #(half_period_ps);
        if (RST || PWRDWN)
            CLKOUT0 = 1'b0;
        else
            CLKOUT0 = ~CLKOUT0;
    end

    always @(posedge CLKIN1 or posedge RST or posedge PWRDWN) begin
        if (RST || PWRDWN)
            LOCKED <= 1'b0;
        else
            LOCKED <= 1'b1;
    end

    wire unused_feedback = CLKFBIN;
endmodule

module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

`default_nettype wire
