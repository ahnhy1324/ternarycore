// qk_group_dot.v -- pipelined INT8 x signed low-bit QK reduction.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module qk_group_dot #(
    parameter integer GROUP_SIZE  = 32,
    parameter integer Q_WIDTH     = 8,
    parameter integer K_WIDTH     = 4,
    parameter integer SCALE_WIDTH = 16,
    parameter integer ACC_WIDTH   = 32,
    // 0: explicit signed-digit shift/add, 1: force DSP, 2: Vivado auto.
    parameter integer MULT_STYLE  = 2
) (
    input  wire clk,
    input  wire rst_n,
    input  wire in_valid,
    input  wire vector_start,
    input  wire vector_last,
    input  wire [(16*Q_WIDTH)-1:0] q_lanes,
    input  wire [(16*K_WIDTH)-1:0] k_lanes,
    input  wire [SCALE_WIDTH-1:0] group_scale,
    output reg  out_valid,
    output reg  signed [ACC_WIDTH-1:0] result,
    output reg  invalid_code
);
    // The reduction tree is structurally fixed at 16 lanes. Keeping this out
    // of the parameter list prevents synthesis from accepting a width that
    // the explicit 16-leaf tree cannot implement correctly.
    localparam integer LANES = 16;
    localparam integer PRODUCT_WIDTH = Q_WIDTH + K_WIDTH;
    localparam integer PAIR_WIDTH = PRODUCT_WIDTH + 1;
    localparam integer QUAD_WIDTH = PRODUCT_WIDTH + 2;
    localparam integer OCT_WIDTH = PRODUCT_WIDTH + 3;
    localparam integer SLICE_SUM_WIDTH = PRODUCT_WIDTH + 4;
    localparam integer GROUP_SUM_WIDTH = PRODUCT_WIDTH + $clog2(GROUP_SIZE);
    localparam integer SLICES_PER_GROUP = GROUP_SIZE / LANES;
    localparam integer SLICE_INDEX_WIDTH =
        (SLICES_PER_GROUP <= 1) ? 1 : $clog2(SLICES_PER_GROUP);
    localparam integer SCALED_PRODUCT_WIDTH = GROUP_SUM_WIDTH + SCALE_WIDTH;

    function signed [PRODUCT_WIDTH-1:0] shift_add_product;
        input signed [Q_WIDTH-1:0] q;
        input signed [K_WIDTH-1:0] k;
        reg signed [PRODUCT_WIDTH-1:0] q_ext;
        reg signed [PRODUCT_WIDTH-1:0] magnitude_product;
        reg [K_WIDTH-1:0] magnitude;
        integer bit_index;
        begin
            q_ext = {{K_WIDTH{q[Q_WIDTH-1]}}, q};
            magnitude = k[K_WIDTH-1] ? (~k + 1'b1) : k;
            magnitude_product = {PRODUCT_WIDTH{1'b0}};
            for (bit_index = 0; bit_index < K_WIDTH-1; bit_index = bit_index + 1)
                if (magnitude[bit_index])
                    magnitude_product = magnitude_product + (q_ext <<< bit_index);
            shift_add_product = k[K_WIDTH-1] ?
                -magnitude_product : magnitude_product;
        end
    endfunction

    wire signed [PRODUCT_WIDTH-1:0] product [0:15];
    wire invalid_lane [0:15];
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_product
            wire signed [Q_WIDTH-1:0] q =
                q_lanes[(lane*Q_WIDTH) +: Q_WIDTH];
            wire signed [K_WIDTH-1:0] k =
                k_lanes[(lane*K_WIDTH) +: K_WIDTH];
            if (MULT_STYLE == 0) begin : g_shift_add
                assign product[lane] = shift_add_product(q, k);
            end else if (MULT_STYLE == 1) begin : g_dsp
                (* use_dsp = "yes" *) wire signed [PRODUCT_WIDTH-1:0] dsp_product = q * k;
                assign product[lane] = dsp_product;
            end else begin : g_auto
                wire signed [PRODUCT_WIDTH-1:0] auto_product = q * k;
                assign product[lane] = auto_product;
            end
            assign invalid_lane[lane] =
                (k_lanes[(lane*K_WIDTH) +: K_WIDTH] == {1'b1, {(K_WIDTH-1){1'b0}}});
        end
    endgenerate

    wire signed [PAIR_WIDTH-1:0] pair_sum [0:7];
    wire signed [QUAD_WIDTH-1:0] quad_sum [0:3];
    wire signed [OCT_WIDTH-1:0] oct_sum [0:1];
    genvar node;
    generate
        for (node = 0; node < 8; node = node + 1) begin : g_pair
            assign pair_sum[node] = product[node*2] + product[node*2+1];
        end
        for (node = 0; node < 4; node = node + 1) begin : g_quad
            assign quad_sum[node] = pair_sum[node*2] + pair_sum[node*2+1];
        end
        for (node = 0; node < 2; node = node + 1) begin : g_oct
            assign oct_sum[node] = quad_sum[node*2] + quad_sum[node*2+1];
        end
    endgenerate
    wire signed [SLICE_SUM_WIDTH-1:0] slice_sum = oct_sum[0] + oct_sum[1];
    wire invalid_slice = invalid_lane[0] | invalid_lane[1] |
        invalid_lane[2] | invalid_lane[3] | invalid_lane[4] |
        invalid_lane[5] | invalid_lane[6] | invalid_lane[7] |
        invalid_lane[8] | invalid_lane[9] | invalid_lane[10] |
        invalid_lane[11] | invalid_lane[12] | invalid_lane[13] |
        invalid_lane[14] | invalid_lane[15];

    reg signed [SLICE_SUM_WIDTH-1:0] slice_sum_reg;
    reg slice_valid, slice_vector_start, slice_vector_last, slice_invalid;
    reg [SCALE_WIDTH-1:0] slice_scale;
    reg [SLICE_INDEX_WIDTH-1:0] slice_index;
    reg signed [GROUP_SUM_WIDTH-1:0] group_accumulator;
    reg signed [ACC_WIDTH-1:0] scaled_accumulator;
    reg signed [GROUP_SUM_WIDTH-1:0] pending_group_sum;
    reg [SCALE_WIDTH-1:0] pending_scale;
    reg pending_valid, pending_vector_last, pending_invalid;
    reg vector_invalid;

    wire group_end = (slice_index == SLICES_PER_GROUP-1);
    wire signed [GROUP_SUM_WIDTH-1:0] extended_slice_sum = slice_sum_reg;
    wire signed [GROUP_SUM_WIDTH-1:0] completed_group_sum =
        (slice_index == 0) ? extended_slice_sum :
        group_accumulator + extended_slice_sum;
    wire signed [SCALED_PRODUCT_WIDTH-1:0] scaled_product_full =
        pending_group_sum * $signed({1'b0, pending_scale});
    wire signed [ACC_WIDTH-1:0] scaled_product = scaled_product_full;

    always @(posedge clk) begin
        if (!rst_n) begin
            slice_index        <= {SLICE_INDEX_WIDTH{1'b0}};
            slice_sum_reg      <= {SLICE_SUM_WIDTH{1'b0}};
            slice_valid        <= 1'b0;
            slice_vector_start <= 1'b0;
            slice_vector_last  <= 1'b0;
            slice_invalid      <= 1'b0;
            slice_scale        <= {SCALE_WIDTH{1'b0}};
            group_accumulator  <= {GROUP_SUM_WIDTH{1'b0}};
            scaled_accumulator <= {ACC_WIDTH{1'b0}};
            pending_group_sum  <= {GROUP_SUM_WIDTH{1'b0}};
            pending_scale      <= {SCALE_WIDTH{1'b0}};
            pending_valid      <= 1'b0;
            pending_vector_last <= 1'b0;
            pending_invalid    <= 1'b0;
            vector_invalid     <= 1'b0;
            out_valid          <= 1'b0;
            result             <= {ACC_WIDTH{1'b0}};
            invalid_code       <= 1'b0;
        end else begin
            out_valid    <= 1'b0;
            invalid_code <= 1'b0;
            slice_valid  <= in_valid;
            if (in_valid) begin
                slice_sum_reg      <= slice_sum;
                slice_vector_start <= vector_start;
                slice_vector_last  <= vector_last;
                slice_invalid      <= invalid_slice;
                slice_scale        <= group_scale;
            end

            // The registered group boundary keeps the raw reduction tree out
            // of the scale-multiply timing path. The product is retired while
            // the next group's first slice is accepted.
            if (pending_valid) begin
                if (pending_vector_last) begin
                    result       <= scaled_accumulator + scaled_product;
                    out_valid    <= 1'b1;
                    invalid_code <= pending_invalid;
                    scaled_accumulator <= {ACC_WIDTH{1'b0}};
                end else begin
                    scaled_accumulator <= scaled_accumulator + scaled_product;
                end
                pending_valid <= 1'b0;
            end

            if (slice_valid) begin
                if (slice_vector_start) begin
                    slice_index        <= {SLICE_INDEX_WIDTH{1'b0}};
                    group_accumulator  <= {GROUP_SUM_WIDTH{1'b0}};
                    scaled_accumulator <= {ACC_WIDTH{1'b0}};
                    vector_invalid     <= slice_invalid;
                end else begin
                    vector_invalid <= vector_invalid | slice_invalid;
                end

                if (group_end) begin
                    pending_group_sum   <= completed_group_sum;
                    pending_scale       <= slice_scale;
                    pending_valid       <= 1'b1;
                    pending_vector_last <= slice_vector_last;
                    pending_invalid     <= slice_vector_start ? slice_invalid :
                                           (vector_invalid | slice_invalid);
                    slice_index         <= {SLICE_INDEX_WIDTH{1'b0}};
                    group_accumulator   <= {GROUP_SUM_WIDTH{1'b0}};
                end else begin
                    slice_index <= slice_index + 1'b1;
                    if (slice_index == 0)
                        group_accumulator <= extended_slice_sum;
                    else
                        group_accumulator <= group_accumulator + extended_slice_sum;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (K_WIDTH < 3 || K_WIDTH > 5)
            $error("qk_group_dot v0.2 supports signed 3..5-bit K codes");
        if (GROUP_SIZE % LANES != 0)
            $error("qk_group_dot: LANES must divide GROUP_SIZE");
    end
    always @(posedge clk) begin
        if (rst_n && slice_valid && slice_vector_last && !group_end)
            $error("qk_group_dot: vector_last must coincide with a group boundary");
        if (rst_n && slice_valid && slice_vector_start && slice_index != 0)
            $error("qk_group_dot: vector_start arrived mid-group");
    end
`endif
endmodule

`default_nettype wire
