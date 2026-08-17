// tb_kv_v03_page_header.v -- PACKED5 header validation and CRC gating.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_page_header;
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg header_valid = 0;
    reg [95:0] header_data = 0;
    reg crc_valid = 0;
    reg [31:0] computed_crc = 0;
    wire busy, descriptor_valid, raw_mode, stream_is_v, error_valid;
    wire [7:0] token_count, scale_format_id, error_code;
    wire [15:0] payload_bytes;
    wire [31:0] expected_crc;
    integer errors = 0;
    reg [95:0] header;

    always #5 clk = ~clk;

    kv_v03_page_header dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .header_valid(header_valid), .header_data(header_data),
        .crc_valid(crc_valid), .computed_crc(computed_crc), .busy(busy),
        .descriptor_valid(descriptor_valid), .raw_mode(raw_mode),
        .stream_is_v(stream_is_v), .token_count(token_count),
        .payload_bytes(payload_bytes), .scale_format_id(scale_format_id),
        .expected_crc(expected_crc), .error_valid(error_valid),
        .error_code(error_code)
    );

    function [95:0] make_header;
        input [7:0] flags;
        input [7:0] tokens_minus_one;
        input [15:0] payload;
        input [7:0] codebook;
        input [7:0] scale_id;
        input [31:0] stored_crc;
        begin
            make_header = {stored_crc, scale_id, codebook, payload,
                           tokens_minus_one, flags, 16'hc303};
        end
    endfunction

    task reset_parser;
        begin
            @(negedge clk);
            start = 1;
            header_valid = 0;
            crc_valid = 0;
            @(negedge clk);
            start = 0;
        end
    endtask

    task present_header;
        input [95:0] value;
        begin
            @(negedge clk);
            header_data = value;
            header_valid = 1;
            @(negedge clk);
            header_valid = 0;
        end
    endtask

    task present_crc;
        input [31:0] value;
        begin
            @(negedge clk);
            computed_crc = value;
            crc_valid = 1;
            @(negedge clk);
            crc_valid = 0;
        end
    endtask

    task expect_header_error;
        input [95:0] value;
        input [7:0] wanted;
        begin
            reset_parser();
            present_header(value);
            if (!error_valid || error_code !== wanted || descriptor_valid) begin
                $display("FAIL header error got valid=%0d code=%02x want=%02x",
                         error_valid, error_code, wanted);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        header = make_header(8'h00, 8'd127, 16'd7000,
                             8'd1, 8'd1, 32'h12345678);
        reset_parser();
        present_header(header);
        if (!busy || descriptor_valid || error_valid) begin
            $display("FAIL valid header did not wait for CRC");
            errors = errors + 1;
        end
        present_crc(32'h12345678);
        if (!descriptor_valid || busy || raw_mode || stream_is_v ||
            token_count != 128 || payload_bytes != 7000 ||
            scale_format_id != 1 || expected_crc != 32'h12345678) begin
            $display("FAIL compressed K descriptor fields/gating");
            errors = errors + 1;
        end

        header = make_header(8'h03, 8'd63, 16'd5120,
                             8'd1, 8'd2, 32'h89abcdef);
        reset_parser();
        present_header(header);
        present_crc(32'h89abcdef);
        if (!descriptor_valid || !raw_mode || !stream_is_v ||
            token_count != 64 || payload_bytes != 5120 || scale_format_id != 2) begin
            $display("FAIL raw V descriptor fields");
            errors = errors + 1;
        end

        reset_parser();
        present_header(make_header(8'h00, 8'd0, 16'd1,
                                   8'd1, 8'd1, 32'h11111111));
        present_crc(32'h22222222);
        if (!error_valid || error_code != 8'h07 || descriptor_valid) begin
            $display("FAIL CRC mismatch was not gated");
            errors = errors + 1;
        end

        header = make_header(8'h00, 8'd0, 16'd1,
                             8'd1, 8'd1, 32'h0);
        header[15:0] = 16'hc302;
        expect_header_error(header, 8'h01);
        expect_header_error(make_header(8'h80, 8'd0, 16'd1,
                                        8'd1, 8'd1, 32'h0), 8'h02);
        expect_header_error(make_header(8'h00, 8'd128, 16'd1,
                                        8'd1, 8'd1, 32'h0), 8'h03);
        expect_header_error(make_header(8'h01, 8'd63, 16'd4095,
                                        8'd1, 8'd1, 32'h0), 8'h04);
        expect_header_error(make_header(8'h00, 8'd63, 16'd4096,
                                        8'd1, 8'd1, 32'h0), 8'h04);
        expect_header_error(make_header(8'h00, 8'd0, 16'd1,
                                        8'd2, 8'd1, 32'h0), 8'h05);
        expect_header_error(make_header(8'h00, 8'd0, 16'd1,
                                        8'd1, 8'd3, 32'h0), 8'h06);

        reset_parser();
        present_crc(32'h0);
        if (!error_valid || error_code != 8'h08 || descriptor_valid) begin
            $display("FAIL orphan CRC was not rejected");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB PASS: v0.3 page header validation/CRC gating");
            $finish;
        end
        $fatal(1, "TB FAIL: v0.3 page header errors=%0d", errors);
    end
endmodule

`default_nettype wire
