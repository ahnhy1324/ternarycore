// tb_kv_v03_score_row_commit_guard.v
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_score_row_commit_guard;
    localparam integer MAX_CONTEXT = 8;
    localparam integer TAG_WIDTH = 128;
    localparam [127:0] TAG_LONG  = 128'h0001_0002_0003_0004_0005_0006_0007_0008;
    localparam [127:0] TAG_SHORT = 128'h1001_1002_1003_1004_1005_1006_1007_1008;
    localparam [127:0] TAG_BAD   = 128'hdead_beef_dead_beef_dead_beef_dead_beef;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg cmd_valid = 1'b0;
    wire cmd_ready;
    reg [12:0] cmd_context_len = 13'd0;
    reg [127:0] cmd_task_tag = 128'd0;
    reg abort = 1'b0;
    reg score_valid = 1'b0;
    wire score_ready;
    reg [1:0] score_row = 2'd0;
    reg [11:0] score_index = 12'd0;
    reg signed [15:0] score_data = 16'sd0;
    reg [127:0] score_task_tag = 128'd0;
    wire commit_valid;
    reg commit_ready = 1'b0;
    wire [127:0] commit_task_tag;
    wire [12:0] commit_context_len;
    wire active;
    reg bank_release = 1'b0;
    reg rd_en = 1'b0;
    reg [1:0] rd_row = 2'd0;
    reg [11:0] rd_index = 12'd0;
    wire rd_valid;
    wire signed [15:0] rd_data;
    wire busy;
    wire aborted;
    wire [127:0] aborted_task_tag;
    wire error_valid;
    wire [7:0] error_code;
    wire [127:0] error_task_tag;
    wire [31:0] accepted_score_count;
    wire [31:0] commit_count;

    integer errors = 0;
    integer abort_pulses = 0;
    integer error_pulses = 0;

    kv_v03_score_row_commit_guard #(
        .MAX_CONTEXT(MAX_CONTEXT), .TAG_WIDTH(TAG_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready), .cmd_context_len(cmd_context_len),
        .cmd_task_tag(cmd_task_tag), .abort(abort),
        .score_valid(score_valid), .score_ready(score_ready),
        .score_row(score_row), .score_index(score_index),
        .score_data(score_data), .score_task_tag(score_task_tag),
        .commit_valid(commit_valid), .commit_ready(commit_ready),
        .commit_task_tag(commit_task_tag),
        .commit_context_len(commit_context_len), .active(active),
        .bank_release(bank_release), .rd_en(rd_en), .rd_row(rd_row),
        .rd_index(rd_index), .rd_valid(rd_valid), .rd_data(rd_data),
        .busy(busy), .aborted(aborted),
        .aborted_task_tag(aborted_task_tag), .error_valid(error_valid),
        .error_code(error_code), .error_task_tag(error_task_tag),
        .accepted_score_count(accepted_score_count),
        .commit_count(commit_count)
    );

    always @(posedge clk) begin
        if (rst_n) begin
            if (aborted)
                abort_pulses = abort_pulses + 1;
            if (error_valid)
                error_pulses = error_pulses + 1;
            if (commit_valid && active) begin
                $display("FAIL commit_valid and active overlap");
                errors = errors + 1;
            end
            if ((commit_valid || active || score_ready || rd_valid) && abort) begin
                $display("FAIL externally visible handshake during abort");
                errors = errors + 1;
            end
        end
    end

    task pulse_cmd;
        input [12:0] context_len;
        input [127:0] tag;
        begin
            @(negedge clk);
            cmd_context_len = context_len;
            cmd_task_tag = tag;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task send_score;
        input [1:0] row_value;
        input [11:0] index_value;
        input signed [15:0] data_value;
        input [127:0] tag_value;
        begin
            @(negedge clk);
            score_row = row_value;
            score_index = index_value;
            score_data = data_value;
            score_task_tag = tag_value;
            score_valid = 1'b1;
            while (!score_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    task load_scores;
        input integer context_len;
        input [127:0] tag;
        integer token;
        integer row;
        begin
            for (token = 0; token < context_len; token = token + 1)
                for (row = 0; row < 4; row = row + 1)
                    send_score(row[1:0], token[11:0],
                               $signed(token*100 + row), tag);
        end
    endtask

    task accept_commit;
        input integer context_len;
        input [127:0] tag;
        integer hold_cycle;
        begin
            for (hold_cycle = 0; hold_cycle < 3; hold_cycle = hold_cycle + 1) begin
                @(negedge clk);
                if (!commit_valid || commit_task_tag !== tag ||
                    commit_context_len !== context_len) begin
                    $display("FAIL held commit fields cycle=%0d", hold_cycle);
                    errors = errors + 1;
                end
            end
            commit_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            commit_ready = 1'b0;
            if (!active) begin
                $display("FAIL bank did not become active");
                errors = errors + 1;
            end
        end
    endtask

    task check_scores;
        input integer context_len;
        integer token;
        integer row;
        reg signed [15:0] wanted;
        begin
            for (token = 0; token < context_len; token = token + 1)
                for (row = 0; row < 4; row = row + 1) begin
                    @(negedge clk);
                    rd_row = row[1:0];
                    rd_index = token[11:0];
                    rd_en = 1'b1;
                    @(posedge clk);
                    @(negedge clk);
                    rd_en = 1'b0;
                    wanted = token*100 + row;
                    if (!rd_valid || rd_data !== wanted) begin
                        $display("FAIL read token=%0d row=%0d got=%0d valid=%0d",
                                 token, row, $signed(rd_data), rd_valid);
                        errors = errors + 1;
                    end
                end
        end
    endtask

    task pulse_release;
        begin
            @(negedge clk);
            bank_release = 1'b1;
            @(posedge clk);
            @(negedge clk);
            bank_release = 1'b0;
            if (busy || active || commit_valid) begin
                $display("FAIL release did not return idle");
                errors = errors + 1;
            end
        end
    endtask

    task pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(posedge clk);
            @(negedge clk);
            abort = 1'b0;
            // Let the one-cycle status pulse reach the scoreboard.
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task expect_error;
        input [7:0] wanted_code;
        input [127:0] wanted_tag;
        begin
            if (!error_valid || error_code !== wanted_code ||
                error_task_tag !== wanted_tag) begin
                $display("FAIL error got valid=%0d code=%02x tag=%032x",
                         error_valid, error_code, error_task_tag);
                errors = errors + 1;
            end
            if (busy || active || commit_valid || rd_valid) begin
                $display("FAIL error left stale visibility");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Full long transaction and held all-or-nothing commit.
        pulse_cmd(4, TAG_LONG);
        load_scores(4, TAG_LONG);
        accept_commit(4, TAG_LONG);
        check_scores(4);
        pulse_release();

        // Partial long load aborts, then a short no-reset generation must not
        // expose any tail from the prior RAM contents.
        pulse_cmd(4, TAG_LONG);
        send_score(0, 0, 16'sd900, TAG_LONG);
        send_score(1, 0, 16'sd901, TAG_LONG);
        pulse_abort();
        if (aborted_task_tag !== TAG_LONG || abort_pulses != 1 || busy) begin
            $display("FAIL partial-load abort attribution");
            errors = errors + 1;
        end
        pulse_cmd(1, TAG_SHORT);
        load_scores(1, TAG_SHORT);
        accept_commit(1, TAG_SHORT);
        check_scores(1);
        @(negedge clk);
        rd_en = 1'b1;
        rd_row = 0;
        rd_index = 1;
        @(posedge clk);
        @(negedge clk);
        rd_en = 1'b0;
        if (rd_valid) begin
            $display("FAIL short generation exposed stale long tail");
            errors = errors + 1;
        end
        pulse_release();

        // Distinct tag and sequence faults are attributed to the accepted
        // command and publish nothing.
        pulse_cmd(1, TAG_LONG);
        send_score(0, 0, 16'sd1, TAG_BAD);
        expect_error(8'h03, TAG_LONG);
        pulse_cmd(1, TAG_SHORT);
        send_score(1, 0, 16'sd1, TAG_SHORT);
        expect_error(8'h02, TAG_SHORT);

        pulse_cmd(0, TAG_BAD);
        expect_error(8'h01, TAG_BAD);

        // Abort exactly while score VALID is presented: READY must be gated,
        // no score is accepted, and a new generation starts cleanly.
        pulse_cmd(1, TAG_LONG);
        @(negedge clk);
        score_valid = 1'b1;
        score_row = 0;
        score_index = 0;
        score_data = 16'sd77;
        score_task_tag = TAG_LONG;
        abort = 1'b1;
        #1;
        if (score_ready) begin
            $display("FAIL score_ready high on abort edge");
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        score_valid = 1'b0;
        abort = 1'b0;
        pulse_cmd(1, TAG_SHORT);
        load_scores(1, TAG_SHORT);
        accept_commit(1, TAG_SHORT);

        // Abort cancels a backpressured commit on the same edge.
        pulse_release();
        pulse_cmd(1, TAG_LONG);
        load_scores(1, TAG_LONG);
        @(negedge clk);
        if (!commit_valid)
            $fatal(1, "commit not pending for abort collision");
        abort = 1'b1;
        commit_ready = 1'b1;
        #1;
        if (commit_valid) begin
            $display("FAIL commit visible on abort edge");
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        abort = 1'b0;
        commit_ready = 1'b0;
        if (busy || active || commit_valid) begin
            $display("FAIL commit-abort left bank busy");
            errors = errors + 1;
        end

        // Reset mid-load is also fail-closed and permits a clean restart.
        pulse_cmd(2, TAG_LONG);
        send_score(0, 0, 16'sd5, TAG_LONG);
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        pulse_cmd(1, TAG_SHORT);
        load_scores(1, TAG_SHORT);
        accept_commit(1, TAG_SHORT);
        check_scores(1);
        pulse_release();

        if (accepted_score_count !== 4 || commit_count !== 1) begin
            // Counters reset during the directed reset above, so only the
            // final clean short transaction remains visible.
            $display("FAIL post-reset counters accepted=%0d commits=%0d",
                     accepted_score_count, commit_count);
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("KV_V03_SCORE_ROW_COMMIT_GUARD_PASS");
            $finish;
        end
        $fatal(1, "KV_V03_SCORE_ROW_COMMIT_GUARD_FAIL errors=%0d", errors);
    end
endmodule

`default_nettype wire
