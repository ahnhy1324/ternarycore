// tb_axi_kvq_raw_attention_diag.v -- AXI wrapper proof for raw attention.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_axi_kvq_raw_attention_diag;
`ifdef SCALE_WIDTH_VAL
    localparam integer SCALE_WIDTH = `SCALE_WIDTH_VAL;
`else
    localparam integer SCALE_WIDTH = 12;
`endif
`ifdef AXI_DATA_WIDTH_VAL
    localparam integer AXI_WIDTH = `AXI_DATA_WIDTH_VAL;
`else
    localparam integer AXI_WIDTH = 64;
`endif

    localparam integer AXI_BYTES = AXI_WIDTH / 8;
    localparam integer AXI_SIZE = $clog2(AXI_BYTES);
    localparam integer MAX_CONTEXT = 128;
    localparam integer CONTEXT_LEN = 2;
    localparam integer EXPECTED_READ_BEATS = CONTEXT_LEN * (80 / AXI_BYTES);
    localparam [31:0] V_BASE = 32'h0200_0000;
    localparam [15:0] REG_CTRL        = 16'h0000;
    localparam [15:0] REG_STATUS      = 16'h0004;
    localparam [15:0] REG_V_BASE_LO   = 16'h0008;
    localparam [15:0] REG_V_BASE_HI   = 16'h000c;
    localparam [15:0] REG_CONTEXT     = 16'h0010;
    localparam [15:0] REG_SCORE_COUNT = 16'h0014;
    localparam [15:0] REG_SCALE_COUNT = 16'h0018;
    localparam [15:0] REG_ERROR       = 16'h001c;
    localparam [15:0] REG_PERF        = 16'h0020;
    localparam [15:0] REG_READ_BEATS  = 16'h0024;
    localparam [15:0] REG_AR_STALLS   = 16'h0028;
    localparam [15:0] REG_R_STALLS    = 16'h002c;
    localparam [15:0] REG_ID          = 16'h0030;
    localparam [15:0] REG_GEOMETRY    = 16'h0034;
    localparam [15:0] REG_SCALE_FMT   = 16'h0038;
    localparam [15:0] REG_SAT_COUNT   = 16'h003c;
    localparam [15:0] REG_DENOM0      = 16'h0040;
    localparam [15:0] REG_RECIP0      = 16'h0050;
    localparam [15:0] SCORE_BASE      = 16'h1000;
    localparam [15:0] SCALE_BASE      = 16'h2000;
    localparam [15:0] RESULT_BASE     = 16'h4000;
    localparam [7:0] ERR_COUNTS       = 8'h21;
    localparam [7:0] ERR_SCALE_FORMAT = 8'h22;
    localparam [7:0] ERR_CTRL         = 8'h82;
    localparam [7:0] ERR_BUSY_WRITE   = 8'h83;
    localparam [SCALE_WIDTH-1:0] UNIT_SCALE =
        (SCALE_WIDTH == 12) ? 12'd256 : 16'd2048;
    localparam signed [47:0] EXPECTED_NUMERATOR =
        (SCALE_WIDTH == 12) ? 48'sd33554432 : 48'sd268435456;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [15:0] s_axi_awaddr = 16'd0;
    reg  [2:0]  s_axi_awprot = 3'd0;
    reg         s_axi_awvalid = 1'b0;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata = 32'd0;
    reg  [3:0]  s_axi_wstrb = 4'd0;
    reg         s_axi_wvalid = 1'b0;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready = 1'b0;
    reg  [15:0] s_axi_araddr = 16'd0;
    reg  [2:0]  s_axi_arprot = 3'd0;
    reg         s_axi_arvalid = 1'b0;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready = 1'b0;

    wire [0:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    reg  m_axi_arready;
    reg  [0:0] m_axi_rid = 1'b0;
    reg  [AXI_WIDTH-1:0] m_axi_rdata;
    reg  [1:0] m_axi_rresp = 2'b00;
    reg  m_axi_rlast;
    reg  m_axi_rvalid;
    wire m_axi_rready;

    axi_kvq_raw_attention_diag #(
        .MAX_CONTEXT(MAX_CONTEXT), .SCALE_WIDTH(SCALE_WIDTH),
        .MULT_STYLE(2), .M_AXI_DATA_WIDTH(AXI_WIDTH),
        .TIMEOUT_CYCLES(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    reg [7:0] vmem [0:159];
    reg response_active = 1'b0;
    reg [31:0] response_addr = 32'd0;
    reg [8:0] response_beats_left = 9'd0;
    integer errors = 0;
    integer write_sequence = 0;
    integer model_ar_count = 0;
    integer model_read_beats = 0;
    integer byte_lane;
    integer byte_offset;
    integer index;

    task set_token_code;
        input integer token;
        input [4:0] code;
        integer dimension;
        integer bit_index;
        integer absolute_bit;
        integer byte_index;
        integer bit_in_byte;
        begin
            for (dimension = 0; dimension < 128;
                 dimension = dimension + 1)
                for (bit_index = 0; bit_index < 5;
                     bit_index = bit_index + 1) begin
                    absolute_bit = dimension*5 + bit_index;
                    byte_index = token*80 + absolute_bit/8;
                    bit_in_byte = absolute_bit % 8;
                    if (code[bit_index])
                        vmem[byte_index] = vmem[byte_index] |
                                           (8'b1 << bit_in_byte);
                end
        end
    endtask

    always @* begin
        m_axi_arready = !response_active;
        m_axi_rvalid = response_active;
        m_axi_rlast = response_active && response_beats_left == 1;
        m_axi_rdata = {AXI_WIDTH{1'b0}};
        if (response_active) begin
            for (byte_lane = 0; byte_lane < AXI_BYTES;
                 byte_lane = byte_lane + 1) begin
                byte_offset = (response_addr - V_BASE) + byte_lane;
                if (byte_offset >= 0 && byte_offset < 160)
                    m_axi_rdata[byte_lane*8 +: 8] = vmem[byte_offset];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            response_active <= 1'b0;
            response_addr <= 32'd0;
            response_beats_left <= 9'd0;
            model_ar_count <= 0;
            model_read_beats <= 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_arid !== 0 || m_axi_arsize !== AXI_SIZE ||
                    m_axi_arburst !== 2'b01 || m_axi_arlock !== 1'b0 ||
                    m_axi_araddr < V_BASE || m_axi_araddr >= V_BASE+160 ||
                    ((m_axi_araddr - V_BASE) % 80) != 0) begin
                    $display("FAIL DDR command addr=%08x len=%0d size=%0d",
                             m_axi_araddr, m_axi_arlen, m_axi_arsize);
                    errors = errors + 1;
                end
                if ((m_axi_arlen + 1) != (80 / AXI_BYTES)) begin
                    $display("FAIL DDR burst length got=%0d want=%0d",
                             m_axi_arlen + 1, 80 / AXI_BYTES);
                    errors = errors + 1;
                end
                response_active <= 1'b1;
                response_addr <= m_axi_araddr;
                response_beats_left <= m_axi_arlen + 1'b1;
                model_ar_count <= model_ar_count + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                model_read_beats <= model_read_beats + 1;
                if (response_beats_left == 1) begin
                    response_active <= 1'b0;
                    response_beats_left <= 9'd0;
                end else begin
                    response_addr <= response_addr + AXI_BYTES;
                    response_beats_left <= response_beats_left - 1'b1;
                end
            end
        end
    end

    task send_aw;
        input [15:0] addr;
        integer guard;
        begin
            @(negedge clk);
            s_axi_awaddr = addr;
            s_axi_awvalid = 1'b1;
            guard = 0;
            while (!s_axi_awready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_awready)
                $fatal(1, "AXI-Lite AW timeout addr=%04x", addr);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task send_w;
        input [31:0] data;
        input [3:0] strobe;
        integer guard;
        begin
            @(negedge clk);
            s_axi_wdata = data;
            s_axi_wstrb = strobe;
            s_axi_wvalid = 1'b1;
            guard = 0;
            while (!s_axi_wready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_wready)
                $fatal(1, "AXI-Lite W timeout data=%08x", data);
            @(posedge clk);
            @(negedge clk);
            s_axi_wvalid = 1'b0;
            s_axi_wstrb = 4'd0;
        end
    endtask

    task axi_write;
        input [15:0] addr;
        input [31:0] data;
        integer guard;
        begin
            // Alternate truly split AW-first and W-first transactions.
            if ((write_sequence & 1) == 0) begin
                send_aw(addr);
                repeat ((write_sequence % 3) + 1) @(negedge clk);
                send_w(data, 4'hf);
            end else begin
                send_w(data, 4'hf);
                repeat ((write_sequence % 3) + 1) @(negedge clk);
                send_aw(addr);
            end
            write_sequence = write_sequence + 1;
            @(negedge clk);
            s_axi_bready = 1'b1;
            guard = 0;
            while (!s_axi_bvalid && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_bvalid)
                $fatal(1, "AXI-Lite B timeout addr=%04x", addr);
            if (s_axi_bresp !== 2'b00) begin
                $display("FAIL AXI-Lite BRESP addr=%04x resp=%0d",
                         addr, s_axi_bresp);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_write_strobe;
        input [15:0] addr;
        input [31:0] data;
        input [3:0] strobe;
        integer guard;
        begin
            if ((write_sequence & 1) == 0) begin
                send_aw(addr);
                repeat ((write_sequence % 3) + 1) @(negedge clk);
                send_w(data, strobe);
            end else begin
                send_w(data, strobe);
                repeat ((write_sequence % 3) + 1) @(negedge clk);
                send_aw(addr);
            end
            write_sequence = write_sequence + 1;
            @(negedge clk);
            s_axi_bready = 1'b1;
            guard = 0;
            while (!s_axi_bvalid && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_bvalid)
                $fatal(1, "AXI-Lite B timeout addr=%04x", addr);
            if (s_axi_bresp !== 2'b00) begin
                $display("FAIL AXI-Lite BRESP addr=%04x resp=%0d",
                         addr, s_axi_bresp);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_read;
        input [15:0] addr;
        output [31:0] data;
        integer guard;
        begin
            @(negedge clk);
            s_axi_araddr = addr;
            s_axi_arvalid = 1'b1;
            guard = 0;
            while (!s_axi_arready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_arready)
                $fatal(1, "AXI-Lite AR timeout addr=%04x", addr);
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;
            repeat ((addr[3:2] & 2'b01) + 1) @(negedge clk);
            s_axi_rready = 1'b1;
            guard = 0;
            while (!s_axi_rvalid && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_rvalid)
                $fatal(1, "AXI-Lite R timeout addr=%04x", addr);
            #1 data = s_axi_rdata;
            if (s_axi_rresp !== 2'b00) begin
                $display("FAIL AXI-Lite RRESP addr=%04x resp=%0d",
                         addr, s_axi_rresp);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    task expect_reg;
        input [15:0] addr;
        input [31:0] wanted;
        input string label_text;
        reg [31:0] got;
        begin
            axi_read(addr, got);
            if (got !== wanted) begin
                $display("FAIL %s got=%08x want=%08x",
                         label_text, got, wanted);
                errors = errors + 1;
            end
        end
    endtask

    task wait_terminal;
        output [31:0] status;
        integer polls;
        begin
            status = 32'd0;
            polls = 0;
            while (polls < 200000) begin
                axi_read(REG_STATUS, status);
                if (!status[0] && (status[1] || status[2] || status[3]))
                    polls = 200000;
                else
                    polls = polls + 1;
            end
            if (status[0] || !(status[1] || status[2] || status[3]))
                $fatal(1, "diagnostic completion timeout status=%08x", status);
        end
    endtask

    task start_and_wait_success;
        input string label_text;
        reg [31:0] status;
        begin
            model_ar_count = 0;
            model_read_beats = 0;
            axi_write(REG_CTRL, 32'h0000_0001);
            wait_terminal(status);
            if (status !== 32'h0000_0012) begin
                $display("FAIL %s status=%08x want=00000012",
                         label_text, status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, 32'd0, "successful run error code");
        end
    endtask

    task check_summary;
        integer head;
        reg [31:0] value;
        begin
            axi_read(REG_PERF, value);
            if (value == 0) begin
                $display("FAIL performance counter is zero");
                errors = errors + 1;
            end
            expect_reg(REG_READ_BEATS, EXPECTED_READ_BEATS,
                       "read beat counter");
            expect_reg(REG_AR_STALLS, 32'd0, "AR stall counter");
            expect_reg(REG_R_STALLS, 32'd0, "R stall counter");
            expect_reg(REG_SAT_COUNT, 32'd0, "saturation counter");
            if (model_ar_count != CONTEXT_LEN ||
                model_read_beats != EXPECTED_READ_BEATS) begin
                $display("FAIL DDR model counters ar=%0d beats=%0d want=%0d/%0d",
                         model_ar_count, model_read_beats, CONTEXT_LEN,
                         EXPECTED_READ_BEATS);
                errors = errors + 1;
            end
            for (head = 0; head < 4; head = head + 1) begin
                expect_reg(REG_DENOM0 + head*4, 32'd65536,
                           "softmax denominator");
                expect_reg(REG_RECIP0 + head*4,
                           {14'd0, 5'd16, 13'd4096},
                           "softmax reciprocal");
            end
        end
    endtask

    task check_all_results;
        input string label_text;
        integer result_index;
        reg [31:0] low_word;
        reg [31:0] high_word;
        reg [31:0] code_word;
        reg signed [47:0] reconstructed;
        begin
            for (result_index = 0; result_index < 512;
                 result_index = result_index + 1) begin
                axi_read(RESULT_BASE + result_index*16, low_word);
                axi_read(RESULT_BASE + result_index*16 + 4, high_word);
                axi_read(RESULT_BASE + result_index*16 + 8, code_word);
                reconstructed = {high_word[15:0], low_word};
                if ($signed(reconstructed) !== EXPECTED_NUMERATOR ||
                    high_word[31:16] !==
                        {16{EXPECTED_NUMERATOR[47]}} ||
                    code_word !== 32'd512) begin
                    if (errors < 20)
                        $display("FAIL %s result[%0d] num=%0d high=%08x code=%08x",
                                 label_text, result_index,
                                 $signed(reconstructed), high_word, code_word);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task expect_results_hidden;
        input string label_text;
        integer result_index;
        reg [31:0] low_word;
        reg [31:0] high_word;
        reg [31:0] code_word;
        begin
            for (result_index = 0; result_index < 512;
                 result_index = result_index + 1) begin
                axi_read(RESULT_BASE + result_index*16, low_word);
                axi_read(RESULT_BASE + result_index*16 + 4, high_word);
                axi_read(RESULT_BASE + result_index*16 + 8, code_word);
                if (low_word !== 0 || high_word !== 0 || code_word !== 0) begin
                    if (errors < 20)
                        $display("FAIL %s exposed result[%0d]=%08x/%08x/%08x",
                                 label_text, result_index, low_word,
                                 high_word, code_word);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task program_inputs;
        integer row;
        integer token;
        begin
            axi_write(REG_V_BASE_LO, V_BASE);
            axi_write(REG_V_BASE_HI, 32'd0);
            axi_write(REG_CONTEXT, CONTEXT_LEN);
            for (row = 0; row < 4; row = row + 1)
                for (token = 0; token < CONTEXT_LEN;
                     token = token + 1)
                    axi_write(SCORE_BASE +
                              ((row*MAX_CONTEXT + token)*4), 32'd0);
            for (token = 0; token < CONTEXT_LEN; token = token + 1)
                axi_write(SCALE_BASE + token*4, UNIT_SCALE);
            axi_write(REG_SCORE_COUNT, CONTEXT_LEN*4);
            axi_write(REG_SCALE_COUNT, CONTEXT_LEN);
            expect_reg(REG_CONTEXT, CONTEXT_LEN, "context count");
            expect_reg(REG_SCORE_COUNT, CONTEXT_LEN*4, "score count");
            expect_reg(REG_SCALE_COUNT, CONTEXT_LEN, "scale count");
        end
    endtask

    task expect_bad_count;
        reg [31:0] status;
        begin
            axi_write(REG_SCORE_COUNT, CONTEXT_LEN*4 - 1);
            axi_write(REG_CTRL, 32'h0000_0001);
            wait_terminal(status);
            if (status !== 32'h0000_0004) begin
                $display("FAIL bad-count status=%08x want=00000004", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, ERR_COUNTS}, "bad-count code");
            expect_results_hidden("bad-count");
            axi_write(REG_CTRL, 32'h0000_0002);
            axi_write(REG_SCORE_COUNT, CONTEXT_LEN*4);
        end
    endtask

    task check_scale_format_guard;
        reg [31:0] status;
        begin
            if (SCALE_WIDTH == 12) begin
                axi_write(SCALE_BASE, 32'h0000_f100);
                axi_read(REG_STATUS, status);
                if (status !== 32'h0000_0004) begin
                    $display("FAIL scale-format status=%08x want=00000004",
                             status);
                    errors = errors + 1;
                end
                expect_reg(REG_ERROR, {24'd0, ERR_SCALE_FORMAT},
                           "scale-format code");
                expect_results_hidden("scale-format");
                axi_write(REG_CTRL, 32'h0000_0002);
                axi_write(SCALE_BASE, UNIT_SCALE);
            end else begin
                // UQ5.11 consumes all 16 bits, so the same payload is legal.
                axi_write(SCALE_BASE, 32'h0000_f100);
                expect_reg(REG_STATUS, 32'd0,
                           "UQ5.11 full-width scale acceptance");
                axi_write(SCALE_BASE, UNIT_SCALE);
            end
        end
    endtask

    task abort_and_restart;
        reg [31:0] status;
        reg [31:0] first_result;
        begin
            // Establish visible committed data, then START invalidates it.
            start_and_wait_success("pre-abort run");
            axi_read(RESULT_BASE, first_result);
            if (first_result !== EXPECTED_NUMERATOR[31:0]) begin
                $display("FAIL pre-abort visible result=%08x", first_result);
                errors = errors + 1;
            end

            axi_write(REG_CTRL, 32'h0000_0001);
            axi_read(REG_STATUS, status);
            if (!status[0] || status[4]) begin
                $display("FAIL abort setup status=%08x", status);
                errors = errors + 1;
            end
            repeat (20) @(negedge clk);
            axi_write(REG_CTRL, 32'h0000_0004);
            wait_terminal(status);
            if (status !== 32'h0000_0008) begin
                $display("FAIL aborted status=%08x want=00000008", status);
                errors = errors + 1;
            end
            expect_results_hidden("aborted run stale-result guard");

            // No reset and no reload: START must clear abort and complete.
            start_and_wait_success("no-reset restart");
            check_summary();
            check_all_results("no-reset restart");
        end
    endtask

    task check_write_guards;
        reg [31:0] status;
        integer polls;
        begin
            // Any configuration mutation invalidates a previously committed
            // result even when the value itself is unchanged.
            axi_write(REG_CONTEXT, CONTEXT_LEN);
            expect_results_hidden("config-write invalidation");
            start_and_wait_success("config-write restart");

            // Score and scale memories require a complete 32-bit AXI-Lite
            // write.  Partial writes fail closed and hide old results.
            axi_write_strobe(SCORE_BASE, 32'd0, 4'h3);
            axi_read(REG_STATUS, status);
            if (!status[2] || status[4]) begin
                $display("FAIL partial score-write status=%08x", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, ERR_CTRL},
                       "partial score-write code");
            expect_results_hidden("partial score-write");
            axi_write(REG_CTRL, 32'h0000_0002);
            axi_write(SCORE_BASE, 32'd0);

            axi_write_strobe(SCALE_BASE, UNIT_SCALE, 4'h1);
            axi_read(REG_STATUS, status);
            if (!status[2] || status[4]) begin
                $display("FAIL partial scale-write status=%08x", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, ERR_CTRL},
                       "partial scale-write code");
            expect_results_hidden("partial scale-write");
            axi_write(REG_CTRL, 32'h0000_0002);
            axi_write(SCALE_BASE, UNIT_SCALE);

            // Simultaneous W1P commands are an explicit protocol error.
            axi_write(REG_CTRL, 32'h0000_0003);
            axi_read(REG_STATUS, status);
            if (!status[2] || status[4]) begin
                $display("FAIL multi-control status=%08x", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, ERR_CTRL},
                       "multi-control code");
            expect_results_hidden("multi-control");
            axi_write(REG_CTRL, 32'h0000_0002);

            // A non-control write while the engine owns its inputs aborts the
            // transaction, reports the violation, and exposes no stale data.
            axi_write(REG_CTRL, 32'h0000_0001);
            axi_read(REG_STATUS, status);
            if (!status[0]) begin
                $display("FAIL busy-write setup status=%08x", status);
                errors = errors + 1;
            end
            axi_write(REG_CONTEXT, CONTEXT_LEN);
            polls = 0;
            axi_read(REG_STATUS, status);
            while (status[0] && polls < 1000) begin
                repeat (4) @(negedge clk);
                axi_read(REG_STATUS, status);
                polls = polls + 1;
            end
            if (status[0] || !status[2]) begin
                $display("FAIL busy-write terminal status=%08x", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, ERR_BUSY_WRITE},
                       "busy-write code");
            expect_results_hidden("busy-write abort");

            // The violation must not poison a no-reset clean restart.
            axi_write(REG_CTRL, 32'h0000_0002);
            start_and_wait_success("busy-write no-reset restart");
            check_summary();
            check_all_results("busy-write no-reset restart");
        end
    endtask

    reg [31:0] initial_status;
    initial begin
        if ((AXI_WIDTH != 64 && AXI_WIDTH != 128) ||
            (SCALE_WIDTH != 12 && SCALE_WIDTH != 16))
            $fatal(1, "TB requires AXI width 64/128 and scale width 12/16");
        for (index = 0; index < 160; index = index + 1)
            vmem[index] = 8'd0;
        set_token_code(0, 5'd1);
        set_token_code(1, 5'd3);

        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        expect_reg(REG_ID, 32'h4b56_0302, "core ID");
        expect_reg(REG_GEOMETRY,
                   ((AXI_WIDTH & 8'hff) << 24) |
                   (32'd128 << 16) | (32'd18 << 8) | 32'd5,
                   "geometry");
        expect_reg(REG_SCALE_FMT,
                   (SCALE_WIDTH == 12) ? 32'h0000_0c08 : 32'h0000_100b,
                   "scale format");
        axi_read(REG_STATUS, initial_status);
        if (initial_status !== 32'd0) begin
            $display("FAIL reset status=%08x", initial_status);
            errors = errors + 1;
        end

        program_inputs();
        expect_bad_count();
        check_scale_format_guard();

        start_and_wait_success("first complete run");
        check_summary();
        check_all_results("first complete run");

        axi_write(REG_CTRL, 32'h0000_0002);
        expect_reg(REG_STATUS, 32'd0, "CLEAR status");
        expect_results_hidden("CLEAR");

        abort_and_restart();
        check_write_guards();

        if (errors == 0) begin
            $display("TB PASS: AXI KVQ raw-attention diagnostic scale_width=%0d axi_width=%0d",
                     SCALE_WIDTH, AXI_WIDTH);
            $finish;
        end
        $fatal(1, "TB FAIL: AXI KVQ raw-attention diagnostic errors=%0d",
               errors);
    end

    wire unused_axi = ^m_axi_arcache ^ ^m_axi_arprot ^ ^m_axi_arqos;
endmodule

`default_nettype wire
