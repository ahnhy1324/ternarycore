`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_qk_score_quantizer;
`ifdef SCALE_FRACTION_BITS_VAL
    localparam integer SCALE_FRACTION_BITS = `SCALE_FRACTION_BITS_VAL;
`else
    localparam integer SCALE_FRACTION_BITS = 8;
`endif
    localparam integer SHIFT_BITS = SCALE_FRACTION_BITS - 8;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg abort = 1'b0;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [1:0] in_row = 2'd0;
    reg [11:0] in_index = 12'd0;
    reg signed [31:0] in_score = 32'sd0;
    wire out_valid;
    reg out_ready = 1'b1;
    wire [1:0] out_row;
    wire [11:0] out_index;
    wire signed [15:0] out_score;
    wire out_saturated;
    integer errors = 0;
    integer seq_id = 0;

    kv_v03_qk_score_quantizer #(
        .INPUT_WIDTH(32),
        .SCALE_FRACTION_BITS(SCALE_FRACTION_BITS),
        .OUTPUT_FRACTION_BITS(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .abort(abort),
        .in_valid(in_valid), .in_ready(in_ready), .in_row(in_row),
        .in_index(in_index), .in_score(in_score), .out_valid(out_valid),
        .out_ready(out_ready), .out_row(out_row), .out_index(out_index),
        .out_score(out_score), .out_saturated(out_saturated)
    );

    task send_and_expect;
        input signed [31:0] value;
        input signed [15:0] expected;
        input expected_saturated;
        integer watchdog;
        begin
            @(negedge clk);
            out_ready = 1'b0;
            while (!in_ready)
                @(negedge clk);
            in_score = value;
            in_row = seq_id[1:0];
            in_index = seq_id[11:0];
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            watchdog = 0;
            while (!out_valid && watchdog < 20) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!out_valid || out_score !== expected ||
                out_saturated !== expected_saturated ||
                out_row !== seq_id[1:0] ||
                out_index !== seq_id[11:0]) begin
                $display("FAIL q=%0d got=%0d/%0d tag=%0d:%0d expected=%0d/%0d",
                         value, out_score, out_saturated, out_row, out_index,
                         expected, expected_saturated);
                errors = errors + 1;
            end
            out_ready = 1'b1;
            @(negedge clk);
            seq_id = seq_id + 1;
        end
    endtask

    integer unit;
    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        unit = 1 << SHIFT_BITS;

        send_and_expect(0, 0, 0);
        send_and_expect(17*unit, 17, 0);
        send_and_expect(-17*unit, -17, 0);
        if (SHIFT_BITS > 0) begin
            // Halfway to an even integer stays even; halfway to an odd
            // integer rounds away to the adjacent even integer.
            send_and_expect((10*unit)+(unit/2), 10, 0);
            send_and_expect((11*unit)+(unit/2), 12, 0);
            send_and_expect(-((10*unit)+(unit/2)), -10, 0);
            send_and_expect(-((11*unit)+(unit/2)), -12, 0);
            send_and_expect((10*unit)+(unit/2)+1, 11, 0);
            send_and_expect(-((10*unit)+(unit/2)+1), -11, 0);
        end
        send_and_expect(32767*unit, 32767, 0);
        send_and_expect(32768*unit, 32767, 1);
        send_and_expect(-32768*unit, -32768, 0);
        send_and_expect(-32769*unit, -32768, 1);
        send_and_expect(-32'sd2147483647-1, -32768, 1);

        // Held output is stable under backpressure.
        out_ready = 1'b0;
        @(negedge clk);
        in_score = 32'sd123 * unit;
        in_row = 2'd3;
        in_index = 12'habc;
        in_valid = 1'b1;
        @(negedge clk);
        in_valid = 1'b0;
        repeat (3) begin
            @(negedge clk);
            if (!out_valid || out_score != 123 || out_row != 3 ||
                out_index != 12'habc) begin
                $display("FAIL held output changed");
                errors = errors + 1;
            end
        end
        // Abort cancels a held result and same-edge handshakes.
        abort = 1'b1;
        out_ready = 1'b1;
        #1;
        if (out_valid || in_ready) begin
            $display("FAIL abort did not gate ready/valid");
            errors = errors + 1;
        end
        @(negedge clk);
        abort = 1'b0;
        @(negedge clk);
        if (out_valid || !in_ready) begin
            $display("FAIL abort cleanup");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB PASS: KV v0.3 QK score quantizer scale_fraction_bits=%0d",
                     SCALE_FRACTION_BITS);
            $finish;
        end
        $fatal(1, "TB FAIL: QK score quantizer errors=%0d", errors);
    end
endmodule

`default_nettype wire
