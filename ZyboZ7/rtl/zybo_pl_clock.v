`timescale 1ns/1ps
`default_nettype none

// SPDX-License-Identifier: CERN-OHL-S-2.0

// The PS7 FCLK is an internal fabric clock, so this module deliberately does
// not instantiate an input buffer and does not add a primary create_clock
// constraint. Vivado derives the MMCM output clock from the PS-generated
// clk_fpga_0 clock.
module zybo_pl_clock_core #(
    parameter real CLKFBOUT_MULT_F    = 9.000,
    parameter real CLKOUT0_DIVIDE_F   = 12.000
) (
    input  wire clk_in,
    input  wire resetn,
    output wire clk_out,
    output wire locked
);
    wire mmcm_reset;
    wire clk_feedback_unbuffered;
    wire clk_feedback;
    wire clk_out_unbuffered;
    wire clkfboutb_unused;
    wire clkout0b_unused;
    wire clkout1_unused;
    wire clkout1b_unused;
    wire clkout2_unused;
    wire clkout2b_unused;
    wire clkout3_unused;
    wire clkout3b_unused;
    wire clkout4_unused;
    wire clkout5_unused;
    wire clkout6_unused;

    assign mmcm_reset = ~resetn;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(CLKFBOUT_MULT_F),
        .CLKFBOUT_PHASE(0.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(CLKOUT0_DIVIDE_F),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE(0.000),
        .DIVCLK_DIVIDE(1),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) mmcm_i (
        .CLKFBOUT(clk_feedback_unbuffered),
        .CLKFBOUTB(clkfboutb_unused),
        .CLKOUT0(clk_out_unbuffered),
        .CLKOUT0B(clkout0b_unused),
        .CLKOUT1(clkout1_unused),
        .CLKOUT1B(clkout1b_unused),
        .CLKOUT2(clkout2_unused),
        .CLKOUT2B(clkout2b_unused),
        .CLKOUT3(clkout3_unused),
        .CLKOUT3B(clkout3b_unused),
        .CLKOUT4(clkout4_unused),
        .CLKOUT5(clkout5_unused),
        .CLKOUT6(clkout6_unused),
        .LOCKED(locked),
        .CLKFBIN(clk_feedback),
        .CLKIN1(clk_in),
        .PWRDWN(1'b0),
        .RST(mmcm_reset)
    );

    BUFG feedback_bufg_i (
        .I(clk_feedback_unbuffered),
        .O(clk_feedback)
    );

    BUFG output_bufg_i (
        .I(clk_out_unbuffered),
        .O(clk_out)
    );
endmodule

// resetn ultimately drives the MMCM's asynchronous RST input. Do not declare
// it as ASSOCIATED_RESET on clk_in: that metadata falsely requests a
// synchronous relationship and causes Vivado BD 41-1348.
module zybo_pl_clock_75 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_in, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.000" *)
    input  wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input  wire resetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_out, FREQ_HZ 75000000, FREQ_TOLERANCE_HZ 0, PHASE 0.000" *)
    output wire clk_out,
    output wire locked
);
    zybo_pl_clock_core #(
        .CLKFBOUT_MULT_F(9.000),
        .CLKOUT0_DIVIDE_F(12.000)
    ) clock_core_i (
        .clk_in(clk_in),
        .resetn(resetn),
        .clk_out(clk_out),
        .locked(locked)
    );
endmodule

module zybo_pl_clock_81p25 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_in CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_in, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.000" *)
    input  wire clk_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 resetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *)
    input  wire resetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_out CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_out, FREQ_HZ 81250000, FREQ_TOLERANCE_HZ 0, PHASE 0.000" *)
    output wire clk_out,
    output wire locked
);
    zybo_pl_clock_core #(
        .CLKFBOUT_MULT_F(8.125),
        .CLKOUT0_DIVIDE_F(10.000)
    ) clock_core_i (
        .clk_in(clk_in),
        .resetn(resetn),
        .clk_out(clk_out),
        .locked(locked)
    );
endmodule

`default_nettype wire
