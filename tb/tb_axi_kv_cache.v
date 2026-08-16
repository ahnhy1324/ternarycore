// tb_axi_kv_cache.v -- AXI-Lite register ABI plus read-master integration.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_axi_kv_cache;
    localparam HEAD_DIM = 64, MAX_CONTEXT = 4096, BASE = 32'h8000_2000;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [15:0] awaddr = 0; reg [2:0] awprot = 0; reg awvalid = 0;
    wire awready;
    reg [31:0] wdata = 0; reg [3:0] wstrb = 0; reg wvalid = 0;
    wire wready; wire [1:0] bresp; wire bvalid; reg bready = 0;
    reg [15:0] araddr_s = 0; reg [2:0] arprot_s = 0; reg arvalid_s = 0;
    wire arready_s; wire [31:0] rdata_s; wire [1:0] rresp_s;
    wire rvalid_s; reg rready_s = 0;

    wire [0:0] arid;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arlock; wire [3:0] arcache, arqos; wire [2:0] arprot;
    wire arvalid; reg arready = 0;
    reg [0:0] rid = 0; reg [127:0] rdata = 0;
    reg [1:0] rresp = 0; reg rlast = 0, rvalid = 0;
    wire rready;

    axi_kv_cache #(
        .HEAD_DIM(HEAD_DIM), .MAX_CONTEXT(MAX_CONTEXT),
        .M_AXI_DATA_WIDTH(128), .TIMEOUT_CYCLES(1000)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(awprot),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr_s), .s_axi_arprot(arprot_s),
        .s_axi_arvalid(arvalid_s), .s_axi_arready(arready_s),
        .s_axi_rdata(rdata_s), .s_axi_rresp(rresp_s),
        .s_axi_rvalid(rvalid_s), .s_axi_rready(rready_s),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arlock(arlock), .m_axi_arcache(arcache),
        .m_axi_arprot(arprot), .m_axi_arqos(arqos),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    function signed [3:0] k_at;
        input integer token; input integer dim;
        integer code;
        begin code = (token*3 + dim*5 + 8) & 15; k_at = code[3:0]; end
    endfunction
    function integer q_at;
        input integer dim; begin q_at = (dim % 9) - 4; end
    endfunction
    function signed [31:0] expected_dot;
        input integer token;
        integer dim; reg signed [31:0] sum;
        begin
            sum = 0;
            for (dim = 0; dim < HEAD_DIM; dim = dim + 1)
                sum = sum + q_at(dim) * $signed(k_at(token, dim)) * 256;
            expected_dot = sum;
        end
    endfunction
    function [127:0] make_beat;
        input integer token; input integer beat;
        integer lane; reg [127:0] value;
        begin
            value = 0;
            for (lane = 0; lane < 32; lane = lane + 1)
                value[(lane*4) +: 4] = k_at(token, beat*32 + lane);
            make_beat = value;
        end
    endfunction

    reg pending = 0; integer pending_token = 0, beat_no = 0;
    reg [15:0] lfsr = 16'hbabe;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending <= 0; arready <= 0; rvalid <= 0; lfsr <= 16'hbabe;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            arready <= !pending && lfsr[0];
            if (arvalid && arready) begin
                pending <= 1; pending_token <= (araddr - BASE) >> 5; beat_no <= 0;
            end
            if (!rvalid && pending && lfsr[1]) begin
                rdata <= make_beat(pending_token, beat_no);
                rlast <= (beat_no == 1); rresp <= 0; rvalid <= 1;
            end
            if (rvalid && rready) begin
                rvalid <= 0;
                if (rlast) pending <= 0; else beat_no <= beat_no + 1;
            end
        end
    end

    task axi_write_split;
        input [15:0] addr; input [31:0] data; input integer gap;
        begin
            @(negedge clk); awaddr = addr; awvalid = 1; bready = 1;
            wait (awready); @(negedge clk); awvalid = 0;
            repeat (gap) @(negedge clk);
            wdata = data; wstrb = 4'hf; wvalid = 1;
            wait (wready); @(negedge clk); wvalid = 0; wstrb = 0;
            wait (bvalid); @(posedge clk); @(negedge clk); bready = 0;
        end
    endtask

    task axi_read;
        input [15:0] addr; output [31:0] data;
        begin
            @(negedge clk); araddr_s = addr; arvalid_s = 1; rready_s = 1;
            wait (arready_s); @(negedge clk); arvalid_s = 0;
            wait (rvalid_s); #1 data = rdata_s;
            @(posedge clk); @(negedge clk); rready_s = 0;
        end
    endtask

    integer word_index, byte_index, token, errors = 0, polls;
    reg [31:0] word, rd;
    initial begin
        repeat (5) @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        axi_read(16'h0030, rd);
        if (rd != 32'h4b56_0001) begin
            $display("FAIL core ID %08x", rd); errors = errors + 1;
        end
        axi_read(16'h0034, rd);
        if (rd != 32'h8040_1004) begin
            $display("FAIL geometry %08x", rd); errors = errors + 1;
        end

        // Write Q with AW and W separated by varying CPU-like gaps.
        for (word_index = 0; word_index < HEAD_DIM/4; word_index = word_index + 1) begin
            word = 0;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                word[(byte_index*8) +: 8] = q_at(word_index*4 + byte_index);
            axi_write_split(16'h0100 + word_index*4, word, word_index % 3);
        end
        axi_read(16'h0100, rd);
        word = 0;
        for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
            word[(byte_index*8) +: 8] = q_at(byte_index);
        if (rd != word) begin
            $display("FAIL Q readback got %08x want %08x", rd, word);
            errors = errors + 1;
        end

        axi_write_split(16'h0008, BASE, 2);
        axi_write_split(16'h001c, 7, 1);
        axi_write_split(16'h0024, 32'h0000_0100, 2);
        axi_write_split(16'h0000, 32'h0000_0001, 3);

        polls = 0; rd = 0;
        while (!rd[1] && !rd[2] && polls < 100) begin
            axi_read(16'h0004, rd); polls = polls + 1;
        end
        if (rd[2]) begin
            axi_read(16'h002c, word);
            $display("FAIL wrapper engine error %02x", word[7:0]);
            errors = errors + 1;
        end else if (!rd[1]) begin
            $display("FAIL wrapper timeout"); errors = errors + 1;
        end

        for (token = 0; token < 7; token = token + 1) begin
            axi_read(16'h1000 + token*4, rd);
            if ($signed(rd) != expected_dot(token)) begin
                $display("FAIL logit %0d got %0d want %0d",
                         token, $signed(rd), expected_dot(token));
                errors = errors + 1;
            end
        end
        axi_read(16'h0000, rd);
        if (!rd[31]) begin
            $display("FAIL CTRL done compatibility bit"); errors = errors + 1;
        end
        axi_write_split(16'h0000, 32'h0000_0002, 1);
        axi_read(16'h0004, rd);
        if (rd[2:1] != 0) begin
            $display("FAIL status clear: %08x", rd); errors = errors + 1;
        end

        if (errors == 0) $display("TB PASS: AXI KV wrapper");
        else $display("TB FAIL: %0d AXI KV wrapper errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
