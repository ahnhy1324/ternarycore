// tb_axi_kvq_raw_full_diag.v -- complete raw K4/QK/V5 attention proof.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_WIDTH_VAL
`define SCALE_WIDTH_VAL 12
`endif
`ifndef AXI_DATA_WIDTH_VAL
`define AXI_DATA_WIDTH_VAL 64
`endif

module tb_axi_kvq_raw_full_diag;
    localparam integer SCALE_WIDTH = `SCALE_WIDTH_VAL;
    localparam integer AXI_WIDTH = `AXI_DATA_WIDTH_VAL;
    localparam integer MAX_CONTEXT = 128;
    localparam integer TIMEOUT_CYCLES = 24;
    localparam [31:0] K_BASE = 32'h0000_0fe0;
    localparam [31:0] V_BASE = 32'h0000_0fc0;
    localparam [SCALE_WIDTH-1:0] UNIT_SCALE =
        SCALE_WIDTH == 12 ? 12'd256 : 16'd2048;

    localparam [15:0] REG_CTRL          = 16'h0000;
    localparam [15:0] REG_STATUS        = 16'h0004;
    localparam [15:0] REG_K_BASE_LO     = 16'h0008;
    localparam [15:0] REG_K_BASE_HI     = 16'h000c;
    localparam [15:0] REG_V_BASE_LO     = 16'h0010;
    localparam [15:0] REG_V_BASE_HI     = 16'h0014;
    localparam [15:0] REG_CONTEXT       = 16'h0018;
    localparam [15:0] REG_Q_COUNT       = 16'h001c;
    localparam [15:0] REG_K_SCALE_COUNT = 16'h0020;
    localparam [15:0] REG_V_SCALE_COUNT = 16'h0024;
    localparam [15:0] REG_ERROR         = 16'h0028;
    localparam [15:0] REG_ERROR_INFO    = 16'h002c;
    localparam [15:0] REG_ID            = 16'h0030;
    localparam [15:0] REG_GEOMETRY      = 16'h0034;
    localparam [15:0] REG_SCALE_FMT     = 16'h0038;
    localparam [15:0] REG_PROGRESS      = 16'h003c;
    localparam [15:0] REG_QK_READ_BEATS = 16'h0044;
    localparam [15:0] REG_QK_BURSTS     = 16'h0048;
    localparam [15:0] REG_QK_AR_STALLS  = 16'h004c;
    localparam [15:0] REG_AV_READ_BEATS = 16'h0060;
    localparam [15:0] REG_AV_BURSTS     = 16'h0064;
    localparam [15:0] REG_AV_AR_STALLS  = 16'h0068;
    localparam [15:0] REG_SAT_COUNT     = 16'h0070;
    localparam [15:0] REG_SINK_CTRL     = 16'h0074;
    localparam [15:0] REG_GENERATION    = 16'h0078;
    localparam [15:0] REG_MULT_STYLE    = 16'h007c;
    localparam [15:0] REG_DENOM0        = 16'h0080;
    localparam [15:0] REG_RECIP0        = 16'h0090;
    localparam [15:0] Q_BASE            = 16'h1000;
    localparam [15:0] K_SCALE_BASE      = 16'h2000;
    localparam [15:0] V_SCALE_BASE      = 16'h2400;
    localparam [15:0] SCORE_RESULT_BASE = 16'h3000;
    localparam [15:0] RESULT_BASE       = 16'h4000;

    localparam integer FAULT_OK      = 0;
    localparam integer FAULT_RRESP   = 1;
    localparam integer FAULT_RLAST   = 2;
    localparam integer FAULT_MISSING = 3;
    localparam integer FAULT_TIMEOUT = 4;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg [15:0] s_axi_awaddr = 16'd0;
    reg [2:0] s_axi_awprot = 3'd0;
    reg s_axi_awvalid = 1'b0;
    wire s_axi_awready;
    reg [31:0] s_axi_wdata = 32'd0;
    reg [3:0] s_axi_wstrb = 4'd0;
    reg s_axi_wvalid = 1'b0;
    wire s_axi_wready;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    reg s_axi_bready = 1'b0;
    reg [15:0] s_axi_araddr = 16'd0;
    reg [2:0] s_axi_arprot = 3'd0;
    reg s_axi_arvalid = 1'b0;
    wire s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rvalid;
    reg s_axi_rready = 1'b0;

    wire k_arid, v_arid;
    wire [31:0] k_araddr, v_araddr;
    wire [7:0] k_arlen, v_arlen;
    wire [2:0] k_arsize, v_arsize;
    wire [1:0] k_arburst, v_arburst;
    wire k_arlock, v_arlock;
    wire [3:0] k_arcache, v_arcache;
    wire [2:0] k_arprot, v_arprot;
    wire [3:0] k_arqos, v_arqos;
    wire k_arvalid, v_arvalid;
    wire k_arready, v_arready;
    wire k_rid, v_rid;
    wire [AXI_WIDTH-1:0] k_rdata, v_rdata;
    wire [1:0] k_rresp, v_rresp;
    wire k_rlast, v_rlast, k_rvalid, v_rvalid;
    wire k_rready, v_rready;

    axi_kvq_raw_full_diag #(
        .MAX_CONTEXT(MAX_CONTEXT), .SCALE_WIDTH(SCALE_WIDTH),
        .QK_MULT_STYLE(2), .AV_MULT_STYLE(2),
        .M_AXI_DATA_WIDTH(AXI_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
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
        .m_axi_k_arid(k_arid), .m_axi_k_araddr(k_araddr),
        .m_axi_k_arlen(k_arlen), .m_axi_k_arsize(k_arsize),
        .m_axi_k_arburst(k_arburst), .m_axi_k_arlock(k_arlock),
        .m_axi_k_arcache(k_arcache), .m_axi_k_arprot(k_arprot),
        .m_axi_k_arqos(k_arqos), .m_axi_k_arvalid(k_arvalid),
        .m_axi_k_arready(k_arready), .m_axi_k_rid(k_rid),
        .m_axi_k_rdata(k_rdata), .m_axi_k_rresp(k_rresp),
        .m_axi_k_rlast(k_rlast), .m_axi_k_rvalid(k_rvalid),
        .m_axi_k_rready(k_rready),
        .m_axi_v_arid(v_arid), .m_axi_v_araddr(v_araddr),
        .m_axi_v_arlen(v_arlen), .m_axi_v_arsize(v_arsize),
        .m_axi_v_arburst(v_arburst), .m_axi_v_arlock(v_arlock),
        .m_axi_v_arcache(v_arcache), .m_axi_v_arprot(v_arprot),
        .m_axi_v_arqos(v_arqos), .m_axi_v_arvalid(v_arvalid),
        .m_axi_v_arready(v_arready), .m_axi_v_rid(v_rid),
        .m_axi_v_rdata(v_rdata), .m_axi_v_rresp(v_rresp),
        .m_axi_v_rlast(v_rlast), .m_axi_v_rvalid(v_rvalid),
        .m_axi_v_rready(v_rready)
    );

    reg k_model_reset = 1'b0, v_model_reset = 1'b0;
    reg [2:0] k_fault = FAULT_OK, v_fault = FAULT_OK;
    reg k_reserved = 1'b0, v_reserved = 1'b0;
    reg k_allow_ar = 1'b1, v_allow_ar = 1'b1;
    reg [7:0] k_ar_delay = 0, v_ar_delay = 0;
    reg [7:0] k_r_gap = 0, v_r_gap = 0;
    wire k_active, v_active;
    wire [31:0] k_model_ars, v_model_ars;
    wire [31:0] k_model_beats, v_model_beats;

    tb_axi_raw_fault_model #(
        .IS_V(0), .DATA_WIDTH(AXI_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) k_model (
        .clk(clk), .rst_n(rst_n), .scenario_reset(k_model_reset),
        .base_addr(K_BASE), .fault_mode(k_fault),
        .reserved_mode(k_reserved), .allow_ar(k_allow_ar),
        .initial_ar_delay(k_ar_delay), .r_gap(k_r_gap),
        .arid(k_arid), .araddr(k_araddr), .arlen(k_arlen),
        .arsize(k_arsize), .arburst(k_arburst), .arvalid(k_arvalid),
        .arready(k_arready), .rid(k_rid), .rdata(k_rdata),
        .rresp(k_rresp), .rlast(k_rlast), .rvalid(k_rvalid),
        .rready(k_rready), .active(k_active),
        .ar_count(k_model_ars), .read_count(k_model_beats)
    );

    tb_axi_raw_fault_model #(
        .IS_V(1), .DATA_WIDTH(AXI_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) v_model (
        .clk(clk), .rst_n(rst_n), .scenario_reset(v_model_reset),
        .base_addr(V_BASE), .fault_mode(v_fault),
        .reserved_mode(v_reserved), .allow_ar(v_allow_ar),
        .initial_ar_delay(v_ar_delay), .r_gap(v_r_gap),
        .arid(v_arid), .araddr(v_araddr), .arlen(v_arlen),
        .arsize(v_arsize), .arburst(v_arburst), .arvalid(v_arvalid),
        .arready(v_arready), .rid(v_rid), .rdata(v_rdata),
        .rresp(v_rresp), .rlast(v_rlast), .rvalid(v_rvalid),
        .rready(v_rready), .active(v_active),
        .ar_count(v_model_ars), .read_count(v_model_beats)
    );

    integer errors = 0;
    integer write_sequence = 0;

    task axi_write;
        input [15:0] address;
        input [31:0] data;
        integer guard;
        begin
            @(negedge clk);
            if ((write_sequence & 1) == 0) begin
                s_axi_awaddr = address;
                s_axi_awvalid = 1'b1;
                guard = 0;
                while (!s_axi_awready && guard < 200) begin
                    @(negedge clk); guard = guard + 1;
                end
                @(posedge clk); @(negedge clk);
                s_axi_awvalid = 1'b0;
                s_axi_wdata = data; s_axi_wstrb = 4'hf;
                s_axi_wvalid = 1'b1;
                guard = 0;
                while (!s_axi_wready && guard < 200) begin
                    @(negedge clk); guard = guard + 1;
                end
                @(posedge clk); @(negedge clk);
                s_axi_wvalid = 1'b0; s_axi_wstrb = 4'd0;
            end else begin
                s_axi_wdata = data; s_axi_wstrb = 4'hf;
                s_axi_wvalid = 1'b1;
                guard = 0;
                while (!s_axi_wready && guard < 200) begin
                    @(negedge clk); guard = guard + 1;
                end
                @(posedge clk); @(negedge clk);
                s_axi_wvalid = 1'b0; s_axi_wstrb = 4'd0;
                s_axi_awaddr = address; s_axi_awvalid = 1'b1;
                guard = 0;
                while (!s_axi_awready && guard < 200) begin
                    @(negedge clk); guard = guard + 1;
                end
                @(posedge clk); @(negedge clk);
                s_axi_awvalid = 1'b0;
            end
            write_sequence = write_sequence + 1;
            s_axi_bready = 1'b1;
            guard = 0;
            while (!s_axi_bvalid && guard < 200) begin
                @(negedge clk); guard = guard + 1;
            end
            if (!s_axi_bvalid || s_axi_bresp != 0)
                $fatal(1, "AXI-Lite write failure addr=%04x", address);
            @(posedge clk); @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_write_fast;
        input [15:0] address;
        input [31:0] data;
        integer guard;
        begin
            @(negedge clk);
            s_axi_awaddr = address; s_axi_awvalid = 1'b1;
            s_axi_wdata = data; s_axi_wstrb = 4'hf;
            s_axi_wvalid = 1'b1;
            guard = 0;
            while ((!s_axi_awready || !s_axi_wready) && guard < 200) begin
                @(negedge clk); guard = guard + 1;
            end
            @(posedge clk); @(negedge clk);
            s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
            s_axi_wstrb = 4'd0; s_axi_bready = 1'b1;
            guard = 0;
            while (!s_axi_bvalid && guard < 200) begin
                @(negedge clk); guard = guard + 1;
            end
            if (!s_axi_bvalid)
                $fatal(1, "AXI-Lite fast write failure addr=%04x", address);
            @(posedge clk); @(negedge clk); s_axi_bready = 1'b0;
        end
    endtask

    task axi_read;
        input [15:0] address;
        output [31:0] data;
        integer guard;
        begin
            @(negedge clk);
            s_axi_araddr = address; s_axi_arvalid = 1'b1;
            guard = 0;
            while (!s_axi_arready && guard < 200) begin
                @(negedge clk); guard = guard + 1;
            end
            @(posedge clk); @(negedge clk); s_axi_arvalid = 1'b0;
            repeat ((address[3:2] & 1) + 1) @(negedge clk);
            s_axi_rready = 1'b1;
            guard = 0;
            while (!s_axi_rvalid && guard < 200) begin
                @(negedge clk); guard = guard + 1;
            end
            if (!s_axi_rvalid || s_axi_rresp != 0)
                $fatal(1, "AXI-Lite read failure addr=%04x", address);
            #1 data = s_axi_rdata;
            @(posedge clk); @(negedge clk); s_axi_rready = 1'b0;
        end
    endtask

    task expect_reg;
        input [15:0] address;
        input [31:0] wanted;
        input string label_text;
        reg [31:0] got;
        begin
            axi_read(address, got);
            if (got !== wanted) begin
                $display("ERROR %s got=%08x wanted=%08x",
                         label_text, got, wanted);
                errors = errors + 1;
            end
        end
    endtask

    task reset_models;
        begin
            @(negedge clk);
            k_model_reset = 1'b1; v_model_reset = 1'b1;
            @(negedge clk);
            k_model_reset = 1'b0; v_model_reset = 1'b0;
        end
    endtask

    task clean_models;
        begin
            @(negedge clk);
            k_fault = FAULT_OK; v_fault = FAULT_OK;
            k_reserved = 1'b0; v_reserved = 1'b0;
            k_allow_ar = 1'b1; v_allow_ar = 1'b1;
            k_ar_delay = 0; v_ar_delay = 0;
            k_r_gap = 0; v_r_gap = 0;
            reset_models();
        end
    endtask

    task wait_terminal;
        output [31:0] status;
        integer watchdog;
        begin
            status = 0; watchdog = 0;
            while (watchdog < 100000) begin
                axi_read(REG_STATUS, status);
                if (!status[0] && (status[1] || status[2] || status[3]))
                    watchdog = 100000;
                else
                    watchdog = watchdog + 1;
            end
            if (status[0] || !(status[1] || status[2] || status[3]))
                $fatal(1, "terminal timeout status=%08x top=%0d qk=%0d pipe=%0d/pstate%0d guard=%0d meta=%0d kactive=%0d vactive=%0d avbusy=%0d avdrain=%0d/astate%0d/reader%0d/ameta%0d norm=%0d softq=%0d pmeta=%0d",
                    status,dut.state,dut.qk_busy,dut.pipeline_busy,
                    dut.u_pipeline.state,dut.guard_busy,
                    dut.qk_meta_rsp_valid,k_active,v_active,
                    dut.u_pipeline.av_busy,dut.u_pipeline.av_draining,
                    dut.u_pipeline.u_av_engine.state,
                    dut.u_pipeline.u_av_engine.reader_busy,
                    dut.u_pipeline.u_av_engine.meta_drain_pending,
                    dut.u_pipeline.normalizer_busy,
                    dut.u_pipeline.soft_quiescent,
                    dut.u_pipeline.meta_rsp_valid);
        end
    endtask

    task clear_status;
        begin
            axi_write(REG_CTRL, 32'h2);
            expect_reg(REG_STATUS, 32'd0, "CLEAR status");
        end
    endtask

    task program_context;
        input integer count;
        integer token;
        begin
            axi_write(REG_K_BASE_LO, K_BASE);
            axi_write(REG_K_BASE_HI, 0);
            axi_write(REG_V_BASE_LO, V_BASE);
            axi_write(REG_V_BASE_HI, 0);
            axi_write(REG_CONTEXT, count);
            for (token = 0; token < count; token = token + 1) begin
                axi_write(K_SCALE_BASE + token*4, UNIT_SCALE);
                axi_write(V_SCALE_BASE + token*4, UNIT_SCALE);
            end
            axi_write(REG_Q_COUNT, 512);
            axi_write(REG_K_SCALE_COUNT, count);
            axi_write(REG_V_SCALE_COUNT, count);
        end
    endtask

    task start_success_with_backpressure;
        input integer count;
        reg [31:0] status;
        begin
            clear_status(); clean_models();
            @(negedge clk);
            k_ar_delay = 2; v_ar_delay = 3;
            k_r_gap = 1; v_r_gap = 1;
            reset_models();
            axi_write(REG_SINK_CTRL, 0);
            axi_write(REG_CTRL, 1);
            wait (dut.pipeline_result_valid);
            repeat (5) @(posedge clk);
            axi_write(REG_SINK_CTRL, 1);
            wait_terminal(status);
            if (!status[1] || !status[4] || status[2] || status[3]) begin
                $display("ERROR success status=%08x", status);
                errors = errors + 1;
            end
            if (count == 2) begin
                expect_reg(REG_QK_READ_BEATS,
                           AXI_WIDTH == 64 ? 16 : 8, "QK beats ctx2");
                expect_reg(REG_QK_BURSTS, 3, "QK bursts ctx2 split");
                expect_reg(REG_AV_READ_BEATS,
                           AXI_WIDTH == 64 ? 20 : 10, "AV beats ctx2");
                expect_reg(REG_AV_BURSTS, 3, "AV bursts ctx2 split");
            end else begin
                expect_reg(REG_QK_READ_BEATS,
                           AXI_WIDTH == 64 ? 8 : 4, "QK beats ctx1");
                expect_reg(REG_QK_BURSTS, 2, "QK bursts ctx1 split");
                expect_reg(REG_AV_READ_BEATS,
                           AXI_WIDTH == 64 ? 10 : 5, "AV beats ctx1");
                expect_reg(REG_AV_BURSTS, 2, "AV bursts ctx1 split");
            end
            if (k_model_ars == 0 || v_model_ars == 0)
                errors = errors + 1;
            expect_reg(REG_SAT_COUNT, 0, "saturation counts");
        end
    endtask

    task check_all_results;
        input integer count;
        integer item;
        integer head;
        reg [31:0] lo, hi, codeword;
        reg signed [47:0] reconstructed;
        reg signed [47:0] wanted_numerator;
        reg signed [17:0] wanted_code;
        begin
            if (count == 2) begin
                wanted_numerator = SCALE_WIDTH == 12 ?
                    48'sd33554432 : 48'sd268435456;
                wanted_code = 18'sd512;
            end else begin
                wanted_numerator = SCALE_WIDTH == 12 ?
                    48'sd8388608 : 48'sd67108864;
                wanted_code = 18'sd256;
            end
            for (item = 0; item < 512; item = item + 1) begin
                axi_read(RESULT_BASE + item*16, lo);
                axi_read(RESULT_BASE + item*16 + 4, hi);
                axi_read(RESULT_BASE + item*16 + 8, codeword);
                reconstructed = {hi[15:0],lo};
                if (reconstructed !== wanted_numerator ||
                    hi[31:16] !== {16{wanted_numerator[47]}} ||
                    $signed(codeword[17:0]) !== wanted_code ||
                    codeword[31] !== 1'b0) begin
                    if (errors < 20)
                        $display("ERROR result ctx%0d item%0d num=%0d code=%0d",
                            count, item, reconstructed,
                            $signed(codeword[17:0]));
                    errors = errors + 1;
                end
            end
            for (head = 0; head < 4; head = head + 1)
                expect_reg(REG_DENOM0 + head*4,
                           count == 2 ? 32'd65536 : 32'd32768,
                           "softmax denominator");
        end
    endtask

    task check_all_scores;
        input integer count;
        integer item;
        integer row;
        integer token;
        reg [31:0] value;
        reg signed [15:0] wanted;
        begin
            for (item = 0; item < 512; item = item + 1) begin
                row = item / 128;
                token = item % 128;
                if (token >= count)
                    wanted = 16'sd0;
                else case (row)
                    0: wanted = 16'sd1024;
                    1: wanted = 16'sd3072;
                    2: wanted = -16'sd1024;
                    default: wanted = 16'sd5120;
                endcase
                axi_read(SCORE_RESULT_BASE + item*4,value);
                if ($signed(value) !== wanted) begin
                    if (errors < 20)
                        $display("ERROR committed score ctx%0d item%0d=%0d want=%0d",
                                 count,item,$signed(value),wanted);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task expect_all_scores_hidden;
        input string label_text;
        integer item;
        reg [31:0] value;
        begin
            for (item = 0; item < 512; item = item + 1) begin
                axi_read(SCORE_RESULT_BASE + item*4,value);
                if (value !== 0) begin
                    if (errors < 20)
                        $display("ERROR %s exposed score[%0d]=%08x",
                                 label_text,item,value);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task expect_hidden;
        input string label_text;
        reg [31:0] value;
        begin
            axi_read(RESULT_BASE, value);
            if (value != 0) begin
                $display("ERROR %s exposed first result=%08x",label_text,value);
                errors = errors + 1;
            end
            axi_read(RESULT_BASE + 511*16 + 8, value);
            if (value != 0) begin
                $display("ERROR %s exposed last result=%08x",label_text,value);
                errors = errors + 1;
            end
            axi_read(SCORE_RESULT_BASE,value);
            if (value != 0) begin
                $display("ERROR %s exposed committed score=%08x",
                         label_text,value);
                errors = errors + 1;
            end
        end
    endtask

    task run_fault;
        input integer on_v;
        input [2:0] mode;
        input [7:0] wanted_code;
        reg [31:0] status, info;
        begin
            clear_status(); clean_models();
            @(negedge clk);
            if (on_v) v_fault = mode; else k_fault = mode;
            reset_models();
            axi_write(REG_CTRL, 1);
            wait_terminal(status);
            if (!status[2] || status[1] || status[3] || status[4]) begin
                $display("ERROR fault terminal master=%0d mode=%0d status=%08x",
                         on_v, mode, status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, wanted_code, "transport fault code");
            axi_read(REG_ERROR_INFO, info);
            if (info[18:16] != (on_v ? 4 : 2)) begin
                $display("ERROR fault source got=%0d", info[18:16]);
                errors = errors + 1;
            end
            expect_hidden("transport fault");
        end
    endtask

    task run_tag_fault;
        reg [31:0] status, info;
        begin
            clear_status(); clean_models();
            axi_write(REG_CTRL,1);
            wait (dut.qk_score_valid && dut.guard_score_ready);
            @(negedge clk);
            force dut.u_score_guard.score_task_tag = 128'hbad0_bad0;
            @(posedge clk); @(negedge clk);
            release dut.u_score_guard.score_task_tag;
            wait_terminal(status);
            if (!status[2] || status[4]) errors = errors + 1;
            expect_reg(REG_ERROR,8'h03,"score task-tag fault");
            axi_read(REG_ERROR_INFO,info);
            if (info[18:16] != 3) errors = errors + 1;
            expect_hidden("score task-tag fault");
        end
    endtask

    task abort_in_phase;
        input integer which_phase;
        reg [31:0] status;
        begin
            $display("INFO abort phase %0d",which_phase);
            clear_status(); clean_models();
            if (which_phase == 0) begin
                // Keep an accepted K burst outstanding long enough to prove
                // that cancellation drains the owned 64/128-bit transaction.
                @(negedge clk);
                k_r_gap = 8;
            end
            axi_write(REG_SINK_CTRL, which_phase == 4 ? 0 : 1);
            axi_write(REG_CTRL, 1);
            case (which_phase)
                0: wait (k_active);
                1: wait (dut.state == 4'd2);
                2: wait (dut.u_pipeline.state == 4'd2);
                3: begin
                    // Accept one V-scale metadata request, hold its response,
                    // then abort.  The response remains owned and is drained
                    // before the no-reset restart boundary opens.
                    wait (dut.u_pipeline.meta_req_valid &&
                          dut.u_pipeline.meta_req_ready);
                    @(negedge clk);
                    force dut.u_pipeline.meta_rsp_ready = 1'b0;
                    @(posedge clk);
                end
                default: wait (dut.pipeline_result_valid);
            endcase
            axi_write_fast(REG_CTRL, 4);
            if (which_phase == 0)
                wait (dut.qk_draining);
            if (which_phase == 3) begin
                wait (dut.state == 4'd4);
                repeat (2) @(posedge clk);
                release dut.u_pipeline.meta_rsp_ready;
            end
            wait_terminal(status);
            if (!status[3] || status[1] || status[2] || status[4]) begin
                $display("ERROR abort phase%0d status=%08x",which_phase,status);
                errors = errors + 1;
            end
            expect_hidden("aborted phase");
            if (which_phase == 4)
                axi_write(REG_SINK_CTRL, 1);
        end
    endtask

    integer index;
    integer dimension;
    reg [31:0] status;
    reg [31:0] generation_before, generation_after;
    initial begin
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        expect_reg(REG_ID, 32'h4b56_0303, "raw-full ID");
        expect_reg(REG_GEOMETRY, 32'h4080_1204, "geometry");
        expect_reg(REG_SCALE_FMT,
                   SCALE_WIDTH == 12 ? 32'h0000_0c08 : 32'h0000_100b,
                   "scale format");
        expect_reg(REG_MULT_STYLE,32'h0000_0022,"balanced multiply styles");

        // Four flattened Q vectors have exact row sums +4,+12,-4,+20.
        for (index = 0; index < 512; index = index + 1) begin
            dimension = index % 128;
            case (index / 128)
                0: axi_write(Q_BASE + index*4,
                             dimension < 4 ? 32'h1 : 32'h0);
                1: axi_write(Q_BASE + index*4,
                             dimension < 12 ? 32'h1 : 32'h0);
                2: axi_write(Q_BASE + index*4,
                             dimension < 4 ? 32'hffff_ffff : 32'h0);
                default: axi_write(Q_BASE + index*4,
                             dimension < 20 ? 32'h1 : 32'h0);
            endcase
        end
        program_context(2);

        // Bad counts fail before either master can launch.
        clear_status(); clean_models();
        axi_write(REG_Q_COUNT, 511);
        axi_write(REG_CTRL, 1);
        wait_terminal(status);
        if (!status[2]) errors = errors + 1;
        expect_reg(REG_ERROR, 8'h25, "bad count");
        if (k_model_ars != 0 || v_model_ars != 0) errors = errors + 1;
        expect_hidden("bad count");
        axi_write(REG_Q_COUNT, 512);

        start_success_with_backpressure(2);
        check_all_scores(2);
        check_all_results(2);
        axi_read(REG_GENERATION, generation_before);

        // CLEAR hides all previously committed output without erasing input.
        clear_status();
        expect_hidden("CLEAR");
        expect_all_scores_hidden("CLEAR");

        // Reserved raw codes are typed arithmetic failures.
        clean_models();
        @(negedge clk); k_reserved = 1'b1; reset_models();
        axi_write(REG_CTRL,1); wait_terminal(status);
        expect_reg(REG_ERROR,8'h21,"reserved K4");
        expect_hidden("reserved K4");

        clear_status(); clean_models();
        @(negedge clk); v_reserved = 1'b1; reset_models();
        axi_write(REG_CTRL,1); wait_terminal(status);
        expect_reg(REG_ERROR,8'h63,"reserved V5");
        expect_hidden("reserved V5");

        run_tag_fault();

        run_fault(0,FAULT_RRESP,8'h13);
        run_fault(0,FAULT_RLAST,8'h14);
        run_fault(0,FAULT_MISSING,8'h14);
        run_fault(0,FAULT_TIMEOUT,8'h11);
        run_fault(1,FAULT_RRESP,8'h53);
        run_fault(1,FAULT_RLAST,8'h54);
        run_fault(1,FAULT_MISSING,8'h54);
        run_fault(1,FAULT_TIMEOUT,8'h51);

        // Explicit cancellation at each ownership boundary.
        abort_in_phase(0);
        abort_in_phase(1);
        abort_in_phase(2);
        abort_in_phase(3);
        abort_in_phase(4);

        // A non-control configuration write during QK cancels the job.
        clear_status(); clean_models();
        axi_write(REG_CTRL,1); wait(k_active);
        axi_write_fast(REG_CONTEXT,2);
        wait_terminal(status);
        if (!status[2] || status[4]) errors = errors + 1;
        expect_reg(REG_ERROR,8'h83,"busy config write");
        expect_hidden("busy config write");

        // No reset: change to the short context and prove all 512 outputs and
        // generation ownership anew.
        clear_status(); clean_models(); program_context(1);
        start_success_with_backpressure(1);
        check_all_scores(1);
        check_all_results(1);
        axi_read(REG_GENERATION, generation_after);
        if (generation_after <= generation_before) begin
            $display("ERROR generation did not advance %0d -> %0d",
                     generation_before,generation_after);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("AXI_KVQ_RAW_FULL_DIAG_SCALE%0d_AXI%0d_PASS",
                     SCALE_WIDTH,AXI_WIDTH);
            $finish;
        end
        $fatal(1,"AXI raw full diagnostic errors=%0d",errors);
    end

    initial begin
        #30000000;
        $fatal(1,"TB timeout");
    end

    wire unused_axi = k_arlock ^ v_arlock ^ ^k_arcache ^ ^v_arcache ^
        ^k_arprot ^ ^v_arprot ^ ^k_arqos ^ ^v_arqos ^
        (k_arsize != $clog2(AXI_WIDTH/8)) ^
        (v_arsize != $clog2(AXI_WIDTH/8)) ^
        (k_arburst != 1) ^ (v_arburst != 1) ^
        ^k_model_beats ^ ^v_model_beats ^ ^REG_PROGRESS ^ ^REG_RECIP0 ^
        ^REG_QK_AR_STALLS ^ ^REG_AV_AR_STALLS;
endmodule

// One-outstanding AXI64/128 model.  It synthesizes dense raw K4 or packed raw V5
// bytes directly from the requested address and can inject one first-burst
// protocol fault per scenario.
module tb_axi_raw_fault_model #(
    parameter integer IS_V = 0,
    parameter integer DATA_WIDTH = 64,
    parameter integer TIMEOUT_CYCLES = 24
) (
    input wire clk,
    input wire rst_n,
    input wire scenario_reset,
    input wire [31:0] base_addr,
    input wire [2:0] fault_mode,
    input wire reserved_mode,
    input wire allow_ar,
    input wire [7:0] initial_ar_delay,
    input wire [7:0] r_gap,
    input wire arid,
    input wire [31:0] araddr,
    input wire [7:0] arlen,
    input wire [2:0] arsize,
    input wire [1:0] arburst,
    input wire arvalid,
    output wire arready,
    output wire rid,
    output reg [DATA_WIDTH-1:0] rdata,
    output reg [1:0] rresp,
    output reg rlast,
    output reg rvalid,
    input wire rready,
    output reg active,
    output reg [31:0] ar_count,
    output reg [31:0] read_count
);
    localparam integer FAULT_OK      = 0;
    localparam integer FAULT_RRESP   = 1;
    localparam integer FAULT_RLAST   = 2;
    localparam integer FAULT_MISSING = 3;
    localparam integer FAULT_TIMEOUT = 4;
    localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam integer BYTE_SHIFT = $clog2(BYTES_PER_BEAT);
    reg [31:0] active_addr;
    integer active_beats;
    integer active_beat;
    integer ar_wait;
    integer gap_wait;
    integer timeout_wait;
    reg fault_consumed;
    assign arready = allow_ar && !active && ar_wait == 0;
    assign rid = 1'b0;

    function [DATA_WIDTH-1:0] memory_word;
        input [31:0] address;
        integer lane;
        integer absolute_offset;
        integer token;
        integer local_byte;
        integer bit_index;
        integer absolute_bit;
        integer dimension;
        integer code_bit;
        reg [4:0] code;
        reg [7:0] one_byte;
        reg [DATA_WIDTH-1:0] word;
        begin
            word = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < BYTES_PER_BEAT; lane = lane + 1) begin
                absolute_offset = address + lane - base_addr;
                if (IS_V) begin
                    token = absolute_offset / 80;
                    local_byte = absolute_offset % 80;
                    one_byte = 8'd0;
                    for (bit_index = 0; bit_index < 8;
                         bit_index = bit_index + 1) begin
                        absolute_bit = local_byte*8 + bit_index;
                        dimension = absolute_bit / 5;
                        code_bit = absolute_bit % 5;
                        code = token == 0 ? 5'd1 : 5'd3;
                        if (reserved_mode && token == 0 && dimension == 0)
                            code = 5'h10;
                        one_byte[bit_index] = code[code_bit];
                    end
                end else begin
                    token = absolute_offset / 64;
                    one_byte = 8'h11;
                    if (reserved_mode && absolute_offset == 0)
                        one_byte[3:0] = 4'h8;
                end
                word[lane*8 +: 8] = one_byte;
            end
            memory_word = word;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n || scenario_reset) begin
            rdata <= {DATA_WIDTH{1'b0}};
            rresp <= 2'b00;
            rlast <= 1'b0;
            rvalid <= 1'b0;
            active <= 1'b0;
            active_addr <= 32'd0;
            active_beats <= 0;
            active_beat <= 0;
            ar_wait <= initial_ar_delay;
            gap_wait <= 0;
            timeout_wait <= 0;
            fault_consumed <= 1'b0;
            ar_count <= 32'd0;
            read_count <= 32'd0;
        end else begin
            if (!active && ar_wait > 0)
                ar_wait <= ar_wait - 1;
            if (arvalid && arready) begin
                if (arsize != BYTE_SHIFT || arburst != 2'b01)
                    $fatal(1,"bad AXI geometry width=%0d size=%0d burst=%0d",
                           DATA_WIDTH,arsize,arburst);
                active <= 1'b1;
                active_addr <= araddr;
                active_beats <= arlen + 1;
                active_beat <= 0;
                gap_wait <= r_gap;
                ar_count <= ar_count + 1'b1;
                if (fault_mode == FAULT_TIMEOUT && !fault_consumed)
                    timeout_wait <= TIMEOUT_CYCLES + 3;
                else
                    timeout_wait <= 0;
            end
            if (rvalid && rready) begin
                rvalid <= 1'b0;
                read_count <= read_count + 1'b1;
                if (rlast) begin
                    active <= 1'b0;
                    ar_wait <= 0;
                    if (fault_mode != FAULT_OK)
                        fault_consumed <= 1'b1;
                end else begin
                    active_beat <= active_beat + 1;
                    gap_wait <= r_gap;
                end
            end
            if (active && !rvalid) begin
                if (timeout_wait > 0)
                    timeout_wait <= timeout_wait - 1;
                else if (gap_wait > 0)
                    gap_wait <= gap_wait - 1;
                else begin
                    rvalid <= 1'b1;
                    rdata <= memory_word(
                        active_addr + active_beat*BYTES_PER_BEAT);
                    rresp <= (fault_mode == FAULT_RRESP && !fault_consumed &&
                              active_beat == 1) ? 2'b10 : 2'b00;
                    if (fault_mode == FAULT_RLAST && !fault_consumed)
                        rlast <= active_beat == 0;
                    else if (fault_mode == FAULT_MISSING && !fault_consumed)
                        rlast <= active_beat == active_beats;
                    else
                        rlast <= active_beat == active_beats-1;
                end
            end
        end
    end

    wire unused = arid;

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH != 64 && DATA_WIDTH != 128)
            $error("tb_axi_raw_fault_model DATA_WIDTH must be 64 or 128");
    end
`endif
endmodule

`default_nettype wire
