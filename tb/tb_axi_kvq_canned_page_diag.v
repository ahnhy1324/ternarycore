`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif
`ifndef QK_MULT_STYLE_VAL
`define QK_MULT_STYLE_VAL 2
`endif
`ifndef AV_MULT_STYLE_VAL
`define AV_MULT_STYLE_VAL 2
`endif
`ifndef DECODE_LANES_VAL
`define DECODE_LANES_VAL 4
`endif

module tb_axi_kvq_canned_page_diag;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam integer QK_MULT_STYLE = `QK_MULT_STYLE_VAL;
    localparam integer AV_MULT_STYLE = `AV_MULT_STYLE_VAL;
    localparam integer DECODE_LANES = `DECODE_LANES_VAL;
    localparam [15:0] REG_CTRL       = 16'h0000;
    localparam [15:0] REG_STATUS     = 16'h0004;
    localparam [15:0] REG_CONTEXT    = 16'h0008;
    localparam [15:0] REG_PAGE_DESC  = 16'h000c;
    localparam [15:0] REG_EPOCH      = 16'h0010;
    localparam [15:0] REG_K_TAG_LO   = 16'h0014;
    localparam [15:0] REG_K_TAG_HI   = 16'h0018;
    localparam [15:0] REG_V_TAG_LO   = 16'h001c;
    localparam [15:0] REG_V_TAG_HI   = 16'h0020;
    localparam [15:0] REG_K_WINDOW   = 16'h0024;
    localparam [15:0] REG_V_WINDOW   = 16'h0028;
    localparam [15:0] REG_PAGE_MODES = 16'h002c;
    localparam [15:0] REG_ERROR      = 16'h0030;
    localparam [15:0] REG_K_VALID_DATA_REQ = 16'h004c;
    localparam [15:0] REG_V_VALID_DATA_REQ = 16'h0050;
    localparam [15:0] REG_K_COPY_DATA_REQ = 16'h005c;
    localparam [15:0] REG_V_COPY_DATA_REQ = 16'h0060;
    localparam [15:0] REG_K_P16_REQ  = 16'h006c;
    localparam [15:0] REG_V_P16_REQ  = 16'h0070;
    localparam [15:0] REG_K_SCALE_REQ = 16'h0074;
    localparam [15:0] REG_V_SCALE_REQ = 16'h0078;
    localparam [15:0] REG_K_STARVE   = 16'h007c;
    localparam [15:0] REG_V_STARVE   = 16'h0080;
    localparam [15:0] REG_K_STARVE_HIGH = 16'h0084;
    localparam [15:0] REG_V_STARVE_HIGH = 16'h0088;
    localparam [15:0] REG_SCORE_COUNT = 16'h008c;
    localparam [15:0] REG_RESULT_COUNT = 16'h0090;
    localparam [15:0] REG_RAW_PAGE_COUNT = 16'h0098;
    localparam [15:0] REG_DECODER_FAULTS = 16'h009c;
    localparam [15:0] REG_DENOM0     = 16'h0100;
    localparam [15:0] REG_RECIP0     = 16'h0120;
    localparam [15:0] Q_BASE         = 16'h1000;
    localparam [15:0] K_PAGE_BASE    = 16'h2000;
    localparam [15:0] V_PAGE_BASE    = 16'h5000;
    localparam [15:0] K_SCALE_BASE   = 16'h8000;
    localparam [15:0] V_SCALE_BASE   = 16'h8400;
    localparam [15:0] SCORE_BASE     = 16'h9000;
    localparam [15:0] RESULT_BASE    = 16'ha000;

    localparam [63:0] GOOD_K_TAG =
        {16'h0003, 16'h0007, 16'h0033, 8'h01, 8'h5a};
    localparam [63:0] GOOD_V_TAG =
        {16'h0003, 16'h0007, 16'h0033, 8'h02, 8'h5a};

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg [15:0] s_axi_awaddr;
    reg [2:0] s_axi_awprot;
    reg s_axi_awvalid;
    wire s_axi_awready;
    reg [31:0] s_axi_wdata;
    reg [3:0] s_axi_wstrb;
    reg s_axi_wvalid;
    wire s_axi_wready;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    reg s_axi_bready;
    reg [15:0] s_axi_araddr;
    reg [2:0] s_axi_arprot;
    reg s_axi_arvalid;
    wire s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rvalid;
    reg s_axi_rready;

    axi_kvq_canned_page_diag #(
        .SCALE_BITS(SCALE_BITS), .MAX_CONTEXT(128),
        .COMPILED_PROFILE_ID(16'h0033),
        .COMPILED_K_CODEBOOK_ID(1), .COMPILED_V_CODEBOOK_ID(2),
        .QK_MULT_STYLE(QK_MULT_STYLE),
        .AV_MULT_STYLE(AV_MULT_STYLE),
        .DECODE_LANES(DECODE_LANES),
        .C_S_AXI_DATA_WIDTH(32), .C_S_AXI_ADDR_WIDTH(16)
    ) dut (
        .clk(clk), .rst_n(rst_n), .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready)
    );

    task axi_write;
        input [15:0] address;
        input [31:0] value;
        begin
            @(negedge clk);
            s_axi_awaddr = address;
            s_axi_awvalid = 1'b1;
            s_axi_wdata = value;
            s_axi_wstrb = 4'hf;
            s_axi_wvalid = 1'b1;
            while (!(s_axi_awready && s_axi_wready))
                @(negedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
            s_axi_wvalid = 1'b0;
            while (!s_axi_bvalid)
                @(negedge clk);
            if (s_axi_bresp != 2'b00)
                $fatal(1, "AXI write response error addr=%04x", address);
            @(negedge clk);
        end
    endtask

    task axi_read;
        input [15:0] address;
        output [31:0] value;
        begin
            @(negedge clk);
            s_axi_araddr = address;
            s_axi_arvalid = 1'b1;
            while (!s_axi_arready)
                @(negedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;
            while (!s_axi_rvalid)
                @(negedge clk);
            if (s_axi_rresp != 2'b00)
                $fatal(1, "AXI read response error addr=%04x", address);
            value = s_axi_rdata;
            s_axi_rready = 1'b1;
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    reg [7:0] k_record [0:10255];
    reg [7:0] v_record [0:10255];
    reg [7:0] k_scale_image [0:255];
    reg [7:0] v_scale_image [0:255];
    integer k_payload_bytes, v_payload_bytes;
    integer k_window_bytes, v_window_bytes, scale_bytes;

    function [31:0] crc_byte;
        input [31:0] state;
        input [7:0] value;
        reg [31:0] work;
        integer bit_no;
        begin
            work = state;
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                if (work[0] ^ value[bit_no])
                    work = (work >> 1) ^ 32'hedb8_8320;
                else
                    work = work >> 1;
            end
            crc_byte = work;
        end
    endfunction

    task clear_images;
        integer n;
        begin
            for (n = 0; n < 10256; n = n + 1) begin
                k_record[n] = 8'd0;
                v_record[n] = 8'd0;
            end
            for (n = 0; n < 256; n = n + 1) begin
                k_scale_image[n] = 8'd0;
                v_scale_image[n] = 8'd0;
            end
        end
    endtask

    task build_scale_images;
        integer token, bit_no, position, kval, vval;
        begin
            scale_bytes = (128*SCALE_BITS + 7) / 8;
            for (token = 0; token < 128; token = token + 1) begin
                kval = ((SCALE_BITS == 16) ? 8 : 1) + (token % 3);
                vval = ((SCALE_BITS == 16) ? 9 : 2) + (token % 2);
                for (bit_no = 0; bit_no < SCALE_BITS; bit_no = bit_no + 1) begin
                    position = token*SCALE_BITS + bit_no;
                    if ((kval >> bit_no) & 1)
                        k_scale_image[position/8][position%8] = 1'b1;
                    if ((vval >> bit_no) & 1)
                        v_scale_image[position/8][position%8] = 1'b1;
                end
            end
        end
    endtask

    task stamp_k_crc;
        reg [31:0] work;
        integer n;
        begin
            work = 32'hffff_ffff;
            for (n = 0; n < 8; n = n + 1)
                work = crc_byte(work, k_record[n]);
            for (n = 0; n < k_payload_bytes; n = n + 1)
                work = crc_byte(work, k_record[12+n]);
            for (n = 0; n < scale_bytes; n = n + 1)
                work = crc_byte(work, k_scale_image[n]);
            work = work ^ 32'hffff_ffff;
            k_record[8] = work[7:0];
            k_record[9] = work[15:8];
            k_record[10] = work[23:16];
            k_record[11] = work[31:24];
        end
    endtask

    task stamp_v_crc;
        reg [31:0] work;
        integer n;
        begin
            work = 32'hffff_ffff;
            for (n = 0; n < 8; n = n + 1)
                work = crc_byte(work, v_record[n]);
            for (n = 0; n < v_payload_bytes; n = n + 1)
                work = crc_byte(work, v_record[12+n]);
            for (n = 0; n < scale_bytes; n = n + 1)
                work = crc_byte(work, v_scale_image[n]);
            work = work ^ 32'hffff_ffff;
            v_record[8] = work[7:0];
            v_record[9] = work[15:8];
            v_record[10] = work[23:16];
            v_record[11] = work[31:24];
        end
    endtask

    task build_pages;
        input integer raw_mode;
        input integer truncate_k;
        input integer wrong_k_codebook;
        input integer corrupt_k_crc;
        integer symbol_no, bit_no, position, n;
        begin
            clear_images();
            build_scale_images();
            if (truncate_k != 0) begin
                k_payload_bytes = 1;
                k_record[12] = 8'h00;
            end else if (raw_mode != 0) begin
                k_payload_bytes = 8192;
                for (n = 0; n < k_payload_bytes; n = n + 1)
                    k_record[12+n] = 8'h11;
            end else begin
                // K=+1 uses MSB-first prefix 110, exactly 6144 bytes.
                k_payload_bytes = 6144;
                for (symbol_no = 0; symbol_no < 16384;
                     symbol_no = symbol_no + 1) begin
                    position = symbol_no*3;
                    k_record[12 + position/8][7-(position%8)] = 1'b1;
                    position = position + 1;
                    k_record[12 + position/8][7-(position%8)] = 1'b1;
                end
            end

            if (raw_mode != 0) begin
                // V=+5 as the raw little-bit reservoir.
                v_payload_bytes = 10240;
                for (symbol_no = 0; symbol_no < 16384;
                     symbol_no = symbol_no + 1) begin
                    for (bit_no = 0; bit_no < 5; bit_no = bit_no + 1) begin
                        position = symbol_no*5 + bit_no;
                        if ((5 >> bit_no) & 1)
                            v_record[12 + position/8][position%8] = 1'b1;
                    end
                end
            end else begin
                // V=+5 is compressed prefix 0000.
                v_payload_bytes = 8192;
            end

            k_record[0] = 8'h03;
            k_record[1] = 8'hc3;
            k_record[2] = raw_mode ? 8'h01 : 8'h00;
            k_record[3] = 8'h7f;
            k_record[4] = k_payload_bytes[7:0];
            k_record[5] = k_payload_bytes[15:8];
            k_record[6] = wrong_k_codebook ? 8'h7f : 8'h01;
            k_record[7] = (SCALE_BITS == 12) ? 8'h01 : 8'h02;

            v_record[0] = 8'h03;
            v_record[1] = 8'hc3;
            v_record[2] = raw_mode ? 8'h03 : 8'h02;
            v_record[3] = 8'h7f;
            v_record[4] = v_payload_bytes[7:0];
            v_record[5] = v_payload_bytes[15:8];
            v_record[6] = 8'h02;
            v_record[7] = (SCALE_BITS == 12) ? 8'h01 : 8'h02;

            k_window_bytes = ((12 + k_payload_bytes + 15) / 16) * 16;
            v_window_bytes = ((12 + v_payload_bytes + 15) / 16) * 16;
            stamp_k_crc();
            stamp_v_crc();
            if (corrupt_k_crc != 0)
                k_record[8] = k_record[8] ^ 8'h01;
        end
    endtask

    task load_queries;
        integer word_no, lane, index, row, dim, qvalue;
        reg [31:0] word_value;
        begin
            for (word_no = 0; word_no < 128; word_no = word_no + 1) begin
                word_value = 32'd0;
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    index = word_no*4 + lane;
                    row = index / 128;
                    dim = index % 128;
                    qvalue = ((row*13 + dim*5) % 23) - 11;
                    word_value[(lane*8) +: 8] = qvalue;
                end
                axi_write(Q_BASE + word_no*4, word_value);
            end
        end
    endtask

    task configure_good_tags;
        begin
            axi_write(REG_CONTEXT, 32'd128);
            axi_write(REG_PAGE_DESC, 32'h0000_0100);
            axi_write(REG_EPOCH, 32'h0000_1234);
            axi_write(REG_K_TAG_LO, GOOD_K_TAG[31:0]);
            axi_write(REG_K_TAG_HI, GOOD_K_TAG[63:32]);
            axi_write(REG_V_TAG_LO, GOOD_V_TAG[31:0]);
            axi_write(REG_V_TAG_HI, GOOD_V_TAG[63:32]);
        end
    endtask

    task load_current_images;
        input integer raw_mode;
        integer word_no, byte_base;
        reg [31:0] word_value;
        begin
            axi_write(REG_K_WINDOW, k_window_bytes);
            axi_write(REG_V_WINDOW, v_window_bytes);
            axi_write(REG_PAGE_MODES, raw_mode ? 32'h3 : 32'h0);
            for (word_no = 0; word_no < k_window_bytes/4;
                 word_no = word_no + 1) begin
                byte_base = word_no*4;
                word_value = {k_record[byte_base+3], k_record[byte_base+2],
                              k_record[byte_base+1], k_record[byte_base]};
                axi_write(K_PAGE_BASE + word_no*4, word_value);
            end
            for (word_no = 0; word_no < v_window_bytes/4;
                 word_no = word_no + 1) begin
                byte_base = word_no*4;
                word_value = {v_record[byte_base+3], v_record[byte_base+2],
                              v_record[byte_base+1], v_record[byte_base]};
                axi_write(V_PAGE_BASE + word_no*4, word_value);
            end
            for (word_no = 0; word_no < (scale_bytes+3)/4;
                 word_no = word_no + 1) begin
                byte_base = word_no*4;
                word_value = {k_scale_image[byte_base+3],
                              k_scale_image[byte_base+2],
                              k_scale_image[byte_base+1],
                              k_scale_image[byte_base]};
                axi_write(K_SCALE_BASE + word_no*4, word_value);
                word_value = {v_scale_image[byte_base+3],
                              v_scale_image[byte_base+2],
                              v_scale_image[byte_base+1],
                              v_scale_image[byte_base]};
                axi_write(V_SCALE_BASE + word_no*4, word_value);
            end
        end
    endtask

    task wait_success;
        integer watchdog;
        reg [31:0] status;
        begin
            watchdog = 0;
            status = 0;
            while (!status[2] && !status[3] && watchdog < 500000) begin
                repeat (100) @(posedge clk);
                axi_read(REG_STATUS, status);
                watchdog = watchdog + 100;
            end
            if (!status[2] || status[3] || !status[5]) begin
                axi_read(REG_ERROR, status);
                $fatal(1, "expected success, status/error=%08x state=%0d",
                       status, dut.state);
            end
        end
    endtask

    task wait_fault;
        input [7:0] expected_code;
        integer watchdog;
        reg [31:0] status;
        reg [31:0] error_word;
        begin
            watchdog = 0;
            status = 0;
            while (!(status[3] && status[12]) && watchdog < 300000) begin
                repeat (20) @(posedge clk);
                axi_read(REG_STATUS, status);
                watchdog = watchdog + 20;
            end
            if (!(status[3] && status[12]))
                $fatal(1, "fault/clear-ready timeout status=%08x state=%0d",
                       status, dut.state);
            axi_read(REG_ERROR, error_word);
            if (error_word[7:0] != expected_code)
                $fatal(1, "fault code=%02x expected=%02x word=%08x",
                       error_word[7:0], expected_code, error_word);
            if (status[5])
                $fatal(1, "fault left result window visible");
        end
    endtask

    task clear_diag;
        reg [31:0] status;
        begin
            axi_write(REG_CTRL, 32'h2);
            axi_read(REG_STATUS, status);
            if (status[5] || status[3] || status[2])
                $fatal(1, "CLEAR did not hide/clear status=%08x", status);
        end
    endtask

    reg [16:0] score_reference [0:511];
    reg [47:0] numerator_reference [0:511];
    reg [18:0] normalized_reference [0:511];
    reg [27:0] denominator_reference [0:3];
    reg [17:0] reciprocal_reference [0:3];
    integer nonzero_scores, nonzero_numerators;
    integer late_av_abort_watchdog;

    task collect_or_compare_results;
        input integer compare_mode;
        integer n;
        reg [31:0] word0, word1, word2;
        reg [16:0] score_value;
        reg [47:0] numerator_value;
        reg [18:0] normalized_value;
        begin
            nonzero_scores = 0;
            nonzero_numerators = 0;
            for (n = 0; n < 512; n = n + 1) begin
                axi_read(SCORE_BASE + n*4, word0);
                score_value = word0[16:0];
                if (score_value[15:0] != 0)
                    nonzero_scores = nonzero_scores + 1;
                if (compare_mode == 0)
                    score_reference[n] = score_value;
                else if (score_value !== score_reference[n])
                    $fatal(1, "score window mismatch n=%0d", n);

                axi_read(RESULT_BASE + n*12, word0);
                axi_read(RESULT_BASE + n*12 + 4, word1);
                axi_read(RESULT_BASE + n*12 + 8, word2);
                numerator_value = {word1[15:0], word0};
                normalized_value = {word2[18], word2[17:0]};
                if (numerator_value != 0)
                    nonzero_numerators = nonzero_numerators + 1;
                if (compare_mode == 0) begin
                    numerator_reference[n] = numerator_value;
                    normalized_reference[n] = normalized_value;
                end else if (numerator_value !== numerator_reference[n] ||
                             normalized_value !== normalized_reference[n])
                    $fatal(1, "AV window mismatch n=%0d", n);
            end
            for (n = 0; n < 4; n = n + 1) begin
                axi_read(REG_DENOM0 + n*4, word0);
                axi_read(REG_RECIP0 + n*4, word1);
                if (compare_mode == 0) begin
                    denominator_reference[n] = word0[27:0];
                    reciprocal_reference[n] = word1[17:0];
                end else if (word0[27:0] !== denominator_reference[n] ||
                             word1[17:0] !== reciprocal_reference[n])
                    $fatal(1, "softmax summary mismatch row=%0d", n);
            end
            if (nonzero_scores == 0 || nonzero_numerators == 0)
                $fatal(1, "equivalence fixture was arithmetically trivial");
        end
    endtask

    task check_counters;
        input integer raw_mode;
        reg [31:0] value;
        begin
            axi_read(REG_K_VALID_DATA_REQ, value);
            if (value == 0) $fatal(1, "K validator counter zero");
            axi_read(REG_V_VALID_DATA_REQ, value);
            if (value == 0) $fatal(1, "V validator counter zero");
            axi_read(REG_K_COPY_DATA_REQ, value);
            if (value == 0) $fatal(1, "K copy counter zero");
            axi_read(REG_V_COPY_DATA_REQ, value);
            if (value == 0) $fatal(1, "V copy counter zero");
            axi_read(REG_K_P16_REQ, value);
            if (value != 4096) $fatal(1, "K P16 requests=%0d", value);
            axi_read(REG_V_P16_REQ, value);
            if (value != 4096) $fatal(1, "V P16 requests=%0d", value);
            axi_read(REG_K_SCALE_REQ, value);
            if (value != 128) $fatal(1, "K scale requests=%0d", value);
            axi_read(REG_V_SCALE_REQ, value);
            if (value != 128) $fatal(1, "V scale requests=%0d", value);
            axi_read(REG_K_STARVE, value);
            if (value == 0) $fatal(1, "K starvation counter zero");
            axi_read(REG_V_STARVE, value);
            if (value == 0) $fatal(1, "V starvation counter zero");
            axi_read(REG_K_STARVE_HIGH, value);
            if (value == 0) $fatal(1, "K starvation high-water zero");
            axi_read(REG_V_STARVE_HIGH, value);
            if (value == 0) $fatal(1, "V starvation high-water zero");
            axi_read(REG_SCORE_COUNT, value);
            if (value != 512) $fatal(1, "score count=%0d", value);
            axi_read(REG_RESULT_COUNT, value);
            if (value != 512) $fatal(1, "result count=%0d", value);
            axi_read(REG_RAW_PAGE_COUNT, value);
            if (value != (raw_mode ? 2 : 0))
                $fatal(1, "raw page count=%0d raw=%0d", value, raw_mode);
        end
    endtask

    reg [31:0] read_value;
    initial begin
        s_axi_awaddr = 16'd0;
        s_axi_awprot = 3'd0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata = 32'd0;
        s_axi_wstrb = 4'd0;
        s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b1;
        s_axi_araddr = 16'd0;
        s_axi_arprot = 3'd0;
        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;

        load_queries();
        configure_good_tags();

        // Full raw context128 through CRC validation, real lane decode, and
        // the complete arithmetic chain.
        build_pages(1, 0, 0, 0);
        load_current_images(1);
        axi_read(SCORE_BASE, read_value);
        if (read_value != 0) $fatal(1, "score visible before start");
        axi_write(REG_CTRL, 32'h8);
        axi_write(REG_CTRL, 32'h1);
        while (dut.state != 5)
            @(posedge clk);
        axi_read(RESULT_BASE, read_value);
        if (read_value != 0) $fatal(1, "result visible before commit");
        wait_success();
        collect_or_compare_results(0);
        check_counters(1);

        clear_diag();
        axi_read(SCORE_BASE, read_value);
        if (read_value != 0) $fatal(1, "score visible after CLEAR");
        axi_read(RESULT_BASE, read_value);
        if (read_value != 0) $fatal(1, "result visible after CLEAR");

        // Compressed K=+1/V=+5 values and identical scale bytes must reproduce
        // every score, softmax summary, numerator, and normalized result.
        build_pages(0, 0, 0, 0);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h8);
        axi_write(REG_CTRL, 32'h1);
        wait_success();
        collect_or_compare_results(1);
        check_counters(0);
        clear_diag();

        // Profile mismatch reaches the typed lane descriptor gate.
        axi_write(REG_K_TAG_LO,
            {16'h0034, 8'h01, 8'h5a});
        axi_write(REG_CTRL, 32'h1);
        wait_fault(8'h03);
        axi_read(RESULT_BASE, read_value);
        if (read_value != 0) $fatal(1, "profile fault exposed result");
        clear_diag();
        axi_write(REG_K_TAG_LO, GOOD_K_TAG[31:0]);

        // Header codebook mismatch is CRC-correct but validator-rejected.
        build_pages(0, 0, 1, 0);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h1);
        wait_fault(8'h02);
        clear_diag();

        // Explicit CRC corruption never reaches decode/arithmetic.
        build_pages(0, 0, 0, 1);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h1);
        wait_fault(8'h02);
        clear_diag();

        // CRC-approved but truncated compressed K payload produces a real
        // decoder fault and fail-closed result window.
        build_pages(0, 1, 0, 0);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h1);
        wait_fault(8'h03);
        axi_read(REG_DECODER_FAULTS, read_value);
        if (read_value == 0) $fatal(1, "decoder fault counter zero");
        axi_read(SCORE_BASE, read_value);
        if (read_value != 0) $fatal(1, "decoder fault exposed score");
        clear_diag();

        // Abort while the full pages are decoding.  All accepted scratch
        // reads drain, CLEAR succeeds, and the exact same loaded images rerun
        // without reset or query reload.
        build_pages(0, 0, 0, 0);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h1);
        while (dut.state != 3 || !(dut.k_lane_busy || dut.v_lane_busy))
            @(posedge clk);
        repeat (20) @(posedge clk);
        axi_write(REG_CTRL, 32'h4);
        wait_fault(8'h05);
        axi_read(RESULT_BASE, read_value);
        if (read_value != 0) $fatal(1, "abort exposed result");
        clear_diag();
        axi_write(REG_CTRL, 32'h8);
        axi_write(REG_CTRL, 32'h1);
        wait_success();
        collect_or_compare_results(1);
        check_counters(0);

        // Reproduce the late arithmetic abort window observed through XSDB
        // on Zybo.  This exercises wrapper + both lane banks + arithmetic
        // ownership together, rather than the earlier decode-only abort.
        clear_diag();
        build_pages(0, 0, 0, 0);
        load_current_images(0);
        axi_write(REG_CTRL, 32'h1);
        late_av_abort_watchdog = 0;
        while ((dut.state != 5 || dut.arith_progress_state != 17 ||
                dut.arith_progress_token != 48 ||
                dut.arith_progress_head != 3 ||
                dut.arith_progress_group != 7) &&
               late_av_abort_watchdog < 3000000) begin
            @(posedge clk);
            late_av_abort_watchdog = late_av_abort_watchdog + 1;
        end
        if (late_av_abort_watchdog == 3000000)
            $fatal(1, "late wrapper AV abort window timeout top=%0d arith=%0d token=%0d head=%0d group=%0d",
                   dut.state, dut.arith_progress_state,
                   dut.arith_progress_token, dut.arith_progress_head,
                   dut.arith_progress_group);
        // Hit the same edge that accepts the synchronous lane scratch read.
        // A normal AXI write cannot deterministically select this one-cycle
        // window in simulation, so force only the decoded control pulse.
        @(negedge clk);
        force dut.ctrl_abort = 1'b1;
        @(posedge clk);
        @(negedge clk);
        release dut.ctrl_abort;
        wait_fault(8'h05);
        axi_read(RESULT_BASE, read_value);
        if (read_value != 0)
            $fatal(1, "late arithmetic abort exposed result");
        clear_diag();
        axi_write(REG_CTRL, 32'h8);
        axi_write(REG_CTRL, 32'h1);
        wait_success();
        collect_or_compare_results(1);
        check_counters(0);

        // A shorter context commits fewer than 512 score entries.  Prove the
        // score window hides every stale tail entry even when the backing
        // BRAM still contains a value from this preceding context128 run.
        // The physical-board context7 fixture exercises the same boundary at
        // index 28; forcing only the committed count isolates the MMIO rule.
        @(negedge clk);
        force dut.stored_score_count = 10'd28;
        axi_read(SCORE_BASE + 28*4, read_value);
        if (read_value != 0)
            $fatal(1, "short-context score tail exposed value=%08x",
                   read_value);
        release dut.stored_score_count;

        if (SCALE_BITS == 12)
            $display("AXI_KVQ_CANNED_PAGE_DIAG_SCALE12_PASS");
        else
            $display("AXI_KVQ_CANNED_PAGE_DIAG_SCALE16_PASS");
        $display("AXI_KVQ_CANNED_PAGE_DIAG_PROFILE_PASS QK=%0d AV=%0d",
                 QK_MULT_STYLE, AV_MULT_STYLE);
        $display("AXI_KVQ_CANNED_PAGE_DIAG_LANES_PASS LANES=%0d",
                 DECODE_LANES);
        $finish;
    end

    initial begin
        #500000000;
        $fatal(1, "axi canned page diag global timeout scale=%0d",
               SCALE_BITS);
    end
endmodule

`default_nettype wire
