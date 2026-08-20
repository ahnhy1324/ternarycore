`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_av_normalizer;
    localparam integer HEAD_DIM = 4;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg abort = 1'b0;
    reg [12:0] reciprocal_code = 13'd0;
    reg [4:0] reciprocal_exponent = 5'd0;
    reg numerator_valid = 1'b0;
    wire numerator_ready;
    reg [1:0] numerator_index = 2'd0;
    reg signed [47:0] numerator = 48'sd0;
    reg numerator_last = 1'b0;
    wire output_valid;
    reg output_ready = 1'b1;
    wire [1:0] output_index;
    wire signed [17:0] output_code;
    wire output_saturated, output_last, busy, done, aborted;
    wire [15:0] saturation_count;
    wire error_valid;
    wire [7:0] error_code;

    integer errors = 0;
    integer outputs = 0;
    integer done_pulses = 0;
    integer abort_pulses = 0;
    reg signed [17:0] expected_code [0:3];
    reg expected_sat [0:3];

    kv_v03_av_normalizer #(.HEAD_DIM(HEAD_DIM), .INDEX_WIDTH(2)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .reciprocal_code(reciprocal_code),
        .reciprocal_exponent(reciprocal_exponent),
        .numerator_valid(numerator_valid),
        .numerator_ready(numerator_ready),
        .numerator_index(numerator_index), .numerator(numerator),
        .numerator_last(numerator_last), .output_valid(output_valid),
        .output_ready(output_ready), .output_index(output_index),
        .output_code(output_code), .output_saturated(output_saturated),
        .output_last(output_last), .busy(busy), .done(done),
        .aborted(aborted), .saturation_count(saturation_count),
        .error_valid(error_valid), .error_code(error_code)
    );

    always @(posedge clk) begin
        if (done)
            done_pulses <= done_pulses + 1;
        if (aborted)
            abort_pulses <= abort_pulses + 1;
        if (output_valid && output_ready) begin
            if (output_index !== outputs[1:0]) begin
                $display("FAIL output index got=%0d exp=%0d", output_index,
                         outputs);
                errors = errors + 1;
            end
            if (output_code !== expected_code[outputs]) begin
                $display("FAIL output code idx=%0d got=%0d exp=%0d",
                         outputs, output_code, expected_code[outputs]);
                errors = errors + 1;
            end
            if (output_saturated !== expected_sat[outputs]) begin
                $display("FAIL saturation idx=%0d got=%0d exp=%0d",
                         outputs, output_saturated, expected_sat[outputs]);
                errors = errors + 1;
            end
            if (output_last !== (outputs == HEAD_DIM-1)) begin
                $display("FAIL output_last idx=%0d", outputs);
                errors = errors + 1;
            end
            outputs = outputs + 1;
        end
        if (abort && (numerator_valid && numerator_ready ||
                      output_valid && output_ready)) begin
            $display("FAIL abort leaked handshake");
            errors = errors + 1;
        end
    end

    task pulse_start;
        input [12:0] recip;
        input [4:0] exponent;
        begin
            @(negedge clk);
            reciprocal_code = recip;
            reciprocal_exponent = exponent;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task send_numerator;
        input [1:0] index;
        input signed [47:0] value;
        input is_last;
        integer watchdog;
        begin
            @(negedge clk);
            numerator_index = index;
            numerator = value;
            numerator_last = is_last;
            numerator_valid = 1'b1;
            watchdog = 0;
            while (!numerator_ready && watchdog < 100) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!numerator_ready) begin
                $display("FAIL numerator ready timeout");
                errors = errors + 1;
            end
            @(negedge clk);
            numerator_valid = 1'b0;
        end
    endtask

    task wait_done;
        integer watchdog;
        begin
            watchdog = 0;
            while (!done && watchdog < 200) begin
                @(negedge clk);
                watchdog = watchdog + 1;
            end
            if (!done) begin
                $display("FAIL done timeout");
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // reciprocal=4096, exponent=15 gives output_code=numerator/32768.
        // The middle two values are exact .5 ties and prove ties-to-even.
        expected_code[0] = 18'sd100;
        expected_code[1] = 18'sd10;
        expected_code[2] = -18'sd12;
        expected_code[3] = 18'sd131071;
        expected_sat[0] = 1'b0;
        expected_sat[1] = 1'b0;
        expected_sat[2] = 1'b0;
        expected_sat[3] = 1'b1;
        outputs = 0;
        pulse_start(13'd4096, 5'd15);
        output_ready = 1'b0;
        send_numerator(0, 48'sd3276800, 1'b0);
        repeat (3) @(posedge clk);
        if (!output_valid || output_index != 0 || output_code != 18'sd100) begin
            $display("FAIL held output changed under backpressure");
            errors = errors + 1;
        end
        @(negedge clk);
        output_ready = 1'b1;
        @(negedge clk);
        send_numerator(1, 48'sd344064, 1'b0); // +10.5 -> +10
        send_numerator(2, -48'sd376832, 1'b0); // -11.5 -> -12
        send_numerator(3, 48'sd6553600000, 1'b1);
        wait_done();
        if (outputs != 4 || saturation_count != 1) begin
            $display("FAIL transaction summary outputs=%0d sat=%0d", outputs,
                     saturation_count);
            errors = errors + 1;
        end

        // Framing failure is fail-closed.
        pulse_start(13'd4096, 5'd15);
        @(negedge clk);
        numerator_index = 2'd1;
        numerator = 48'sd1;
        numerator_last = 1'b0;
        numerator_valid = 1'b1;
        @(negedge clk);
        numerator_valid = 1'b0;
        if (!error_valid || error_code != 8'h03 || busy || output_valid) begin
            $display("FAIL framing fail-closed code=%02x", error_code);
            errors = errors + 1;
        end

        // A held result is canceled by abort and cannot handshake stale data.
        expected_code[0] = 18'sd1;
        expected_sat[0] = 1'b0;
        outputs = 0;
        pulse_start(13'd4096, 5'd15);
        output_ready = 1'b0;
        send_numerator(0, 48'sd32768, 1'b0);
        @(negedge clk);
        abort = 1'b1;
        output_ready = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        if (busy || output_valid || !aborted) begin
            $display("FAIL abort cleanup busy=%0d valid=%0d aborted=%0d", busy,
                     output_valid, aborted);
            errors = errors + 1;
        end
        @(negedge clk);
        if (abort_pulses != 1) begin
            $display("FAIL abort pulse count=%0d", abort_pulses);
            errors = errors + 1;
        end

        // Invalid reciprocal and busy-start are typed failures.
        pulse_start(13'd0, 5'd0);
        if (!error_valid || error_code != 8'h01) begin
            $display("FAIL reciprocal error code=%02x", error_code);
            errors = errors + 1;
        end
        pulse_start(13'd4096, 5'd15);
        pulse_start(13'd4096, 5'd15);
        if (!error_valid || error_code != 8'h02 || busy) begin
            $display("FAIL busy-start code=%02x busy=%0d", error_code, busy);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("TB PASS: KV v0.3 AV normalizer F12 round-even saturation");
        else begin
            $display("TB FAIL: KV v0.3 AV normalizer errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule

`default_nettype wire
