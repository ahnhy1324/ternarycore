// kv_v03_score_row_commit_guard.v -- typed all-or-nothing score-row bank.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// A transaction is published only after all four GQA score rows have arrived
// in token-major order.  Old RAM contents are never visible unless the
// matching generation has crossed the commit handshake.
module kv_v03_score_row_commit_guard #(
    parameter integer MAX_CONTEXT = 128,
    parameter integer TAG_WIDTH = 128
) (
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire                        cmd_valid,
    output wire                        cmd_ready,
    input  wire [12:0]                 cmd_context_len,
    input  wire [TAG_WIDTH-1:0]        cmd_task_tag,
    input  wire                        abort,

    input  wire                        score_valid,
    output wire                        score_ready,
    input  wire [1:0]                  score_row,
    input  wire [11:0]                 score_index,
    input  wire signed [15:0]          score_data,
    input  wire [TAG_WIDTH-1:0]        score_task_tag,

    output wire                        commit_valid,
    input  wire                        commit_ready,
    output wire [TAG_WIDTH-1:0]        commit_task_tag,
    output wire [12:0]                 commit_context_len,

    output wire                        active,
    input  wire                        bank_release,
    input  wire                        rd_en,
    input  wire [1:0]                  rd_row,
    input  wire [11:0]                 rd_index,
    output reg                         rd_valid,
    output reg signed [15:0]           rd_data,

    output wire                        busy,
    output reg                         aborted,
    output reg  [TAG_WIDTH-1:0]        aborted_task_tag,
    output reg                         error_valid,
    output reg  [7:0]                  error_code,
    output reg  [TAG_WIDTH-1:0]        error_task_tag,
    output reg  [31:0]                 accepted_score_count,
    output reg  [31:0]                 commit_count
);
    localparam [1:0] ST_IDLE   = 2'd0,
                     ST_LOAD   = 2'd1,
                     ST_COMMIT = 2'd2,
                     ST_ACTIVE = 2'd3;
    localparam [7:0] ERR_CONTEXT  = 8'h01,
                     ERR_SEQUENCE = 8'h02,
                     ERR_TAG      = 8'h03;

    reg [1:0] state;
    reg [12:0] context_reg;
    reg [TAG_WIDTH-1:0] task_tag_reg;
    reg [1:0] expected_row;
    reg [11:0] expected_index;
    reg signed [15:0] score_mem [0:3][0:MAX_CONTEXT-1];

    assign cmd_ready = state == ST_IDLE && !abort;
    assign score_ready = state == ST_LOAD && !abort;
    assign commit_valid = state == ST_COMMIT && !abort;
    assign commit_task_tag = task_tag_reg;
    assign commit_context_len = context_reg;
    assign active = state == ST_ACTIVE && !abort && !bank_release;
    assign busy = state != ST_IDLE;

    wire cmd_fire = cmd_valid && cmd_ready;
    wire score_fire = score_valid && score_ready;
    wire commit_fire = commit_valid && commit_ready;
    wire score_tag_ok = score_task_tag == task_tag_reg;
    wire score_sequence_ok = score_row == expected_row &&
                             score_index == expected_index;
    wire score_last = expected_row == 2'd3 &&
                      expected_index == context_reg - 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            context_reg <= 13'd0;
            task_tag_reg <= {TAG_WIDTH{1'b0}};
            expected_row <= 2'd0;
            expected_index <= 12'd0;
            rd_valid <= 1'b0;
            rd_data <= 16'sd0;
            aborted <= 1'b0;
            aborted_task_tag <= {TAG_WIDTH{1'b0}};
            error_valid <= 1'b0;
            error_code <= 8'd0;
            error_task_tag <= {TAG_WIDTH{1'b0}};
            accepted_score_count <= 32'd0;
            commit_count <= 32'd0;
        end else begin
            rd_valid <= 1'b0;
            aborted <= 1'b0;
            error_valid <= 1'b0;

            if (abort && state != ST_IDLE) begin
                aborted <= 1'b1;
                aborted_task_tag <= task_tag_reg;
                state <= ST_IDLE;
                context_reg <= 13'd0;
                expected_row <= 2'd0;
                expected_index <= 12'd0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (cmd_fire) begin
                            if (cmd_context_len == 0 ||
                                cmd_context_len > MAX_CONTEXT) begin
                                error_valid <= 1'b1;
                                error_code <= ERR_CONTEXT;
                                error_task_tag <= cmd_task_tag;
                            end else begin
                                context_reg <= cmd_context_len;
                                task_tag_reg <= cmd_task_tag;
                                expected_row <= 2'd0;
                                expected_index <= 12'd0;
                                state <= ST_LOAD;
                            end
                        end
                    end

                    ST_LOAD: begin
                        if (score_fire) begin
                            if (!score_tag_ok) begin
                                error_valid <= 1'b1;
                                error_code <= ERR_TAG;
                                error_task_tag <= task_tag_reg;
                                state <= ST_IDLE;
                            end else if (!score_sequence_ok) begin
                                error_valid <= 1'b1;
                                error_code <= ERR_SEQUENCE;
                                error_task_tag <= task_tag_reg;
                                state <= ST_IDLE;
                            end else begin
                                score_mem[score_row][score_index] <= score_data;
                                accepted_score_count <=
                                    accepted_score_count + 1'b1;
                                if (score_last) begin
                                    state <= ST_COMMIT;
                                end else if (expected_row == 2'd3) begin
                                    expected_row <= 2'd0;
                                    expected_index <= expected_index + 1'b1;
                                end else begin
                                    expected_row <= expected_row + 1'b1;
                                end
                            end
                        end
                    end

                    ST_COMMIT: begin
                        if (commit_fire) begin
                            commit_count <= commit_count + 1'b1;
                            state <= ST_ACTIVE;
                        end
                    end

                    ST_ACTIVE: begin
                        if (bank_release) begin
                            state <= ST_IDLE;
                            context_reg <= 13'd0;
                        end else if (rd_en && rd_index < context_reg) begin
                            rd_data <= score_mem[rd_row][rd_index];
                            rd_valid <= 1'b1;
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 4096)
            $error("kv_v03_score_row_commit_guard MAX_CONTEXT must be 1..4096");
        if (TAG_WIDTH < 1)
            $error("kv_v03_score_row_commit_guard TAG_WIDTH must be positive");
    end
`endif
endmodule

`default_nettype wire
