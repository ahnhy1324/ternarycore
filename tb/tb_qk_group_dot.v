// tb_qk_group_dot.v -- actual-model group128 K4/K5 golden checks.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_qk_group_dot;
`ifdef K_WIDTH_VAL
    localparam K_WIDTH = `K_WIDTH_VAL;
`else
    localparam K_WIDTH = 4;
`endif
`ifdef MULT_STYLE_VAL
    localparam MULT_STYLE = `MULT_STYLE_VAL;
`else
    localparam MULT_STYLE = 2;
`endif
    localparam LANES = 16;
    localparam HEAD_DIM = 128;
    localparam GROUP_SIZE = 128;
    localparam GROUPS = HEAD_DIM / GROUP_SIZE;
    localparam SLICES = HEAD_DIM / LANES;
    localparam CONTEXT = 128;
    localparam ACC_WIDTH = 64;

    reg clk = 0, rst_n = 0;
    reg in_valid = 0, vector_start = 0, vector_last = 0;
    reg [(LANES*8)-1:0] q_lanes = 0;
    reg [(LANES*K_WIDTH)-1:0] k_lanes = 0;
    reg [15:0] group_scale = 0;
    wire out_valid, invalid_code;
    wire signed [ACC_WIDTH-1:0] result;

    reg [7:0] q_mem [0:HEAD_DIM-1];
    reg [K_WIDTH-1:0] k_mem [0:CONTEXT*HEAD_DIM-1];
    reg [15:0] scale_mem [0:CONTEXT*GROUPS-1];
    reg [63:0] expected_mem [0:CONTEXT-1];
    integer token, slice, lane, errors = 0, timeout;
    reg [15:0] lfsr = 16'h1ace;
    string golden_root;

    always #5 clk = ~clk;

    qk_group_dot #(
        .LANES(LANES), .GROUP_SIZE(GROUP_SIZE), .Q_WIDTH(8),
        .K_WIDTH(K_WIDTH), .SCALE_WIDTH(16), .ACC_WIDTH(ACC_WIDTH),
        .MULT_STYLE(MULT_STYLE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .vector_start(vector_start), .vector_last(vector_last),
        .q_lanes(q_lanes), .k_lanes(k_lanes), .group_scale(group_scale),
        .out_valid(out_valid), .result(result), .invalid_code(invalid_code)
    );

    task drive_gap;
        begin
            if (lfsr[1:0] == 2'b00) begin
                @(negedge clk);
                in_valid = 0;
                vector_start = 0;
                vector_last = 0;
                lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            end
        end
    endtask

    task wait_and_check;
        input integer expected_index;
        input integer expect_invalid;
        begin
            @(negedge clk);
            in_valid = 0;
            vector_start = 0;
            vector_last = 0;
            timeout = 0;
            while (!out_valid && timeout < 20) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!out_valid) begin
                $display("FAIL token %0d: result timeout", expected_index);
                errors = errors + 1;
            end else if (invalid_code !== expect_invalid[0]) begin
                $display("FAIL token %0d: invalid=%0d want %0d",
                         expected_index, invalid_code, expect_invalid);
                errors = errors + 1;
            end else if (!expect_invalid &&
                         $signed(result) !== $signed(expected_mem[expected_index])) begin
                $display("FAIL token %0d: got %0d want %0d", expected_index,
                         $signed(result), $signed(expected_mem[expected_index]));
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/real_model/qk_profile_golden_v0_2/regular4";
        $readmemh({golden_root, "/../q_int8.hex"}, q_mem);
        $readmemh({golden_root, "/k_codes.hex"}, k_mem);
        $readmemh({golden_root, "/k_scale_uq5_11_u16.hex"}, scale_mem);
        $readmemh({golden_root, "/expected_scaled_accum_i64.hex"}, expected_mem);

        repeat (3) @(negedge clk);
        rst_n = 1;
        for (token = 0; token < CONTEXT; token = token + 1) begin
            for (slice = 0; slice < SLICES; slice = slice + 1) begin
                drive_gap();
                @(negedge clk);
                q_lanes = 0;
                k_lanes = 0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    q_lanes[(lane*8) +: 8] = q_mem[slice*LANES + lane];
                    k_lanes[(lane*K_WIDTH) +: K_WIDTH] =
                        k_mem[token*HEAD_DIM + slice*LANES + lane];
                end
                group_scale = scale_mem[token*GROUPS + slice/(GROUP_SIZE/LANES)];
                in_valid = 1;
                vector_start = (slice == 0);
                vector_last = (slice == SLICES-1);
                lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            end
            wait_and_check(token, 0);
        end

        // A short vector immediately after the long run exercises stale state
        // and the reserved canonical nibble error path.
        for (slice = 0; slice < SLICES; slice = slice + 1) begin
            @(negedge clk);
            q_lanes = 0;
            k_lanes = 0;
            for (lane = 0; lane < LANES; lane = lane + 1)
                q_lanes[(lane*8) +: 8] = 8'd1;
            if (slice == 0)
                k_lanes[K_WIDTH-1:0] = {1'b1, {(K_WIDTH-1){1'b0}}};
            group_scale = 16'h0800;
            in_valid = 1;
            vector_start = (slice == 0);
            vector_last = (slice == SLICES-1);
        end
        wait_and_check(0, 1);

        if (errors == 0) begin
            $display("TB PASS: qk_group_dot K%0d style%0d real-model golden (%0d tokens)",
                     K_WIDTH, MULT_STYLE, CONTEXT);
            $finish;
        end else begin
            $fatal(1, "TB FAIL: qk_group_dot errors=%0d", errors);
        end
    end
endmodule

`default_nettype wire
