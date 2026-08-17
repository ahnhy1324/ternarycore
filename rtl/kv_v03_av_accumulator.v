// kv_v03_av_accumulator.v -- four-head P16 banked integer AV numerator.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// Keep each 32-word lane in its own inference boundary.  The accumulator and
// result stream are mutually exclusive, so one asynchronous read address is
// sufficient for both phases and maps naturally to distributed RAM.
module kv_v03_av_numerator_lane (
    input  wire                    clk,
    input  wire                    write_en,
    input  wire [4:0]              write_addr,
    input  wire signed [47:0]      write_data,
    input  wire [4:0]              read_addr,
    output wire signed [47:0]      read_data
);
    (* ram_style = "distributed" *)
    reg signed [47:0] memory [0:31];

    always @(posedge clk) begin
        if (write_en)
            memory[write_addr] <= write_data;
    end

    assign read_data = memory[read_addr];
endmodule

module kv_v03_av_accumulator #(
    parameter integer MAX_CONTEXT = 4096,
    parameter integer MULT_STYLE = 2
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [12:0]          context_len,
    input  wire                 in_valid,
    output wire                 in_ready,
    input  wire [1:0]           in_head,
    input  wire [2:0]           in_group,
    input  wire [15:0]          in_exp_code,
    input  wire [11:0]          in_v_scale,
    input  wire [79:0]          in_v_codes,
    output wire                 out_valid,
    input  wire                 out_ready,
    output reg  [1:0]           out_head,
    output reg  [2:0]           out_group,
    output wire [767:0]         out_numerators,
    output wire                 out_last,
    output wire                 busy,
    output reg                  done,
    output reg                  error_valid,
    output reg  [7:0]           error_code
);
    localparam integer LANES = 16;
    localparam integer GROUPS = 8;
    localparam integer ACC_WIDTH = 48;
    localparam integer PRODUCT_WIDTH = 33;
    localparam [7:0] ERR_CONTEXT = 8'h01;
    localparam [7:0] ERR_BUSY = 8'h02;
    localparam [7:0] ERR_SCHEDULE = 8'h03;
    localparam [7:0] ERR_RESERVED = 8'h04;
    localparam [7:0] ERR_SCALE = 8'h05;
    // The legal maximum magnitude is
    // (2^16-1)*(2^12-1)*15*4096 < 2^44.  A signed 48-bit accumulator
    // therefore has three guard bits beyond the 45-bit minimum, so a runtime
    // overflow detector would only add an unreachable global control path.

    reg active, accepting, output_active;
    reg [12:0] context_reg, token_counter;
    reg [1:0] expected_head;
    reg [2:0] expected_group;

    wire input_handshake = in_valid && in_ready;
    wire [27:0] input_weight = in_exp_code * in_v_scale;
    wire input_first_token = (token_counter == 0);
    wire input_final = (token_counter == context_reg-1'b1) &&
                       (expected_head == 3) && (expected_group == 7);

    wire invalid_lane [0:15];
    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_invalid
            assign invalid_lane[lane] =
                in_v_codes[(lane*5) +: 5] == 5'b10000;
        end
    endgenerate
    wire invalid_v_code = invalid_lane[0] | invalid_lane[1] |
        invalid_lane[2] | invalid_lane[3] | invalid_lane[4] |
        invalid_lane[5] | invalid_lane[6] | invalid_lane[7] |
        invalid_lane[8] | invalid_lane[9] | invalid_lane[10] |
        invalid_lane[11] | invalid_lane[12] | invalid_lane[13] |
        invalid_lane[14] | invalid_lane[15];

    reg stage0_valid, stage0_first, stage0_final;
    reg [4:0] stage0_address;
    reg [27:0] stage0_weight;
    reg [79:0] stage0_v_codes;
    wire signed [PRODUCT_WIDTH-1:0] product_next [0:15];
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_multiply
            kv_v03_v5_weight_mul #(
                .WEIGHT_WIDTH(28), .MULT_STYLE(MULT_STYLE)
            ) u_multiply (
                .weight(stage0_weight),
                .v_code(stage0_v_codes[(lane*5) +: 5]),
                .product(product_next[lane])
            );
        end
    endgenerate

    reg stage1_valid, stage1_first, stage1_final;
    reg [4:0] stage1_address;
    reg signed [PRODUCT_WIDTH-1:0] stage1_product [0:15];

    // Sixteen lane banks, each with four heads x eight dimension groups.
    // The first token overwrites every logical entry, so no bulk reset is
    // required.  Accumulation and result output never overlap, allowing their
    // addresses to share the single asynchronous read port.
    wire [4:0] numerator_read_address = output_active ?
                                                {out_head, out_group} :
                                                stage1_address;
    wire signed [ACC_WIDTH-1:0] numerator_read [0:15];
    wire signed [ACC_WIDTH-1:0] next_accumulator [0:15];
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_accumulate
            wire signed [ACC_WIDTH-1:0] extended_product =
                {{(ACC_WIDTH-PRODUCT_WIDTH){stage1_product[lane][PRODUCT_WIDTH-1]}},
                 stage1_product[lane]};
            assign next_accumulator[lane] = stage1_first ?
                extended_product : numerator_read[lane] + extended_product;
            assign out_numerators[(lane*ACC_WIDTH) +: ACC_WIDTH] =
                numerator_read[lane];
            kv_v03_av_numerator_lane u_numerator_lane (
                .clk(clk),
                // The proven legal bound above makes the write enable depend
                // only on transaction/pipeline state.  This also avoids a
                // data-dependent 16-lane reduction feeding all RAM lanes.
                .write_en(!start && active && stage1_valid),
                .write_addr(stage1_address),
                .write_data(next_accumulator[lane]),
                .read_addr(numerator_read_address),
                .read_data(numerator_read[lane])
            );
        end
    endgenerate
    assign in_ready = active && accepting;
    assign out_valid = output_active;
    assign out_last = output_active && out_head == 3 && out_group == 7;
    assign busy = active;

    integer update_lane;
    always @(posedge clk) begin
        if (!rst_n) begin
            active           <= 1'b0;
            accepting        <= 1'b0;
            output_active    <= 1'b0;
            context_reg      <= 13'b0;
            token_counter    <= 13'b0;
            expected_head    <= 2'b0;
            expected_group   <= 3'b0;
            stage0_valid     <= 1'b0;
            stage0_first     <= 1'b0;
            stage0_final     <= 1'b0;
            stage0_address   <= 5'b0;
            stage0_weight    <= 28'b0;
            stage0_v_codes   <= 80'b0;
            stage1_valid     <= 1'b0;
            stage1_first     <= 1'b0;
            stage1_final     <= 1'b0;
            stage1_address   <= 5'b0;
            out_head         <= 2'b0;
            out_group        <= 3'b0;
            done             <= 1'b0;
            error_valid      <= 1'b0;
            error_code       <= 8'b0;
            for (update_lane = 0; update_lane < LANES;
                 update_lane = update_lane + 1)
                stage1_product[update_lane] <= {PRODUCT_WIDTH{1'b0}};
        end else begin
            done        <= 1'b0;
            error_valid <= 1'b0;

            if (start) begin
                if (active) begin
                    // Do not pause live pipeline-valid bits: resuming them on
                    // the next cycle would commit the same update twice.
                    // Abort the in-flight transaction with a typed error.
                    active        <= 1'b0;
                    accepting     <= 1'b0;
                    output_active <= 1'b0;
                    stage0_valid  <= 1'b0;
                    stage1_valid  <= 1'b0;
                    error_valid   <= 1'b1;
                    error_code    <= ERR_BUSY;
                end else if (context_len == 0 || context_len > MAX_CONTEXT) begin
                    error_valid <= 1'b1;
                    error_code  <= ERR_CONTEXT;
                end else begin
                    active         <= 1'b1;
                    accepting      <= 1'b1;
                    output_active  <= 1'b0;
                    context_reg    <= context_len;
                    token_counter  <= 13'b0;
                    expected_head  <= 2'b0;
                    expected_group <= 3'b0;
                    stage0_valid   <= 1'b0;
                    stage1_valid   <= 1'b0;
                    out_head       <= 2'b0;
                    out_group      <= 3'b0;
                    error_code     <= 8'b0;
                end
            end else if (active) begin
                stage0_valid <= input_handshake;
                stage1_valid <= stage0_valid;

                if (stage0_valid) begin
                    for (update_lane = 0; update_lane < LANES;
                         update_lane = update_lane + 1)
                        stage1_product[update_lane] <=
                            product_next[update_lane];
                    stage1_address <= stage0_address;
                    stage1_first   <= stage0_first;
                    stage1_final   <= stage0_final;
                end

                if (stage1_valid) begin
                    if (stage1_final) begin
                        output_active <= 1'b1;
                        out_head      <= 2'b0;
                        out_group     <= 3'b0;
                    end
                end

                if (input_handshake) begin
                    if (in_head != expected_head ||
                        in_group != expected_group) begin
                        active        <= 1'b0;
                        accepting     <= 1'b0;
                        output_active <= 1'b0;
                        stage0_valid  <= 1'b0;
                        stage1_valid  <= 1'b0;
                        error_valid   <= 1'b1;
                        error_code    <= ERR_SCHEDULE;
                    end else if (invalid_v_code) begin
                        active        <= 1'b0;
                        accepting     <= 1'b0;
                        output_active <= 1'b0;
                        stage0_valid  <= 1'b0;
                        stage1_valid  <= 1'b0;
                        error_valid   <= 1'b1;
                        error_code    <= ERR_RESERVED;
                    end else if (in_v_scale == 0) begin
                        active        <= 1'b0;
                        accepting     <= 1'b0;
                        output_active <= 1'b0;
                        stage0_valid  <= 1'b0;
                        stage1_valid  <= 1'b0;
                        error_valid   <= 1'b1;
                        error_code    <= ERR_SCALE;
                    end else begin
                        stage0_address <= {expected_head, expected_group};
                        stage0_weight  <= input_weight;
                        stage0_v_codes <= in_v_codes;
                        stage0_first   <= input_first_token;
                        stage0_final   <= input_final;
                        if (input_final)
                            accepting <= 1'b0;
                        if (expected_group == GROUPS-1) begin
                            expected_group <= 3'b0;
                            if (expected_head == 3) begin
                                expected_head <= 2'b0;
                                if (token_counter != context_reg-1'b1)
                                    token_counter <= token_counter + 1'b1;
                            end else begin
                                expected_head <= expected_head + 1'b1;
                            end
                        end else begin
                            expected_group <= expected_group + 1'b1;
                        end
                    end
                end

                if (output_active && out_ready) begin
                    if (out_group == GROUPS-1) begin
                        out_group <= 3'b0;
                        if (out_head == 3) begin
                            output_active <= 1'b0;
                            active        <= 1'b0;
                            done          <= 1'b1;
                        end else begin
                            out_head <= out_head + 1'b1;
                        end
                    end else begin
                        out_group <= out_group + 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT != 4096)
            $error("kv_v03_av_accumulator: v0.3 ABI fixes MAX_CONTEXT=4096");
        if (MULT_STYLE < 0 || MULT_STYLE > 2)
            $error("kv_v03_av_accumulator: MULT_STYLE must be 0..2");
    end
`endif
endmodule

`default_nettype wire
