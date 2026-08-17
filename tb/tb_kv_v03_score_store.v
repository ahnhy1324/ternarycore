// tb_kv_v03_score_store.v -- four-row synchronous score-memory regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_score_store;
    reg clk = 0, wr_en = 0, rd_en = 0;
    reg [1:0] wr_row = 0, rd_row = 0;
    reg [11:0] wr_addr = 0, rd_addr = 0;
    reg signed [15:0] wr_data = 0;
    wire rd_valid;
    wire signed [15:0] rd_data;
    integer row, address, errors = 0;
    reg signed [15:0] expected;

    always #5 clk = ~clk;

    kv_v03_score_store dut (
        .clk(clk), .wr_en(wr_en), .wr_row(wr_row), .wr_addr(wr_addr),
        .wr_data(wr_data), .rd_en(rd_en), .rd_row(rd_row),
        .rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data)
    );

    function signed [15:0] pattern;
        input integer test_row;
        input integer test_address;
        begin
            pattern = (test_row * 8191) ^ (test_address * 257) ^ 16'h5aa5;
        end
    endfunction

    initial begin
        // Cover first, adjacent, and final addresses in every independent row.
        for (row = 0; row < 4; row = row + 1) begin
            for (address = 0; address < 4; address = address + 1) begin
                @(negedge clk);
                wr_en = 1;
                wr_row = row;
                case (address)
                    0: wr_addr = 0;
                    1: wr_addr = 1;
                    2: wr_addr = 4094;
                    default: wr_addr = 4095;
                endcase
                wr_data = pattern(row, wr_addr);
            end
        end
        @(negedge clk);
        wr_en = 0;

        for (row = 0; row < 4; row = row + 1) begin
            for (address = 0; address < 4; address = address + 1) begin
                @(negedge clk);
                rd_en = 1;
                rd_row = row;
                case (address)
                    0: rd_addr = 0;
                    1: rd_addr = 1;
                    2: rd_addr = 4094;
                    default: rd_addr = 4095;
                endcase
                expected = pattern(row, rd_addr);
                @(posedge clk);
                #1;
                if (!rd_valid || rd_data !== expected) begin
                    $display("FAIL score store row=%0d addr=%0d got=%0d want=%0d",
                             row, rd_addr, rd_data, expected);
                    errors = errors + 1;
                end
            end
        end
        @(negedge clk);
        rd_en = 0;
        @(posedge clk);
        #1;
        if (rd_valid) begin
            $display("FAIL score store rd_valid did not clear");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 four-row synchronous score store");
            $finish;
        end
        $fatal(1, "TB FAIL: score store errors=%0d", errors);
    end
endmodule

`default_nettype wire
